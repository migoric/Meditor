# MEditor AI 路线图

> 状态：living document，随版本更新。最后修订 2026-10-25（对应 0.13.9 之后）。
> 姊妹文档：`product-roadmap-prd.zh.md`（产品主线，V1–V3 是 AI 之前定的）、
> `ai-memory-design.md`（M1 的设计稿）、`ai-document-agents-design.md`（M1.5 的设计稿与实施记录）。

## 0. 这份文档补的是什么

`product-roadmap-prd.zh.md` 的 §8 功能拆解里没有一条涉及 agent —— 它成文于 AI 面板之前。
AI 这部分的能力边界与后续计划此前只散落在 README 的 Roadmap 和提交历史里，
结果是**同一个缺口会被反复当成新发现**（包括被我自己发现两次）。

这份文档只做三件事：写清**已经有什么**、**明确不做什么**、**接下来按什么顺序做什么**。

---

## 1. 边界（先写「不做」，否则后面的清单会退化成抄竞品）

AI 这块的取舍可以压成一句话：**agent 是编辑器的一部分，不是编辑器外面的一个聊天窗。**

由此推出四条硬约束，它们决定了下面每一条「不做」：

1. **本地优先**：文档、记忆、运行记录都在用户机器上。没有账号体系，没有云端记忆。
2. **零运行时依赖**：仓根 `dependencies = {}`。任何需要引入第三方客户端的方案都只能以
   「配方 + 文档」存在，不进主进程。
3. **写前必审阅**：agent 的每一次文档写入都走 diff 审阅；记忆写入是唯一例外（见 §3.1 的理由）。
4. **不跟协议跑**：MCP 等外部协议只在「生态已稳 + 对本产品形态有收益」时跟进。

| 不做 | 理由 |
|---|---|
| 向量检索 / embedding RAG | 记忆与文档的量级是「几十到几百条 / 单篇」，关键词 + 中文 2-gram 足够；引入 embedding 会打破约束 2，并撞 `product-roadmap-prd.zh.md` §9 对「笔记双链系统」的非目标设定 |
| 云端记忆 / 账号同步 | 撞约束 1；PRD §9 把「云同步平台」列为非目标 |
| 端侧小模型做主力 | 质量与成本都不划算，且与 BYOK 的定位冲突。唯一可考虑的窄口是「会话标题生成」这类对质量不敏感的活，不值得单列 |
| 追 MCP 2026-07-28 的无状态化 | 那一版的核心是删握手、删 session，解决的是**云端水平扩展**。本产品的 MCP 服务端是 stdio 本地进程，收益为零，成本是重写握手 + 传输层。见 §5.5 |
| 插件市场 / 双链 / 实时协作 | PRD §9 已有明确结论，不重复讨论 |
| 自动应用 agent 的写入 | 与约束 3 直接冲突 |

---

## 2. 已经有的（截至 0.13.9）

| 能力 | 落点 | 备注 |
|---|---|---|
| Agent 多轮循环 + 26 个内置工具（macOS）/ 14 个（iOS） | `AgentRunner` / `BuiltinAgentTools` | 只读工具可并行，写工具串行（确认弹框依赖串行语义） |
| 三种后端：OpenAI 兼容 / Anthropic / Claude CLI | `Backends/` | BYOK，无内置额度 |
| 写前 diff 审阅 + run 级回滚 | `WriteDiffPreview` / `AgentRunCheckpoint` | 回滚目前只在当次进程内有效，见 M4 |
| 上下文预算裁剪 | `AgentHistoryBudget` | **只有裁剪与丢弃，没有摘要压缩**，见 M2 |
| HITL（命令风险分级 + 写入确认） | `ShellContext` 协议 | 默认 fail-closed |
| Skills（`SKILL.md` 渐进披露） | `AgentSkillStore` / `LoadSkillTool` | 全局 + 工作区两级，可导入导出 |
| MCP 双向 | `MCPServer`（stdio）/ `MCPClient`（stdio + HTTP） | 客户端 `2025-03-26`、服务端 `2025-06-18`，两端版本不一致，见 M5 |
| 运行轨迹（默认关） | `AgentRunTrace` | 只记元数据，不含正文 |
| 工具定义预算（MCP 相关性裁剪） | `AgentToolBudget` | 门槛 32 条而内置只有 15 ⇒ **当前永不触发**，见 M2 |
| 项目记忆（捕获 / 巩固 / 检索 / 遗忘 / 审计） | `Services/AI/Memory/` | 0.13.8，见 M1 |
| 文档类型分档（MD 大纲 / HTML 结构树与 CSS 折叠 / 模板引用式） | `Services/AI/Authoring/` | 0.13.9，见 M1.5 |

---

## 3. 里程碑

### M1 · 项目记忆（已交付，2026-10-25）

**为什么先做这个**：2026 年这个场景最贵的缺口不是「模型不够聪明」，是「每次对话都从零开始」。
写作任务的约束（术语、文风、章节骨架、已定的决策）**跨会话稳定**，却被每一轮重新猜。

**交付**

