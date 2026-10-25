# 文档类型分派：MD 档案与 HTML 档案（设计稿，2026-10-25）

> 起因：写作场景下 agent 需要更懂文档结构。观察是「HTML 文档的上下文非常大」，提议是
> 「设计一个 md 的 agent 和一个 html 的 agent」。本文先验证前半句，再修正后半句。
>
> **状态：已实施（0.13.9）。** 落地时有三处与本文不同、还有两条没做——先读 §11
> 再读 §3，否则会照着没实现的东西理解代码。

---

## 0. 结论先说

**方向对，切法要改。**

- 「HTML 上下文大」**成立**，但原因不是标签多（实测只有 **1.50×**），是**样式表占了 60%**。
- 「分两个 agent」**不成立**。`AgentRunner` 的 843 行里，停滞检测、并行调度、代际防竞态、
  预算裁剪、diff 审阅、回滚、写后自检**全部与文档类型无关**。复制两份等于两份 bug 各修一遍。
- 真正该分的是三个维度：**上下文构建策略 / 工具子集 / 操作指引**。做成一份纯值配置
  `DocumentAuthoringProfile`，由 `AgentRunner` 之外的一层在组装 prompt 与工具时读取。

一句话：**不是两个 agent，是一个 agent 的两副眼镜。**

---

## 1. 实测数据（决定设计的那几个数）

按 `AIConversation.estimateTokens` 同口径估算（CJK 1 token/字，其余 4 字符/token）：

| 对象 | 字符 | ≈ token | 备注 |
|---|---|---|---|
| 17 个内置工具的定义总和 | — | 2,835 | 占 60K 历史预算的 4.7% |
| `doc-template.html` 全文 | 9,866 | 2,699 | |
| ├ 其中 `<style>` 块 | 5,970 | **1,510** | **占全文 60%** |
| └ 正文骨架 | 3,896 | 1,189 | |
| `tufteCSS` / `craftCSS` / `darkCSS` | 1,810 / 1,986 / 2,186 | 452 / 496 / 546 | 薄样式，与 doc 差 4.5× |
| 同内容 MD vs HTML（无样式） | 320 vs 615 | 146 vs 219 | **纯标签开销 1.50×** |
| 同上 HTML + doc 模板外壳 | — | 3,118 | **相对 MD 21.4×** |

**两条结论**

1. **标签不是问题。** 1.50× 在任何预算下都可接受。
2. **模板外壳是问题，且分两种情况**：
   - 短文（< ~5,400 token 内容）：模板成本占绝对主导，21× 是灾难。
   - 长文（> ~5,400 token）：模板成本摊薄到 2× 以内，但**CSS 仍然每次都在**——
     模型要改一句话，也得为那 1,510 token 的样式表付费，而它对改正文毫无用处。

    当前 `read_document` 返回全文（上限 64K 字符），**样式表和正文一起塞进历史**。
    `get_html_template` 更直接：一次调用把 2,699 token 的完整模板灌进对话，一个 run 调两次
    就是 5,398 token，且进历史后永久占用（除非被裁剪成占位符，那模型又得重拿）。

---

## 2. 为什么不是「两个 agent」

`AgentRunner.swift` 里与文档类型**真正相关**的只有三处：system prompt 文本、
注册哪些工具、以及上下文怎么给。其余全部无关：

| 机制 | 位置 | 与文档类型的关系 |
|---|---|---|
| 三级停滞检测 | `AgentRunner.swift:68/73/78` | 无关 |
| 并行只读 / 串行写 | `:83`、`:401` | 无关（但工具名清单要跟着档案走） |
| 代际防竞态 | `:93`、`:306` | 无关 |
| 输出上限 / 超时联动 | `:96-105`、`:129` | 无关 |
| 预算裁剪与配对对齐 | `AgentHistoryBudget` | 无关（档案只决定**进去多少**，不决定**怎么裁**） |
| diff 审阅 / 逐块接受 | `DocumentTools.swift:236-262` | 无关 |
| 写后自检 | `AgentWriteSelfCheck.swift` | 无关（可扩展检查项） |
| 参数校验一把尺子 | `AgentTool.swift:295` | 无关 |