- `<workspace>/MEDITOR.md`：人可读、可进 git、可手改。两段——`## 约定`（人写，原样注入）
  与 `## 记忆`（agent 捕获，按相关性检索注入）。
- 旁挂 `.meditor/memory-state.json`：命中次数 / 最近使用 / pin / 出处。不进 Markdown，
  否则每次注入都改文件，git diff 全是噪音。
- 工具 `save_memory` / `recall_memory`；设置 → 记忆面板（分组、搜索、编辑、pin、删除、恢复归档）。
- 检索是纯函数 `MemorySelector.select`：关键词（中文 2-gram）+ 种类权重 + 新鲜度 + 使用频次，
  预算 800 token，pinned 优先。
- 遗忘 = **归档**，不是删除；条件是非 pinned + 90 天没用 + 一次都没被检索到过。

**显式边界**

- 记忆写入**不走 diff 审阅**（它是 agent 的笔记本，不是用户的文档）。安全网是：单条 500 字符、
  单 run 最多 8 条、注入同级提示注入消毒、面板可逐条撤销。
- iOS 暂不注册这两个工具：记忆层还没进 iOS 共享源码清单（`check_ios_shared_sources.py`）。
- 没有记忆文件时，system prompt 与之前**逐字节一致**（有守卫测试）。

**验收**：`Tests/MEditorTests/AIMemoryTests.swift`，18 条，覆盖设计稿 §8 的七条判据；
关键两条做过变异验证（去掉 per-run 限额 / 去掉「用过就不归档」都会让用例变红）。

---

### M1.5 · 文档类型分档（已交付，0.13.9）

**为什么不是 M2**：它不解决「上下文超预算」，解决的是「上下文里一半是没用的东西」——
HTML 的 `<style>` 占模板 60%，而模型改一句话也得为它每轮付费。

**交付**

- `DocumentAuthoringProfile`（纯值）：按扩展名分派 markdown / html / plain。
  **plain = 改造前逐字节不变**（参照实现抄进测试做比对），也是回滚开关。
- Markdown 侧：`outline_document` / `read_section` / `rewrite_section`。首轮注入大纲
  （每节 11–16 token，实测压缩比 1/13 ~ 1/16），整节替换不再需要「读全文 → 拼全文 → 写全文」。
- HTML 侧：`html_outline` / `read_node` / `read_style` / `patch_style` /
  `set_node_class` / `write_html_with_template`。CSS 折叠（不进上下文）+ 语义 body 交给
  模板展开，`get_html_template` 降级为「只看」。
- `AuthoringWrite`：五处写入路径共用一份「取内容 → 审阅 → tab 锁定 → 落盘」，
  `write_document` / `patch_document` 也改调它。
- system prompt 分「稳定前缀 / 易变尾部」，Anthropic 的缓存断点落在稳定前缀末尾
  （只修了一半，见设计稿 §11.3）。

**显式边界**

- 结构工具**只在 macOS 注册**（iOS 14 个工具不变）：iOS 端零自动化测试，不接新的写入面。
- 档案**不裁剪工具集**：文档工具都带 `filename`，作用对象与 tab 类型无关
  （`.md` tab 里「导出成 HTML」很常见），按类型藏工具会让这类请求无解。
- 选择器只支持简单形态（`#id` / `.class` / `tag` / `:nth(n)`），不做后代选择器。

**验收**：`MarkdownStructureTests` / `HTMLStructureTests` / `HTMLTemplateAssemblyTests` /
`DocumentStructureToolTests` / `AuthoringPromptTests`，74 条；关键 4 处做过变异验证。

---

### M2 · 上下文工程：压缩与工具裁剪

这两件事共同点是**机制已经存在，但没真正生效**——成本低、收益直接。

**M2.1 工具按相关性裁剪真正启用**

现状：`AgentToolBudget.select` 的门槛是 `tools.count > 32`，而内置工具只有 15 个，
`isExternal` 只认 `mcp__` 前缀 ⇒ 不挂 18 条以上 MCP 服务器时，这段代码一次都不执行。

改法：内置工具也参与打分，但设「保留下限」（文档主路径 6 个永不裁）；预算从「条数上限」
改成「工具定义 token 预算」，更贴近真实成本。

**验收**：15 内置 + 40 MCP 时，wire 里工具定义 token ≤ 预算，且 `read_document` /
`write_document` / `patch_document` / `search_document` / `read_file` / `list_files` 必在。

**M2.2 上下文压缩**

现状：两级裁剪——早期长 tool result 换成一个占位符，仍超预算就从最老一端整轮丢弃
（`AgentHistoryBudget.swift:107-160`）。**全仓没有一次 LLM 摘要调用。**

问题：占位符那句话对模型几乎无用，它不知道被省掉的是哪个文件、哪条结论。
长任务里「用户 20 轮前说的标题必须是 X」会被静默丢掉。

改法：在「整轮丢弃」之前插一级 compress——对将被丢弃的轮次做一次小模型摘要，产出结构化块
（已确认的约束 / 已改的文件及行号 / 未完成的 TODO），并**保留可回溯指针**，让模型知道要重读什么。
摘要失败时降级回原策略。