**判定：不新建第二个 Runner。** 新建的是「档案」——一个纯值配置，`AgentRunner` 完全不知道
它的存在，只在 `AIChatCoordinator.systemContext` 与工具组装两处被读取。

---

## 3. 设计

### 3.1 `DocumentAuthoringProfile`（纯值）

```swift
/// 一种文档类型的写作档案：首轮给模型看什么、追加什么策略。
/// 纯值 + 无 IO ⇒ 可单测，可按扩展名分派。
struct DocumentAuthoringProfile: Sendable, Equatable {
    enum Kind: String, Sendable { case markdown, html, plain }
    enum ContextMode { case fullDocument, markdownOutline, htmlStructure }

    let kind: Kind
    var contextMode: ContextMode { … }
    /// 追加到 system prompt **稳定段**的操作策略
    let guidance: String

    static func resolve(fileExtension: String?) -> DocumentAuthoringProfile
    static func resolve(fileName: String?) -> DocumentAuthoringProfile
}
```

> **落地修正（见 §11.1）**：设计稿原打算带 `toolAllowList: Set<String>?`，
> 实现时删掉了。全部文档工具都带可选 `filename`，作用对象与当前 tab 的类型无关
> （`.md` tab 里要求「导出成 HTML」是常见请求），按 tab 类型藏工具会直接让这类
> 请求无解。工具的取舍仍交给已有的 `AgentToolBudget`。

**分派规则**：按当前 tab 的扩展名（`md`/`markdown` → markdown；`html`/`htm` → html；
其余 → plain）。plain 档案 = **今天的全部行为，逐字节不变**（老用户不受影响，也是回滚开关）。

### 3.2 Markdown 档案：给「地址」，不给「全文」

写作任务的绝大多数是「改某一节」「检查结构」「统一某个说法」，**全文是浪费**。
所以首轮注入**大纲**而不是全文：

```
# 当前文档：设计稿.md（12 节，3,140 字）

| 节 | 标题 | 行区间 | 字数 |
|---|---|---|---|
| 1 | 为什么不是「塞 prompt」 | L1-L18 | 420 |
| 2 | 数据模型 | L19-L46 | 610 |
| ... |

可用：read_section("<标题>") 读全文，rewrite_section("<标题>", 新内容) 替换整节。
```

大纲成本约 **每节 11–16 token**。本仓三份真实文档实测：

| 文档 | 全文 | 大纲 | 压缩比 |
|---|---|---|---|
| `docs/ai-roadmap.md`（12 节） | 3,340 | 203 | 1/16 |
| `docs/ai-memory-design.md`（21 节） | 2,957 | 235 | 1/13 |
| `README.zh.md`（28 节） | 5,029 | 350 | 1/14 |

**省一个数量级。** 这是「每轮 system prompt 都重发」的差别——不是省一次，是省每一轮。

**「整体感」怎么办**：不靠宿主猜意图，**靠工具把选择权给模型**。模型想问「有没有前后矛盾」
就自己 `read_section` 逐节读——这是 agent 该做的判断，不是启发式关键词能替代的。
成本是可能多一次往返，但只在这类请求上付。

**选区仍然优先**：有选区时注入「选区 + 所在节的大纲行」，这是最精准的定位信号，比大纲更省。

**短文档例外（落地时加的）**：正文 ≤ 500 token 时直接给全文。一篇 200 字的笔记，
「大纲 + `read_section`」是用一次往返换 200 token——往返本身（模型思考 + 一次工具结果）
比省下的 token 贵得多。分档的收益只在长文档上成立。

### 3.3 HTML 档案：样式表不进上下文

```
# 当前文档：报告.html（1 个 CSS 块 / 1,510 token，已折叠）

结构：
article.report
├── h1 「三季度复盘」
├── section#summary > h2 + ul(3)
├── section#data > h2 + table(4×3)
└── section#next > h2 + ol(2)

改样式用 set_node_class / patch_style，**不要重写整份文档**。
需要看 CSS 时调 read_style()——它 1,510 token，非必要不调。
```

三件事：

1. **CSS 折叠**，模型改正文时 token 成本里 CSS = 0。
2. **结构用 selector 表达**，模型拿到的不是行号而是「可寻址路径」——这正是它做准确定位需要的东西。
3. **模板引用式**（见 3.4）替代 `get_html_template` 的全文回灌。

### 3.4 模板引用式：让 harness 干确定性的事

现状：`get_html_template` 把 2,699 token 的完整模板塞进对话。模型要做的是**复制它、保留
`<style>`、只改 body** —— 一件纯机械、且复制必出错的活。

改成：

```swift
// 新工具：write_html_with_template
//   template: "doc" | "craft" | "tufte" | "dark"
//   body:     "<article>…</article>"      ← 模型只写语义 HTML
```

宿主在写入时把 `body` 填进模板并展开成完整文档。收益：

| | 现状 | 引用式 |
|---|---|---|
| 模板是否进历史 | 是，2,699 token/次 | 否 |
| CSS 复制出错的可能 | 有（模型逐字复制 6K 字符） | 无 |
| 模板升级后旧文档 | 模型用旧模板 | 用当次模板 |

**这条比「分两个 agent」更能解决「HTML 上下文大」**：它把 2,699 token 从「每轮都付」
变成「零」；结构折叠再把 1,510 token 的 CSS 从「每次读都付」变成「显式要求才付」。

`get_html_template` 保留但降级为「只读查看」用（例如用户就要看模板长什么样），
`guidance` 里明确「新建/改版不要用它，用 `write_html_with_template`」。

### 3.5 新增的结构工具（两档案各一组）

| 档案 | 工具 | 语义 | 为什么不是现有工具能做到的 |
|---|---|---|---|
| MD | `outline_document` | 标题树 + 行区间 + 字数 | `read_document` 只给全文；模型数不清第几节在哪一行 |
| MD | `read_section` | 按**标题路径**读一节 | 现有 `read_document` 只有行号参数，而模型不知道行号 |
| MD | `rewrite_section` | 按标题路径整节替换 | `patch_document` 是字面查找，跨段改写要构造整段原文（易错）；`write_document` 是全量 |
| HTML | `html_outline` | 区块树 + selector | 同上，HTML 更需要——行号在标签流里毫无意义 |
| HTML | `read_node` | 按 selector 读节点（含 outerHTML） | |
| HTML | `read_style` / `patch_style` | 单独寻址 CSS 块 | **这是 CSS 折叠的前提** |
| HTML | `set_node_class` | 按 selector 换 class | 让「改样式」不必改正文 |
| HTML | `write_html_with_template` | 模板 + body → 完整文档 | 见 3.4 |

**`rewrite_section` 是最典型的例子**。用户说「把第二节扩写到 800 字」，今天模型要：
`read_document`（全文 3,000 字进）→ 自己定位第二节 → 构造完整新全文 → `write_document`（3,300 字出）。
改 50 个字，付 6,300 字的钱，还有丢别节内容的风险。

有了它：`outline_document`（200 token）→ 看到「## 第二节 L45-L62，320 字」→
`rewrite_section("第二节", 新内容)`. **进 200 + 出 800，约 1/6 成本，且结构上不可能碰到别的节。**

---

## 4. 前置约束：稳定前缀（这条不做，§3 的方案会亏）

设计这一版时发现一个**已经存在的**问题，它决定大纲该放哪。

`RestAgentBackend.swift:421-424` 有三个 prompt cache 断点，注释写：

```swift
// ② system 末尾：系统提示含文档全文/技能注入，同会话内稳定
```

**这句话是错的。** `systemContext` 里有五个来源，其中至少三个每轮都变：