**验收**：构造 60K 预算下的长任务，压缩后仍能正确回答「第一轮设定的约束」。

---

### M3 · 隔离与可核验

**M3.1 只读子代理 `explore`**

子代理的价值不是并行，是**上下文隔离**：它读完 40 个文件，只有 1K token 摘要回到主上下文。
本产品缺这一环——`search_workspace` 一次返回一堆片段，全灌进主对话。

改法：`explore` 内部起一个受限 runner（只读工具子集、独立 history、`maxSteps ≤ 8`），
返回摘要 + 证据指针。注意两点：取消/超时必须传给子 runner；MCP 无头模式必须排除它，否则可递归。

**验收**：一次「找出工作区里所有提到 X 的文件并总结差异」的请求，主上下文增长 < 2K token。

**M3.2 引用可核验**

素材全齐了但没串起来：`search_document` 返回 `L{n}: 内容`、`read_document` 支持行区间、
diff 审阅本来就有行号。缺的是**把「这条改写依据哪几行」呈现给用户**。

改法：写工具返回里带 `evidence: [{path, startLine, endLine}]`；diff 审阅面板每个 hunk 显示
「依据：`file.md` L42-57」，可点击跳转。

**为什么值得**：这个品类的差异化不在「能不能生成」。把「每一步可核对」做出来，
「本地文件 + agent 能跨文件改」这个位置才立得住。

---

### M4 · Harness 连续性

**M4.1 checkpoint 落盘**

现状：`AgentRunCheckpoint` 的注释自己写明「只存内存，App 重启后不恢复」，
而 README 承诺的是「One-click rollback of an Agent run」。agent 改坏 5 个文件之后 app 崩了
⇒ 回滚按钮消失。

改法：把 `AgentFileSnapshot.preWrite` 序列化到 `<support>/checkpoints/<runID>/`（沿用单文件
1MB 上限），启动时扫最近 N 个可回滚 run 进「历史」面板。

**验收**：`kill -9` 后重启，仍能回滚上一次 run。

**M4.2 运行轨迹接上读取方**

现状：`AgentRunTrace` 落盘但**应用内没有任何 UI 读它**（`loadAll()` 全仓只有测试调用）。
这是「只写不读」的典型：能力看着交付了，实际只是一个磁盘日志。

改法：设置 → AI 里加一个「最近运行」列表（时间、模型、步数、耗时、成败、token），
失败的那几次带错误摘要。顺带把 M1 的 `memoryIDsUsed` 也记进去，让「这次用了哪几条记忆」可回溯。

---

### M5 · 协议与平台跟进（观望为主）

**M5.1 先把自家两个版本号对齐**

客户端声明 `2025-03-26`，服务端声明 `2025-06-18`——**同一个仓里两个协议版本号**，
客户端的 `capabilities` 还是空字典。这是个没人发现的技术账：先对齐到 `2025-06-18`，
并让客户端如实声明自己支持的能力。

**M5.2 确认流的安全降级**

现状：`MCPHeadlessContext` 对写入**恒放行**（`confirmFileWrite` 返回 `true`），
safe 级命令也直接 `true`。这是「确认职责在宿主」的显式取舍，但宿主（Claude Desktop 等）
实际上不做文件写入确认 ⇒ 远程 MCP server 可以让本应用静默写盘。

改法：无可信 UI 时，需要确认的操作**降级为拒绝 + 记日志**，而不是放行。
2026-07-28 spec 的 Multi Round-Trip Requests（`resultType: "input_required"`）是标准做法，
但即使不跟协议版本，这条降级也该先做。

**M5.3 iOS 跟进**

记忆层进 iOS 共享源码清单（`Sources/MEditor/**` 的 40 个 .swift 要同步扩）需要手工改 pbxproj，
所以排在最后。iOS 目前的 AI 面是「单文档 + AI 改文阅读器」，缺记忆的痛感远低于桌面。

---

## 4. 顺序的依据

不是按「缺什么」排，是按**挡住谁**排：

| 里程碑 | 挡住谁 | 成本 |
|---|---|---|
| M1 记忆 | 所有做长文档的人——每轮都要重新交代口径 | 已交付 |
| M2 压缩 + 工具裁剪 | 做长任务的人（>30 轮）；挂多个 MCP 的人 | 各 1–3 天 |
| M3 子代理 + 引用 | 做大范围改写的人（跨多文件） | 5–8 天 |
| M4 harness | 依赖回滚的人（改坏之后的唯一退路） | 2–4 天 |
| M5 协议 | 接远程 MCP server 的人 | 观望为主 |

---

## 5. 这份文档自己怎么防腐

- 每条「不做」都必须带出处（PRD 章节 / 设计稿 / 提交）。**没有出处的「不做」是待办。**
- 每条里程碑都必须带**验收判据**，判据必须是能跑的东西（用例名 / 命令 / 可观测指标）。
- 能力表里的数字（26 个工具、800 token、32 条门槛）都在代码里有唯一出处；
  改代码时同步改这里，`scripts/check_docs_consistency.py` 会盯一部分。