| 来源 | 变化频率 | 位置 |
|---|---|---|
| `state.editorSelectedText` | 用户拖一下选区就变 | `AIChatCoordinator.swift:360` |
| `MemoryService.promptSection(query:)` | **每轮按本轮原话检索，注入的条目必然不同** | `:388` |
| `DocumentContextExcerpt` | 第一轮有全文、第二轮起只有文件名 ⇒ 必变一次 | `:378` |
| `userSkillsPrompt()` / `aiCustomSystemPrompt` | 稳定 | `:393` / `:400` |

Anthropic 的缓存是**顺序前缀**：system 变了，system 之后的一切（含全部历史消息）的前缀都变了，
断点 ③（消息末尾）同时失效。**用户改一个字的选区，整个上下文缓存全废。**

而记忆那一项是 **#109 引入的**——它把原本相对稳定的 system 变成了每轮必变。这是我的回归。

**所以 §3 的「每轮注入大纲」如果直接塞进 system prompt，会继续加剧它。** 必须同时做这件事：

```swift
// system 拆两块：稳定规则打断点，变化内容放后面
system: [
  ["type": "text", "text": 规则 + 档案 guidance + 技能清单,
   "cache_control": ["type": "ephemeral"]],      // ← 断点在这里，永远命中
  ["type": "text", "text": 大纲 + 选区 + 记忆]     // ← 变化，不打断点
]
```

更彻底的做法是把变化内容挪到**消息侧**（作为本轮 user 消息的前缀），这样 system 恒稳定。
但那要改 `systemContext` 的返回形态，成本大于收益——先做上面的 system 分块。

**验收**：连续两轮之间只改选区，第二轮请求的 `cache_read_input_tokens` 应接近
（system 静态块 + tools + 历史）之和，而不是 0。

---

## 5. 接线（不碰 Runner）

```
AIChatCoordinator.systemContext
  ├─ 旧：if let tab → DocumentContextExcerpt.excerpt(全文)
  └─ 新：let profile = DocumentAuthoringProfile.resolve(fileName: tab.name)
          stable += profile.guidance
          volatile += AuthoringContextBuilder.context(for: profile, input:, includeFullDocument:)

BuiltinAgentTools.all
  └─ 不按档案过滤（理由见 §3.1 的落地修正）；新增的 9 个结构工具只在 macOS 注册
```

两处改动，`AgentRunner` 一行不改（只往并行只读白名单里加了 5 个只读工具名）。

**写入路径必须复用现有链路**：`rewrite_section` / `patch_style` / `set_node_class` /
`write_html_with_template` 的落盘统一走 `AuthoringWrite.commit` —— 它做四件事：
取当前内容（tab 内存优先）、`reviewFileWrite` 审阅、审阅后的合并内容落盘、写前校验
tab 没被切走。这份逻辑原本散在 `write_document` / `patch_document` 里，复制第三遍
必然走形，所以抽成一份（`DocumentTools` 现在也调它）。

---

## 6. 失败模式

| 情形 | 处理 |
|---|---|
| 标题路径重名（两节都叫「小结」） | `rewrite_section` 返回**所有**匹配的行区间，要求带上级路径消歧；不猜 |
| 文档无标题（纯段落） | `outline_document` 退化为「段落序号 + 首句」，不返回空 |
| HTML 无 CSS 块 | 折叠提示写「无独立样式」，`read_style` 返回空而非报错 |
| 模板 id 不存在 | 报错并列出可用 id（现有 `get_html_template` 已是这个行为） |
| `body` 里自带了 `<style>` | 拒绝并提示「样式请用 patch_style」——否则模板引用式失效 |
| 大文档（> 200 节） | 大纲分页（`outline_document(page:)`），不一次全给 |

---

## 7. 验收判据（都要能跑）

1. **MD 成本**：「把第二节扩写到 800 字」全链路 token 消耗 ≤ 全文路径的 **1/5**（用 `state.usage` 对比）。
2. **HTML 成本**：改一句正文的上下文里，CSS token = 0（除显式 `read_style`）。
3. **模板零注入**：`write_html_with_template` 路径下，对话历史中不出现 `<style>` 块内容。
4. **plain 不变**：`.txt` 等未命中档案时，system prompt 与工具集与当前**逐字节一致**（守卫测试）。
5. **结构工具正确性**：`rewrite_section` 在「重名标题 / 无标题 / 嵌套标题」三种语料下不误改他节（可复现的固定语料 + 变异验证：把路径匹配改成模糊匹配应变红）。
6. **写入不绕过审阅**：`rewrite_section` / `write_html_with_template` 在 GUI 下必须触发 diff 审阅（用 mock context 断言 `reviewFileWrite` 被调用）。

---

## 8. 不做

- **不复制 `AgentRunner`**（理由见 §2）。
- **不做 DOM 可视化编辑**：超出「写作助手」范围，且要一套新的 UI 模型。
- **不让模型生成 CSS**：它会，但那是每次付费且易漂移；模板引用式把这件事变成确定性代码。
- **不做第三种档案**（`.tex` / `.rst`）：两种覆盖 99%，加第三种是给没人用的场景付维护成本。
- **不在这一版做 HTML 的增量 patch**（`patchDOM` 那套是预览层的，不复用到写入层）——若
  `set_node_class` 证明不够用再说。

---

## 9. 顺序

| 步 | 内容 | 状态 |
|---|---|---|
| 1 | `DocumentAuthoringProfile` + plain 档案（行为不变的骨架） | ✅ |
| 2 | HTML 档案：CSS 折叠 + `read_style`/`patch_style` | ✅ |
| 3 | `write_html_with_template`（模板引用式） | ✅ |
| 4 | MD 档案：`outline_document` + `read_section` | ✅ |
| 5 | `rewrite_section`（含重名/嵌套消歧） | ✅ |
| 6 | `html_outline` + `read_node` + `set_node_class` | ✅ |

**为什么第 6 步也一起做了**：CSS 折叠之后，如果只有 `read_document` 能读正文，模型
改一句话就会把整段 `<style>` 重新拉回上下文——折叠白做。所以「读节点」与「改 class」
不是可有可无的增量，是折叠能否成立的前提。

---

## 10. 前提

这套设计只在「Meditor 的 AI 是**写作助手**」这个定位下成立。若定位是「本地轻量 coding agent」，
则 `outline_document`/`rewrite_section` 是无用功，该补的是测试运行、git 操作、多文件重构。

**2026-10-25 已确认按写作定位推进**（"从写作 writing assistant 来说"）。因此 §3.2–3.5 的工具设计
成立，§9 的六步全部在范围内。

但要留一条后路：`DocumentAuthoringProfile` 的 `plain` 档案 = 今天的全部行为。若将来转向 coding agent
定位，把 `.md` 也映射到 `plain` 即可回退，不影响已写的结构工具（它们仍然可选调用）。

---

## 11. 实施记录（0.13.9）

### 11.1 删掉了「工具白名单」

设计稿 §3.1 原本要让档案决定「本次注册哪些工具」。实现时推翻：**全部文档工具都带可选的
`filename` 参数**，也就是说它们的作用对象与当前 tab 的类型无关——在 `.md` tab 里说
「把这份报告导出成 HTML」是写作场景的常见请求，按 tab 类型把 HTML 工具藏起来会让它无解。
工具的取舍仍交给 `AgentToolBudget`（按本轮原话打分裁剪 MCP 工具）。

代价是工具定义的总 token 没降（26 个内建工具约 4K token）。这个账本该记在 M2.1
（工具预算按 token 而不是条数）上，不该靠档案硬藏。

### 11.2 9 个结构工具只在 macOS 注册

tool 文件没有加进 iOS 工程，注册点包在 `#if os(macOS)` 里。理由与 `RunCommandTool` 相同：
iOS 端零自动化测试，而新增的写入面有 5 个（`rewrite_section` / `patch_style` /
`set_node_class` / `write_html_with_template` / 加上既有的写工具），把没有验证能力的
平台接上写入面，等于把「确认链路有没有漏」交给运气。iOS 工具面维持 14 个。

### 11.3 §4 的 prompt cache 只修了一半

做了：system 拆「稳定前缀 + 易变尾部」，Anthropic 的 `cache_control` 断点落在稳定前缀末尾；
OpenAI / ClaudeCLI 在序列化前把分段标记剥掉。

**没做**：易变内容仍留在 system 里 ⇒ 它之后的全部历史消息（断点 ③）照样每轮失效。
彻底解法是把易变内容移进本轮 user 消息，那要改 `systemContext` 的返回形态与
`agentHistory` 的口径（历史里每轮都会多存一份选区快照），成本大于本次收益。

**收益边界（如实标注）**：保住的是「tools + system 稳定段」这段前缀缓存；消息侧没有改善。
本机没有可用的 API key，**没有在真实请求上验证 `cache_read_input_tokens` 的变化**——
这一条只有单测钉住了 wire 形状（`AuthoringPromptTests` 的两条），没有线上数字。

### 11.4 `get_html_template` 降级为「只看」

保留工具，但描述改成「仅供查看模板」，并指向 `write_html_with_template`。原因见 §3.4：
让模型逐字复制 6K 字符的样式表是纯机械且必然出错的活。

### 11.5 仍未做

- **MCP 无头路径没有按扩展名分派**（§5 原计划）。无头工具的写入面本来就被
  `MCPToolCatalog.excludedToolNames` 挡住了（新加 4 个写工具也进了排除集），所以
  现在只是「拿不到大纲与结构树」，不是「写坏文档」。
- **HTML 的增量 patch**（§8 已明确不做）。
- **选择器只支持简单形态**：`#id` / `.class` / `tag` / `tag#id` / `tag.class` / `:nth(n)`。
  后代选择器与属性选择器没做——实现半套 CSS 匹配会引入一整套要自己维护的语义，
  而现有形态足够表达「定位到哪个节点」。
- **大纲超过 80 节时截断而不是分页**（§6 里写的是分页）。真实文档实测最多 28 节，
  分页在 80 节以上才有意义，等真的出现再加。
- **`.md` 之外的 MD 变体（`.mdx` 等）走 plain**。

### 11.6 验收

- 新增 5 个测试文件、74 条用例（`MarkdownStructureTests` / `HTMLStructureTests` /
  `HTMLTemplateAssemblyTests` / `DocumentStructureToolTests` / `AuthoringPromptTests`）。
- 全量 1792 例 0 失败（本机跑 `swift test --skip test_echoCommand_returnsOutput`：
  该例本机必超时、CI 上通过，与本次改动无关）。
- 变异验证 4/4 转红：整节替换连标题一起换、plain 不走预算截取、稳定段不打缓存断点、
  不重建侧边栏导航。
- `plain` 的守卫是**把改造前那段代码原样抄进测试当参照实现**，逐字节比对 6 组输入。

### 11.7 CI 闸门踩到的（本机看不出来的那类）

本机没装 swiftlint，`Lint` 这一步只能在 CI 上验。第一次跑红了两类、共 6 条：

- **`large_tuple` ×5**（默认规则，2 元上限；`.swiftlint.yml` 的 `disabled_rules` 里**没有**它）。
  导航锚点原写成 `(id: String, title: String, level: Int)` 三元组，回调整体换成
  具名 struct `HTMLSectionAnchor`。三个字段都删不掉——`level` 要一路传到 `navigationHTML`
  做缩进——所以这不是「拆成两个二元组」能绕的。
  **教训**：这个仓里写三元组就是红的，宁可先建个 struct。
- **`trailing_whitespace` ×1**：`{` 之后多余一个空格。这条不受 `disabled_rules` 影响。
  **核验方式**：本机 BSD `grep -E '[ \t]+$'` 里的 `\t` 不解释成制表符（会退化成字母 `t`，
  把 `ExportFormat` 这类词尾也报出来，全是假阳），要用 Python 逐行 `line != line.rstrip()`。
  另注：`.swiftlint.yml` 排除了 `Tests`，测试文件的行尾空格不会被这条抓。
