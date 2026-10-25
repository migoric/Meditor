# Changelog

本文件记录 MEditor 的对外变更。格式按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号按 SemVer（`0.x` 阶段：破坏性变更走 minor）。

> ⚠️ 本文件从 **0.12.0** 起建立。更早的版本在文件创建前发布，只有 GitHub Release 上那条
> 自动生成的记录（`release.yml` 用 tag 区间的提交标题拼的），见
> <https://github.com/migoric/Meditor/releases> —— 不在这里补写，补写就等于编历史。
>
> 发布时的 GitHub Release 正文由 `release.yml` 从提交标题自动生成（见 `CONTRIBUTING.md`「发版流程」）；
> 本文件是**人写的、按变更性质归类**的那一份，两者互补。

## [Unreleased]

### Added

- **项目记忆**：agent 现在会记住跨会话仍然成立的东西（约定 / 术语 / 偏好 / 决策 / 事实），
  不再每轮从零猜口径。落在工作区根的 `MEDITOR.md`——纯 Markdown，能直接手改、能进 git：
  `## 约定` 段是你写的散文（原样注入），`## 记忆` 段由 agent 通过 `save_memory` 追加，
  每条带 `[#id]` 便于在回答里引用与回溯。每轮只注入**与当前请求相关**的几条，
  受 800 token 预算约束，pinned 条目优先；计数器（用过几次、最近使用、出处）旁挂在
  `.meditor/memory-state.json`，不进正文。90 天没用过且一次都没被检索到的条目会**归档**
  （不是删除），可在 `设置 → 记忆` 里恢复。没有 `MEDITOR.md` 时 system prompt
  与之前逐字节一致。
- 新增工具 `save_memory` / `recall_memory`（仅 macOS；iOS 的记忆层尚未进共享源码清单）。
- 新增 `设置 → 记忆` 面板：分组、筛选、行内编辑、固定、删除、恢复归档。
- 新增 `docs/ai-roadmap.md`（AI 能力边界 + 里程碑）与 `docs/ai-memory-design.md`（记忆设计稿）。

### Fixed

- **记忆的三处失联**（同一批交付里自查出来的）：
  - **在编辑器里改 `MEDITOR.md` 不生效**：`MemoryService.activate` 只按「工作区根」判空操作，
    同一个根就一直用内存里的旧副本。于是改完约定保存后，agent 下一轮注入的还是旧内容，
    直到重启 App——注入的内容和你眼前看到的文件不一致，且没有任何报错。`git pull`
    拉下团队约定同理。现在按**文件修改时间**判失效，自己写入时同步哨兵（否则自杀式重读
    会把单 run 限额清零）。
  - **`设置 → 记忆` 的「重新载入」是空按钮**：它调的是同一条空操作路径，点了毫无反应。
    改走 `reload`。
  - **删一条记忆会连带删掉另一层的同名条目**：条目 id 是内容寻址的，同一条正文既在工作区
    又在全局时两层 id 相同，而写操作按 id 遍历两层。现在 `setPinned` / `update` / `delete`
    / `restore` 必须带 `scope`，面板用 `scope + id` 作唯一键。
- **预览里点链接的两条死链**：
  - **Markdown 预览的页内锚点点了毫无反应**：预览模板给页面设了
    `<base href="meditor-asset://…">`，纯 `#小节` 链接被改写成 asset URL 后 WebKit
    既不导航也不滚动（连 `decidePolicyFor` 都不回调）。HTML 预览早在 `HTMLAnchorGuard`
    里修过，markdown 这份没装守卫。同时标题一直没有 `id`——marked v12 起不再产出
    header id，所以 `[跳到某节](#某节)` 即便能跳也无处可落。现在标题按 GitHub 规则
    生成 id（小写、去标点、空白转 `-`、重名加 `-1`），守卫以外部脚本
    `scripts/anchor-guard.js` 注入（模板 CSP 是 `script-src 'self' file:`，内联会被拦）。
  - **跨文档链接 `other.md#小节` 是死链**：同一个 `<base>` 改写后，`PreviewLinkNavigator`
    把所有「带 fragment 的 asset URL」一律取消。现在按「去掉 fragment 后是否落在真实
    文件上」区分：是文件就外开（`.md` 默认打开者为本应用 ⇒ 回 app 开 tab），是目录
    （真正的页内锚点残渣）才取消。

- **AI 改完文档后，确认界面被 AI 面板盖住**：diff 审阅（逐块接受/跳过，HITL 唯一的
  确认入口）挂在文档区，而助手浮层挂在更上一层——420×620 的面板叠 30% 全窗遮罩，
  把整个确认界面压住了，表现是「AI 说改好了、界面没变」。现在审阅期间浮层整层让位
  （透明 + 不接收点击/键盘，Esc 归审阅界面），结束原样回来；**不卸载视图**，
  否则输入草稿与待发图片会丢。tab 条的配套压暗也一并跟随。
- **切走再切回，mermaid 图永久空白**：mermaid 是视口懒渲染（`IntersectionObserver`，
  滚到才画），而缓存命中恢复会把 `contentEl.innerHTML` 整体换掉，上一轮挂的观察器
  随旧节点一起失效 ⇒ 快照里没滚到的那几张再也没人画。现在恢复时按源码重新提取并
  重挂观察器（已渲染的图没有占位 div，幂等）。

## [0.13.7] - 2026-10-24

### Added

- **运行轨迹（默认关）**：设置 → AI → 高级里打开后，每次 agent run 结束会往
  `~/Library/Application Support/MEditor/traces/` 写一条 JSON 轨迹——工具序列、
  成败、耗时、token、停滞诊断。**只记元数据**：参数与结果只留字节数，正文一律不落盘
  （轨迹是排障材料，不该变成第二份文档副本），保留最近 50 条。
- **Agent 离线金标准**（`AgentEvalGoldenTests`）：把「模型说了什么 → 工具按什么顺序
  被调用 → 落盘几次」写成一张场景表，改 agent harness 时先跑它。与单测的分工是
  「整轮交互是否还是原样」，而不是某个函数对不对。

### Changed

- **工具定义有了预算（上限 32 条）**：MCP 挂几台就可能把工具表顶到 40+ 条，而工具
  定义是每轮重发的。超过上限时按本轮原话给 MCP 工具打相关性分数，只保留命中的，
  其余折叠并在系统提示里点名。**只在有把握时裁**：一个词都没命中（典型是中文提问
  对英文工具描述）就原样放行——藏掉唯一能用的工具比多花 token 更糟。内置工具永不裁。

### Fixed

- **选「Anthropic Claude」后发消息必 404**：预设下拉只写 baseURL 和 model，从不写
  provider，于是线格式仍是 OpenAI（打 `api.anthropic.com/v1/chat/completions`，
  那个端点不存在），而「测试连接」是按 baseURL 嗅探成 anthropic 的，所以测试通过、
  一发就失败。连带后果是 prompt caching（`cache_control` 断点）一次都没生效过。
  现在选预设会把 provider 一起切过去，设置里多一个「远程 · Anthropic 直连」选项；
  老版本留下的「openai + anthropic baseURL」组合会在解析配置时自愈成 anthropic
  （自建反代与「已关闭」不受影响）。守卫：`AIProviderWireTests`。
- **预览可能显示上一个文件的内容**（切 tab 时）：`renderInto` 的 no-op 短路拿「上轮
  join 产物」和本次产物比字符串，而这个状态是**整个 WebView 的 JS 上下文级变量**；
  预览的 webview 又跨文档复用（切 tab 只换内容，不重建）。缓存命中恢复那条路径
  直接写 `contentEl.innerHTML` 却没更新它 ⇒ 出现「DOM 是 B、记录是 A」的失同步，
  之后切回 A 时短路误判成「没变化」，预览就停在上一个文件上。现在缓存恢复后
  显式作废短路状态。触发面不小：文档超过 120KB 永不进缓存，或缓存上限只有 3 条
  （开四个以上文件来回切即可命中）。守卫：`PreviewStalePreviewTests`。
- **含代码块的文档每次预览更新都整体重建所有代码块**：Copy 按钮挂在 `pre` 里，
  patchDOM 比较 PRE 的 textContent 会带上按钮文字（"Copy"）导致永不相等——
  每帧替换全部 PRE 并被迫重高亮。现在比较时剥掉按钮与 hljs 痕迹
  （比 `code` 子节点的 className + textContent），未变化的代码块节点原样保留；
  高亮同时改为幂等（已高亮的块跳过）。
- **缓存恢复页可能永久缺代码高亮**：预览的缓存命中路径（切 tab 回来）此前不做
  高亮；快照又是 idle 落盘的，可能存下未高亮的 HTML。命中恢复现在幂等补一遍。
- **预览分块管线与 marked 的三处围栏口径对齐**（低频但真实的渲染错误）：
  ① 反引号围栏的 info 含反引号时该行不是围栏（CommonMark），此前切块器误认开栏，
  教程类文档里「``` 或者 ```javascript」这种写法会让代码/段落错位；
  ② `~~~mermaid` 是合法围栏但不应出图，此前文档里另有 ``` 时会被摘成 diagram
  （与 Swift 侧 MermaidBlocks 口径矛盾）；③ blockquote / 列表项里的链接引用定义
  漏检，走分块解析后链接静默丢失。顺带修掉整篇解析的旧 bug：结构行补空行的
  预处理此前不识别围栏，会往代码块内容里插空行。
- **mermaid 偶发永久缺失**：按需拷贝 `mermaid.min.js` 失败（比如缓存目录恰好被并发
  清理）时「已就绪」标志也会被置位，本进程内 mermaid 图从此不再渲染。现在只有
  真的拷上了才置位，失败留待下次触发重试；按需拷贝也纳入缓存目录写锁，
  与并发清理互斥。
- **AI 打开超限文件时的报错如实了**：`open_file` 对「文件存在但超体积上限」
  此前一律回「未找到文件」，会误导模型放弃或绕路；现在区分两种失败并给出
  替代路径建议。

## [0.13.6] - 2026-10-22

**这一版只有一件事：下载包小了 4.5 MB，功能和视觉都没有变化。** 13.57 MB → 9.27 MB
（-31.7%），装到磁盘上 47.7 MB → 22.5 MB。三处改动都是删东西或重新打包（符号表、
一份零引用的压缩副本、图标里的 PNG 编码），**没有碰一行 Swift**，也没有改任何运行时
行为。代价只有一条，说清楚：`strip` 之后「拿地址回查函数名」这条路断了 —— 而那条路
要 dSYM 才成立，发布包从来没有 dSYM，所以实际损失是零。

### Changed

- **下载包从 13.57 MB 降到 9.27 MB（-31.7%），装到磁盘上从 47.7 MB 降到 22.5 MB。**
  （13.57 MB = 0.13.5 的 `MEditor-v0.13.5.zip`（14,226,170 B）；9.27 MB = 本版
  `MEditor-v0.13.6.zip` 的实测 9,716,571 B，同时被更新通道 `update feed verified`
  核过一遍。本地走完整 `bundle.sh` 再按 CI 同款 `ditto -c -k --keepParent` 打出来是
  9.12 MB，与发布包差 176 KB，全部来自 Sparkle 框架版本差异 —— 引用时以发布包为准。）
  三处，都不动功能：

  ① **发布包里的可执行文件剥掉符号表**（`scripts/bundle.sh` 在 lipo 之后、签名之前
  `strip -x`）。universal 二进制 38.76 MB → 14.71 MB，压缩后下载体积 9.42 → 6.43 MB
  （本节这两个数是 0.13.5 的包实测的；本地重建的包是 36.40 → 14.78 MB）。
  删掉的是 `__LINKEDIT` 里的 nlist 数组与字符串表，即「名称 → 地址」的索引；**代码段
  逐字节不变**——比较 load commands 之后到 `__TEXT` 末尾的 6,546,568 字节，两个文件的
  sha256 相同，`__swift5_*` 元数据段也一个不少（Swift 的反射不依赖符号表）。代价仅限
  「拿地址回查函数名」，而这条链要 dSYM 才成立，发布包从来没有 dSYM。同一个包里的
  Quick Look 扩展一并 strip。

  ② **删掉 `Preview/mermaid.min.js.gz`（883 KB，无引用）**。它是 6 月那次「存 gzip、
  首次用时解压」方案（`b9dc09c`）的遗留：后来加载路径改成 `PreviewAssetMirror` 直接
  按需拷贝明文 `mermaid.min.js`，解压代码已全部删除（全仓搜 `gunzip|Gzip|decompress`
  零命中），只剩这份压缩副本还躺在 `Resources/` 里被整目录复制进包。等于同一份文件
  存了两遍，而 gz 在 zip 里压不动，883 KB 全额计入下载体积。

  ③ **`AppIcon.icns` 无损重压**（新增 `scripts/optimize_appicon.py`）：992,502 B →
  659,420 B。原文件各层 PNG 用的是低效编码（1024px 那层单层 565 KB）；`iconutil` 重打包
  会把 PNG 重新编码回去（642 KB 的 iconset 打回去仍是 969 KB），所以脚本按 icns 容器
  格式逐块改写，条目顺序与类型不变，并逐层比对像素必须完全一致。

  ⚠️ 没做的三件，理由记在这里免得反复讨论：**只发 arm64**（能再省约 3.3 MB，但砍掉
  Intel Mac 支持 —— 2026-10-22 已明确否决：本机就是 Intel Mac，Universal 是支持承诺
  不是开销；改为由 CI 的 `Build (x86_64)` 守着这条能编）、**mermaid 换按需构建**
  （可省 0.3–0.6 MB，要引入打包流程且渲染
  结果需要两端重新对齐）、**删 Sparkle 的 Installer.xpc**（仅 40 KB，且属于框架内部）。

## [0.13.5] - 2026-10-22

**这一版全是「看起来没问题、实际有代价」的东西。** 一是长文档打字变慢：上一版给分块器
加了「切完再合」，合的成本却随规模平方增长，列表类文档反而比不分块慢 12 倍；二是 AI
改完一段后那一次段落对比，800KB 的文档要卡 0.4 秒（`-O`）/ 近 4 秒（`-Onone`）；三是
正文里只要**提到** mermaid 围栏的写法（行内代码里的、被外层围栏包着的、教程里举例的），
后面一长段内容会整段消失——不是退化成代码块，页面上没有任何线索，本仓库 CHANGELOG
自己就中过，实测吞掉 19,370 字符。

### Performance

- **列表类文档的预览刷新不再随规模平方变慢 —— 120KB 松散列表打字 246ms → 44ms**。
  上一版给分块器加了「切完再合」，但合并的实现是每轮把整组拼平、再对整组重扫四条判据
  （`hasListItemLine` 内部的 `split('\n')`、跨行 HTML 的 `indexOf`、块级标签的两次
  `match`）。松散列表与嵌套列表的条目之间都是空行，一份 240KB 文档会切成约 8,000 块、
  块块都要合并 ⇒ Σ O(i) = O(n²)：实测 240KB 松散列表光合并就耗 888ms，而同一份文档
  整篇解析只要 70ms —— 优化比不优化慢 12 倍；嵌套列表 1769ms vs 354ms。现在组内用数组
  累积、判据改成随合并增量维护的摘要（三条都与原判据精确等价），同一份文档降到
  **72ms / 357ms**；端到端（真 `renderInto`）冷启 271→65ms、改一段 258→55ms、
  打字 246→44ms。
  ⚠️ 归因值得记一笔：贵的是「每轮把整组 flatten 后重扫」，不是字符串拼接本身 ——
  JSC 把 `a + b` 存成 rope，纯拼接并不复制。第一次变异（只把拼接写回逐块累加、
  判据仍用摘要）测试仍然全绿，退回判据才变红，就是这个原因。
  守卫 = `testMergeStaysLinearOnListItemHeavyDocuments`（断言块路径耗时 < 整篇的 2.5 倍，
  用比值而不是绝对耗时）；变异验证 ⇒ 松散 1195ms vs 107ms、嵌套 2675ms vs 350ms，两处红。

- **AI 改文的段落对比：4,000 段文档一次 diff 从 389ms 降到 43ms**。
  `ParagraphDiffer` 求最长公共子序列用的是完整 `(m+1) × (n+1)` 的 `[[Int]]` 表，
  823KB / 4,000 段要填 16M 格、峰值 128MB——而它在每次 AI 写入后都会跑
  （审阅预览、`WriteDiffPreview`、本地历史对比）。三处改动：① **先剥公共前后缀**，
  改一段的场景 DP 从 1,440,000 格降到 1 格；② 中段用一整块 `Int32` 缓冲代替嵌套数组
  （`Int32` 够用：LCS 长度 ≤ min(m, n)，峰值内存 128MB → 64MB）；③ 逐格比较先比
  预计算的 FNV-1a 哈希、相等才做真比较。
  ⚠️ **头部不能无条件剥**。段落重复时 LCS 多解，改前的回溯会优先匹配靠后的那个
  重复段落；无条件剥前缀会改变「哪一段算改过」——差分测试直接抓到了（`["A","A","B"]`
  这类输入 400 组里挂 32 组，第一版就是这么写的）。尾部可以无条件剥（改前的回溯从
  末尾出发、相等必走对角线，尾部必然逐对匹配）；头部只在该段落**两边都唯一**时才剥，
  此时该对属于每一个最优解，对齐被钉死。唯一性用一张计数表判，整篇哈希一次。
  ⚠️ ② 单独只快约 10%：瓶颈是逐格的 `String ==`，不是表的布局。真正起作用的是 ③
  （最坏情况 389 → 84ms，几乎每段都改时也保住）。
  ⚠️ 报告 §13 记的「3,849ms + 128MB」是 **-Onone** 的数字；同一份代码 `-O` 下是
  389ms。两条都留着没改，但引用时要说清是哪个构建。
  守卫 = `ParagraphDifferTests`：把改前的整表实现原样搬进测试当**参照实现**，
  700 组随机语料（重复段落 / 唯一段落只改中段 / 尾重编辑）逐条比 `Edit` 序列；
  「前缀真的被剥掉了」用 `dpCellCount` 计数断言（改一段 ⇒ 1 格），不用耗时。
  剩下的 43ms 主要是 `splitParagraphs` 对 534KB 做两次 `components` +
  `trimmingCharacters`，是 O(n) 的旧账，没动。

### Fixed

- **正文里提到 mermaid 围栏不再把后面的内容整段吞掉**。预览会在 marked 之前把
  mermaid 围栏摘成占位元素、渲染完再交给 mermaid 画图，而配对用的是「找到
  mermaid 开栏标记 → 取**最近的**三个反引号当收尾」的惰性匹配：不看行首、不看缩进、
  不认围栏长度。于是行中间的（比如行内代码里的）、被四个反引号外层围栏包着的、
  放在 `~~~` 围栏里的标记都会被当成开栏，与后面某个代码块的开栏配成一对，中间内容
  被整段摘走当成交给 mermaid 的代码。实测在本仓库 CHANGELOG 上吞掉 19,370 字符，
  而且内容是**消失**——不是退化成代码块，页面上没有任何线索。
  现在按 CommonMark 配对：开栏行 0–3 空格缩进、≥3 个同字符、反引号围栏的 info 里
  不能再有反引号；关栏行只能有围栏字符与空白且长度不小于开栏；**所有**围栏
  （含 `~~~`、含 `swift` 这类非 mermaid 语言）都要跨过。扫描用 `indexOf` 在标记之间
  跳，代价只跟围栏个数有关（135KB 文档 0.39ms），两个串不同时出现时直接返回。
  Swift 侧 `MermaidBlocks`（写后自检用它定位待校验的块）同步到同一口径——否则诊断
  会去校验「预览根本不出图」的块，报一个用户在预览里看不见的错。
  守卫 = `PreviewMermaidFenceTests`（11 例，真 WKWebView：行内反引号 / 四个反引号
  围栏内 / `~~~` 围栏内 / 4 空格缩进 / 关栏行带文字 / 未闭合 / 大小写 / 关栏长度 /
  占位与后一段各占一行）+ `MermaidBlocksTests` 新增 7 例。

## [0.13.4] - 2026-10-22

**这一版修两件用户直接能碰到的事。** 一是分块缓存此前对真实文档形同虚设——两个上限相乘，
把 2–5KB 的段落（技术文档的主体）一条都挡在缓存外，「改一段」实际等于冷启；二是那个
从早期就存在的确认框：打开超过 1 MB 的文件问「文件较大，编辑可能较慢。仍要打开吗？」，
而它担心的降级在 150 KB 就已经发生完了，界面上却从没说过。另外修掉 AI 的
`open_document` 无条件返回 true、模型以为文件已在编辑区而实际没有的 bug。

### Performance

- **块级缓存现在对真实文档真的生效，「改一段」从 60ms 降到 9ms**。上一版把分块器修对了，
  但两个上限让缓存对目标文档形同虚设：`PARAGRAPH_CACHE_MAX_BLOCK = 2048` 意味着
  2–5KB 的段落（带表格的小节、长列表项，也就是技术文档的主体）**一条都进不来**，
  而 300 条的条目上限与它相乘，又让「加大单块上限」这条路自己把自己卡死。实测在这份
  66KB 语料上：一次编辑重算了 12 个块、命中 0 个，缓存里 12 条键加起来只有 98 字节
  （等于只缓存了几个标题）。现在预算改成按**源码字节**（4MB，单块上限 256KB），
  同样的编辑只重算 1 块、命中 136 次。
- **未闭合围栏不再回退整篇解析**。流式写入和手动敲代码块时，「刚敲下 ``` 」的那一帧
  是每一帧都会走的路径，此前 `splitBlocks` 直接返回 null ⇒ 整篇 marked + 整篇
  DOMPurify（66KB 文档 36ms）。CommonMark 里未闭合围栏本来就吞到文末，所以把
  「开栏行到文末」整体当作一块在语义上等价：同一份文档从 36ms 降到 **1ms**，
  且只解析 1 块、消毒 1 次。
- **新增渲染计数出口（`getRenderStats` / `resetRenderStats`），把「缓存命中」这类
  性能主张钉住**。此前这类主张没有守卫：把缓存整个删掉、每次整篇解析 + 整篇消毒，
  产物依然逐字节正确，出口等价性测试照样全绿。新用例断言的是
  「改一段重算 ≤2 块、命中 ≥10 次、整篇兜底 0 次、消毒次数 == 重算块数」，
  而不是耗时（CI 机器上不稳定）。

### Changed

- **打开大文件不再问「仍要打开吗」**。原来超过 1 MB 就弹一次确认框，三条理由都不成立：
  代码在 150 KB 就关掉语法高亮、512 KB 就转异步读盘 —— 该降级的在弹窗出现前早已降完，
  界面上却从不告诉用户；1 MB 这一档本身不慢（-O 下行偏移重建约 1.4 ms/MB，
  打开是 10 ms 量级）；而弹窗是在用户已经双击了文件之后才出现的，两种回答都不带来新信息。
  现在直接打开，只在**真的打不动**的地方拦：正文类 16 MB、HTML/HTM 32 MB
  （带 base64 图片的单页文章常态就过 16 MB，与 iOS 的同一取舍）。超限时报告
  「「x.log」有 47.3 MB，超过 16 MB 的打开上限」，不再占用用户一次点击。
  16 MB 这条线来自实测：行偏移表每次击键按 O(n) 重建，-O 折算 16 MB ≈ 23 ms/帧、
  32 MB ≈ 46 ms、64 MB ≈ 92 ms（debug 探针上 127 ms/MB、线性），常驻内存约 5 倍文件体积。

### Fixed

- **AI 的 `open_document` 不再「说打开了、界面什么也没发生」**。
  `AgentDocumentAdapter.openFile(at:)` 以往无条件返回 true，而 >1 MB 的文件在此前只弹出
  确认框、并没有建 tab ⇒ 模型以为文件已经在编辑区，后续编辑落在看不见的文档上。
  现在返回 `TabManager.openFile` 的真实结果。

## [0.13.3] - 2026-10-22

**这一版没有新功能，全是热路径上的账。** 一条预览管线上查出两个量级级的问题：JSC
对「分组上的 `{n,}`」会丢掉锚定优化、退回逐位置失败（120KB 技术文档整篇解析 1.2s），
以及分块解析的产物与整篇解析**不等价**（松散列表被切成多个 `<ol>`、`[bar]:https://x`
的链接被静默丢掉、跨空行的 HTML 注释被拆开）。另外三处是成本：每次按键重建行偏移表
贵一个数量级、目录排序在比较器里重复取计算属性（6.8×）、预览预热在后台与真实预览
并发写同一个缓存目录（可能互删，表现是白屏）。
⚠️ 同时校正上一版写错的三个数字（目录索引、行偏移倍数、块缓存的「改一段」），见下面
条目里的说明——那三条当时都是拿局部测量当整体收益。

### Performance

- **预览解析不再随文档大小按平方变慢 —— 120KB 技术文档整篇 `marked.parse` 1256ms → 34ms**。
  根因不在 marked 的算法，也不在 Swift ↔ JS 的桥接：**JSC（WKWebView 的引擎）对
  「分组上的无界计数重复」`(?:x){3,}` 会丢掉「只在位置 0 尝试匹配」的优化**，匹配失败
  时沿整串走一遍。实测（`jsc`，无匹配输入）`^ {0,3}(?:-[\t ]*){3,}` 在 120KB 上单次
  失败 865µs，而等价改写 `(?:x)(?:x)(?:x)(?:x)*` 是 0.0µs；同一份 `marked.min.js` 在
  V8 上本来就只失败 0.1µs，所以 node 里一直是线性的。marked 每产出一个 block token
  都把 ~12 条块规则对**剩余全文**各试一遍 ⇒ 单条 O(n) × token 数 = O(n²)。
  修法两层：`marked.min.js` 展开 6 处分组量词（`scripts/patch_marked.py` 可重跑，
  12 万次差分模糊验证与原式等价）；`render.js` 给 `html` / `blockquote` / `hr` 三条
  规则加前置判据（`html` 带反向引用 `\1`，展开量词救不回来，只能靠 `charCodeAt`
  提前短路）。产物逐字节不变。
  ⚠️ 这条也解释了「为什么块级缓存看起来那么有效」：块缓存只是把 n 变小，超线性本身
  还在——`splitBlocks` 返回 null 的路径（打字刚敲下 ``` 时围栏未闭合）此前每敲一个键
  都要整篇付 1.2s。
- **每次按键重建行偏移表的成本降到 1/10**。`EditorHighlightScheduler.rebuildLineOffsets`
  此前用 `NSString.range(of:)` 逐行找换行，O(行数) 次搜索调用，且**不受**大文件
  高亮阈值保护——1.24MB 文档单次重建 19.9ms，按 8 字/秒打字等于每 125ms 一次 20ms
  卡顿，超出 16.7ms 帧预算。改成把文本分块读进 4,096 个 UTF16 单元的缓冲区、
  逐单元比较 `0x0A`：实测 218KB 6.17→0.62ms（约 10×）、2.2MB 54.4→3.25ms、
  5.5MB 135.4→7.95ms（大文件 **16.7–17×**，旧法每行一次 ICU 调用，行越长差越大），
  12 例语料（CRLF / 代理对 / 零宽 / 无尾换行 / 空串）输出与旧算法逐项一致。
  同时修掉 `lineOffsetsDirty` 只读不写的死变量——注释说「每次内容变更失效」，实际
  `ensureLineOffsets` 恒为空操作；现在按文本长度做 O(1) 兜底校验。
  ⚠️ 该兜底**只防长度变化**：等长改写不会重建（当前 5 个调用点都在改动后显式 rebuild，
  不可达）。要更强的一致性得比对内容哈希，代价是每次定位都 O(n)，不划算。
- **目录索引的真瓶颈是排序，不是枚举**。上一版把两次目录枚举合并成
  `loadAll(under:)` 一次枚举（4,650 项），也顺手把收益写成了「174.5ms → 89ms」——
  那个数字只计了枚举。`loadAll` 仍是「1 次枚举 + **2 次**排序」，而 `sortItems` 的
  比较器每次比较都取 `FileItem.name`（`url.lastPathComponent` 计算属性）两遍：
  4,500 项单次排序就要 91.7ms，两次 ≈183ms，总量不可能低于 89ms。现在预取 name 后
  4,500 项排序 **91.7 → 13.4ms**（6.8×）。新增 `FileItem.nameAccessCount` 调试计数，
  用例断言「排序里 name 取值次数 < 3N」，把这条性能主张钉住。
- **含代码块的文档重新命中预览块级缓存**。块级缓存按空行切块、只重解析变化的块，
  但判据里有一条「文档任意位置出现围栏 ⇒ 整篇重解析」（因为按 `\n\n` 切会把代码块
  切碎）。技术文档几乎必然含代码块，等于缓存对目标用户基本失效。现在分块器按行
  状态机切块、围栏内部不切；围栏未闭合（AI 流式写入、编辑中途）与带缩进的围栏
  （多在列表项里，切开会丢列表上下文）仍退回整篇解析，与改动前一致。
  实测同一条真实渲染管线（真 WKWebView + marked + DOMPurify）：123K 字符的技术文档
  （含表格 / 围栏 / 列表）冷启 **46ms**、改一段再渲染 **50ms**。
  ⚠️ 这里原来还并列写了个「改一段 79–96ms」当收益，那是**缓存没命中**的数字：
  `PARAGRAPH_CACHE_MAX_BLOCK` 是 2KB，4KB 级长段落永远进不了缓存，
  所以「改一段」等于冷启。
- **分块解析的产物现在与整篇解析等价**（新增出口等价性测试守着）。按空行切对
  **跨空行的结构**无解，上一版把切块范围从「无围栏文档」扩到「所有技术文档」，
  于是把这些错误一路放大：松散列表 `1. 甲\n\n2. 乙` 被切成多个 `<ol start="2">`、
  `<li><p>` 丢失；`[bar]:https://x`（冒号后无空格）不被认成引用定义 ⇒ 定义块渲染成
  空串、正文留 `[bar]`，**链接静默丢失**；`<div>` 与 `</div>` 落在不同块时，
  DOMPurify 逐块消毒会把未闭合片段丢掉。现在切块后做安全边界合并（缩进续行 /
  松散列表 / 未闭合 HTML 元素），引用定义判据去掉「冒号后必须有空白」这一条。
  合并只会牺牲缓存粒度、不会改变产物，24 例对抗语料 + 仓库内真实 .md 逐字节比对。
- **启动预热不再阻塞主线程，且与真实预览共用一套资源镜像**。`WebViewPool.warmUp`
  曾在主线程自己抄了一份「目标不存在就 `copyItem`」的镜像逻辑（856KB），与真实
  预览走的 `PreviewAssetMirror.mirrorAssets`（hard-link + 按源/目标 mtime 判刷新 +
  目录按条目补齐）是两套实现。这不只是重复代码：预热缓存**永不刷新**——
  `fileExists` 直接跳过，`shouldRefresh` / `directoryNeedsRefresh` 没有机会生效，
  升级后残留的旧 CSS/JS（含 `css/katex.min.css`、`css/fonts/*.woff2` 这类新增资源）
  会一直喂给升级后的第一个预览。现在镜像与 `preview.html` 生成统一走
  `PreviewAssetMirror.prepareHTML`，并挪到后台任务，主线程只建 WebView 与导航。
  写盘段补了锁：`PreviewAssetMirror` 的约定是「一个 cache dir 只允许一个写者」，
  而预热挪到后台后与真实预览**并发**写同一个 `caches/com.meditor.preview`，
  `mirrorAssets` 在刷新时会 `removeItem(css|scripts|…)`、`pruneCacheIfNeeded`
  会整目录删——正好删在另一个上下文的 `loadFileURL` 加载途中，表现是有样式缺失 / 白屏。

### Fixed

- **Pro key 的验证缓存不再把 key 明文写回 plist**（#66 迁移的补漏）。验证成功后
  缓存判定按 key 绑定，但此前绑定值就是 key 原文，`didSet` 直接落
  UserDefaults——任何验证过 key 的用户，明文仍躺在
  `~/Library/Preferences/com.meditor.app.plist`（只是换了个键名）。现在只持久化
  SHA-256，旧键一次性迁移并删除。顺带修掉一个次生丢 key：写入 Keychain 有
  400ms 防抖，窗口内退出 App 会两头都不在，现在终止前同步 flush。
- **键盘审阅「↵ 连续接受」现在会真正前进**。此前 JS 侧状态变更只改 DOM class、
  不写回数据层，Enter 接受一段后高亮停留在已处理段上，必须「Enter+j」交替按。
- **审阅面 CSP 注入不再被 `<header>` 骗过**。插入点此前用 `<head` 前缀匹配，
  AI 产物以 `<header>` 开头时 CSP meta 被插进 body，被浏览器整体忽略，
  文档内脚本恢复可执行。改为边界匹配并补了反向测试。

## [0.13.2] - 2026-10-22

**只修一处：冷启动命中「上次选中的是 HTML」时，那篇文档一直是空白页。** 恢复会话走的是
两段式——tab 先以空内容入列，文件后台读完再回填——但回填结果只推给了 Markdown 预览，
HTML 于是永远停在入场那次「加载空内容」上，得手动切一下 tab 才渲染。这条路径从六月就
是这个写法，只是没人报；触发条件窄（冷启动 + 选中的是 HTML + 有本地 HTML 文档），所以
一直没撞见。规则层面没有新东西，是同一个回灌漏了一半。顺带去掉一次多余的空页解析，
并给 HTML 补上加载指示器——此前白屏期间连「正在加载」都没有，看上去像卡死了。

### Fixed

- **macOS：冷启动恢复会话时，选中的 HTML 会一直白屏，切一下 tab 才渲染**。恢复会话时
  tab 先以空内容入列（`awaitingInitialContent`），内容由后台读完回填；而
  `TabManager.applyLoadedContent` 此前只把回填结果推给 markdown 预览，HTML 于是停在
  入场那次「加载空内容」上——`reloadToken` 不再递增，`WebPreviewView` 按
  `(fileURL, reloadToken)` 去重后认为无事可做，直到切 tab（切 tab 会重新同步）才刷新。
  现在两种语言都会回灌，是否重载仍由 `PreviewManager` 按内容 diff 决定（幂等）。
  顺带两处体验：① 内容到达前不再创建 `WKWebView`——此前会先加载一个空页、读完再导航
  一次，等于两次解析；② HTML 补上加载指示器，此前遮罩只挂在 Markdown 上，白屏期间
  没有任何反馈。

## [0.13.1] - 2026-10-21

**iOS 设置补齐与桌面端的三处落差，并多一条不依赖自建服务的发布通道。** 桌面端早就有
「分场景模型」和「Agent 步数预算」，iOS 一直吃默认值：换聊天模型会把工具调用一起换掉，
步数写死 30 无处可调。这一版把两个设置接上，顺手把「关于」补成能自查版本的页面，
再加一个 GitHub Gist 发布入口——它对存档和给开发者看源文件比渲染后的网页更合适，
也不受 Worker 是否在线影响。规则层面唯一的改动是把场景回退抽成共享纯函数，两端从此
共用一份「哪个字段优先、空串算什么」的定义。

### Added

- **iOS「分场景模型」与「Agent 上限」**（设置 → AI 服务）。新增 Agent 专用模型
  （留空跟随主模型）与单次运行最大步数（5–100，默认 30），接在
  `MobileAISettings.makeConfig(scene: .agent)` 与 `AgentRunner(maxSteps:)` 上。
  此前 iOS 只有一个模型字段，把重活交给强模型就等于把聊天也切过去；步数则硬编码
  在 `AgentRunner` 的默认参数里，长任务撞上「超过最大步数」时用户无从调整。
  桌面端的第三个场景（内联编辑）iOS 没有对应入口，故不提供该设置项——留一个
  没人读的开关比不提供更糟。步数超时随预算联动：每步十秒、最少五分钟。

- **iOS 支持发布到 GitHub Gist**（文档页「⋯」→ 发布到 GitHub Gist）。与「发布在线
  链接」并列的第二条通道：上传 Markdown **原文**而非渲染后的 HTML，走 GitHub REST，
  不依赖自建 Worker 是否在线。Token 存钥匙串、可见性默认私密（Gist 的 secret 只保证
  不出现在列表与搜索里，拿到链接的人仍可访问，所以默认值不替用户选择公开）。
  复用桌面端的 `GitHubGistService`——纯 Foundation + Security、无 AppKit 依赖，
  因此进入共享清单（49 → 50 条）。两端钥匙串条目同名但各自独立沙盒，需分别配置。

- **iOS「关于」补版本号与官网入口**。此前设置页里只有一句脚注，装的是哪一版无处可查
  ——iOS 没有 Sparkle 更新通道，报障时版本号是唯一的对齐依据。配套把 iOS 工程的
  `MARKETING_VERSION` 从 1.2 提到 1.3、构建号 1 → 2：iOS 从 0.12 起就没跟仓库
  `VERSION` 走同一套号，不提这一版的话，新包和上一版在报障时仍然无法区分。

### Changed

- **场景模型回退抽成共享纯函数 `AIConfig.resolveModel(scene:fallback:agent:inline:)`**。
  桌面端读 `AppSettings`、iOS 读 `MobileAISettings`，但「专属模型为空则回退主模型」
  这条规则不该有两份实现。抽出来后两端共用一份，且能被 `Tests/MEditorTests` 直接覆盖
  ——iOS 侧没有测试 target，规则放在壳里就等于永远不被验证。

### Fixed

- **模型名的空白判定漏掉换行**。`resolveModel` 原先只按 `.whitespaces` 裁切，
  粘贴一个尾部带换行的模型名时 `"\n"` 会被当成合法模型名发出去，API 侧回
  Model not found，而用户看到的只是一个空字段。改用 `.whitespacesAndNewlines`
  （前者超集，对正常输入无行为差异）。这条是写测试时先红后修的：新用例
  `test_agentScene_blankAgentModel_fallsBackToBase` 一开始就是失败的。

- **iOS：打开文件的失败全链路有回声，且体积上限按类型区分**。此前多个入口失败时
  静默无反应（首页导入、底栏导入、快捷动作、从「文件」App 分享进来），且体积判定
  各自为政——「打开文件」被拒的同一份文件能从最近列表打开。现在：① 所有读取路径
  （导入 / 最近列表 / 启动恢复 / Agent 写入后回读）统一走带分块硬上限的
  `readFileContent`；② 上限按类型区分——纯文本 10MB，HTML 放宽到 32MB
  （自包含单页的 base64 内嵌图轻易越过 10MB）；③ 打开成败改为返回值判定，不再拿
  `lastError == nil` 当导航判据（此前上一篇的落盘失败回声会误阻断新文档导航）；
  ④ 启动恢复失败后清理记录，不再每次启动重试同一个失效文件。

## [0.13.0] - 2026-10-20

**首个带商业化的版本：定时自动化转入 Pro，同时补齐「无人值守」真正需要的几块拼图。**
免费档仍是完整的编辑器 + 手动触发的 agent + 单篇导出，Pro 只管 cron 定时与托管配额。
破坏性变更只有一条 —— 此前随 autoApprove 一起上线的定时任务**没有正式用户**，直接
转入 Pro，无存量迁移。其余七条全是加法：演示模式能导出 `.pptx`，Agent 画的 Mermaid
语法错了会自己修，导出/预览补了中文字体栈，iOS 的 Mermaid 能出矢量图并分享，AI 设置
首屏从「十几个技术决策」收敛成一个。最后一处是视觉统一：iOS 的配色整体并入桌面端的
GitHub + shadcn 骨架，朱砂降级为「只出现在印章与 AI 标识点」—— 两端不再像两个产品。

### Changed

- **iOS 色板重做：GitHub 灰阶骨架 + shadcn 单色强调 + 朱砂降级为品牌印记**
  （纯视觉变更，无行为差异）。此前 iOS 是一套与 macOS 完全无关的「纸墨」系统
  （宣纸 `#F4F5F2` / 松烟墨 `#1B2434` / 朱砂 `#C0392B` = 全页唯一亮色且承担全部
  交互语义），同一个产品在两个平台像两个产品。现在骨架取 GitHub 的
  canvas / surface / border / fg 四级（浅色 `#F6F8FA` + `#FFFFFF`，深色
  `#0D1117` + `#161B22`），强调色取 shadcn 的 primary 单色
  （`#18181B` / 深色反转 `#FAFAFA`），**朱砂只保留在印章与 AI 标识点上**——
  骨架中性化之后，唯一的彩色反而比改版前更显眼。
  **配套改动**：① 新增 `onAccent`（深色下 accent 是近白，原来写死的 `.white`
  前景会白字白底）与 `accentSoft`（选中胶囊，`accent.opacity(0.14)` 在深色下
  几乎不可见）两个派生 token；② 链接色与图表描边从 `accent` 拆成独立
  `link`（GitHub 蓝 `#0969DA` / `#4493F8`）与 `diagramAccent`——沿用 accent
  会让链接失去「可点」信号、Mermaid 图变黑白且每节点描黑框；③ 移除
  「宣纸纤维」噪点纹理（600 点 Canvas + `drawingGroup()`，为米白纸面调的
  opacity 压在中性底上显脏）；④ 启动图 `LaunchMark` / `LaunchPaper` 换新色板
  并补深色变体（此前墨蓝横条在深色启动屏上其实看不清）；⑤ 修掉
  `PlatformShims.PreviewTheme.isDark` 恒 `false` 的假替身——共享的
  `AIAccentStyle` 在 iOS 深色下会据此选出近黑 fill + 近白 onFill。
  `PaperTheme` 的 API 名一个未动，30 处调用点零改动。

- **定价线重划：定时任务转入 Pro**（语义变更）。免费档 = 编辑器 + 手动触发 agent
  （含聊天侧手动发起的后台任务）+ 单篇导出；Pro = **定时自动化**（cron 触发的后台
  Agent 任务）+ **无限托管**（分享发布免配额、不过期、无品牌页脚，worker 侧既有
  `PRO_TOKENS` 分档不变）。定时任务到期时若无有效 Pro 资格，不再发起后台 run，
  toast 引导至 设置 → 集成 填入并验证 Pro 密钥；密钥验证走 worker 新增端点
  `GET /api/pro/verify`（复用 `PRO_TOKENS`，无需新增 secret）。
  **迁移说明**：定时任务此前随 autoApprove 刚上线、无正式用户，直接转为 Pro 即可，
  无存量迁移。本仓 MIT 开源——本地门控是「官方分发二进制的荣誉系统」，只约束官方
  构建的默认行为；离线宽限：验证通过的密钥离线维持有效（fail-open），从未验证过的
  密钥离线不放行（fail-closed）。

- **AI 设置分层：首屏只留一个决策**（战略复核 P0：新用户不该先做十几个技术决策
  才能看到第一个结果）。AI 设置页首屏现在是「快速开始」卡片——检测到本机
  Claude CLI 时推荐一键零配置（复用本机 Claude Code 登录），否则选「使用自己的
  API key」就地填 key；provider 细项、接口地址、模型选择、Agent 步数、个性化、
  入门演示、端侧智能与 MCP 全部收进默认收起的「高级」区，展开状态持久化
  （新增 `MEditor.aiAdvancedExpanded`，默认关）。所有既有配置项、绑定与
  持久化键不变，功能无删减。

### Added

- **iOS 端 Mermaid 矢量输出与分享**：`MermaidRenderer` 的渲染结果除 PNG 位图外同步携带
  自包含 SVG（同一次 `mermaid.render` 顺带产出，同一缓存条目，key 口径不变：
  外观 | 缩放 | 代码）。预览块内展示仍是位图（SwiftUI `Image` 不支持 SVG，
  iOS 无原生 SVG 栅格器），但补了两处矢量质量：长按图表可分享**矢量 SVG**
  （经 `Transferable` 以 .svg 类型进系统分享表单）或 PNG；小图被容器拉宽超过
  已渲染像素时，按实际显示宽度向引擎重渲一档更密的位图（缓存键含缩放，同档位只渲一次），
  不再放大发虚。iOS 端无 PDF 导出、macOS 端 PDF 本就走 `webView.createPDF` 矢量，
  均不在本项范围。

- **演示模式新增 .pptx 导出**：「导出演示文稿…」保存面板新增格式弹窗
  （HTML / PowerPoint .pptx）。.pptx 为纯 Swift 拼装的最小合法 OOXML 包
  （`ZipWriter` 未压缩 stored 写入 + 自实现查表 CRC32，零第三方依赖），
  分页与 HTML 演示导出共用同一份 `SlideSplitter` 结果。v1 只含文本
  （标题 + 正文/项目符号，16:9 白底）：图片仅保留 alt 文本，代码块按等宽
  纯文本保留（无高亮），有序列表渲染为 • 项目符号。产物经 `unzip -t`
  CRC 校验与 macOS QuickLook 真实解析验证（成功渲染缩略图）。

- **Mermaid 语法错误回传给 Agent 自修**（「agent 画的图，错了自己修」）：Agent 写入的
  文档含 ```mermaid 块时，写后自检在同步诊断之后用隐藏 WKWebView 跑真 `mermaid.parse`
  （复用预览的按需拷贝机制，懒初始化 + 串行 + 15s 超时重建），语法错误以
  `DocumentIssue.mermaidSyntax` 合并进自检报告条——报在围栏开栏行、分级为 reportOnly
  （修复要靠模型判断，不进确定性「一键修复」），点击可跳转该行，「让 Agent 修复」
  链路（/fix）的 prompt 会带上错误消息。此前 mermaid 错误只渲染成预览里的
  `.error-block`，没有任何通道回传。

- **定时任务支持 `autoApprove`（无人值守产出的前提）**：`schedules.json` 条目新增可选字段
  `autoApprove: true`（可选 `writeAllowlist: ["dir/"]` 限定工作区相对目录前缀）。声明后该任务的
  后台 run 写入免确认——此前后台 run 无人盯守时确认条挂起不响应，定时任务无法产出成品。
  安全边界不变：只跳过确认条 / 审阅态，写入仍限工作区内，run 级快照回滚照常记录；
  缺省 `false`，交互式聊天 run 的确认链路完全不受影响。

- **导出/预览 CSS 补中文字体栈**：预览主题 `base.css` 与 HTML 导出模板（craft 系列及
  `--font` 主题变量）补 `PingFang SC` / `Hiragino Sans GB` / `Microsoft YaHei`——此前仅
  导出模板含 PingFang SC，预览主题中文完全靠系统 fallback，且全链路缺 Windows 中文字体，
  成品发给非 Mac 收件人时中文渲染不可控（与演示模式 `slides.css` 既有字体栈对齐）。

## [0.12.3] - 2026-10-16

**iOS 端 UI 全面原生化 + 发布签名身份可配置。** iOS 端按「用 iOS 自己的 UI 组件、
UI 交互以及动画」的方向，把自绘 chrome 逐项换成苹果原生实现。macOS 端本轮**无功能
变化**（改动全部在 `Mobile/` 与发布基建，`Sources/` 一行未动）——Sparkle 用户会收到
一个仅构建号变化的更新。iOS 部署目标 `17.0` → `26.0` 是破坏性变更，伴生 App 版本号
同步 `1.1` → `1.2`。

### Changed

- **iOS 端 UI 原生化**：自绘 chrome 逐项换成原生实现。原则是只动「控件与交互」层，
  品牌视觉（宣纸色板、朱砂印、衬线标题、纸纹、`BrandMark`）保留，经 `tint` /
  `foregroundStyle` 注入原生控件。

  | 原来自绘 | 换成原生 |
  |---|---|
  | `GlassCapsuleBackground` 4 层手搓玻璃（材质 + 受光渐变 + 受光描边 + 发丝线 + 双层软影，49 行） | 一条胶囊一层 `.glassEffect(.regular, in: .capsule)`；该文件整删 |
  | `GlassSelection` 的 `TimelineView` 流光选中 pill（每 50ms 重绘一帧） | `matchedGeometryEffect` 滑动 + 系统 tint |
  | 手写卡片搜索框 | `.searchable(placement: .navigationBarDrawer(displayMode: .always))` |
  | 手写「暂无文档」空态、搜索无结果态 | `ContentUnavailableView` / `ContentUnavailableView.search(text:)` |
  | AI 面板自绘 overlay（遮罩 + 抓手 + 上滑 `DragGesture` + 350ms 延迟卸载） | `.sheet` + `presentationDetents` + `presentationDragIndicator(.visible)` |
  | `PaperPrimaryButtonStyle` 自绘朱砂底按钮 | `.buttonStyle(.glassProminent)` + `.tint(朱砂)`；最后一个调用点改完后该样式成死代码，随之删除 |

  页面切换保留原生 `TabView`（`selection` 绑定 + 每 tab 独立导航栈 + 原生转场），
  但**隐藏其 tab 栏**——原生 tab 栏放不了「打开 / AI / 新建」动作钮，与底部通栏并存
  还会叠成双层。底部为**单层左右通栏**：左 = 页面切换胶囊（文档 / 设置，
  `matchedGeometryEffect` 滑动选中 pill + `symbolEffect` + `sensoryFeedback`），
  右 = 动作胶囊（打开 / AI / 新建）。文档页动作条同款两胶囊结构。
  ⚠️ 实现细节：`.toolbar(.hidden, for: .tabBar)` 必须加在 **tab 内容**上才生效，
  加在 `TabView` 自身在 iOS 26 的新 tab 栏上无效。

  保留未动及理由：`PaperTheme.Motion`（本身就是 `Animation.spring` 原生原语的调参
  常量，不为它动 24 个调用点）、`SealStamp`、`PaperNoiseOverlay`、`DocumentView` 的
  品牌空态（`BrandMark` + 印章落款 + 模板入口，品牌资产重于控件语义）。

  净变化：`Mobile/` **+203 / −415 行**。

  ⚠️ **代价：放弃 iOS 17–25 设备**（部署目标 26.0）。这是拿到 `.glassEffect` 原生
  玻璃、原生 `Tab(...)`、`.buttonStyle(.glassProminent)` 的前提——这些 API 在
  iOS 17 上不存在，硬要「原生化」只能得到比自绘更差的近似品。

### Added

- **发布签名身份可配置**（消除升级时的钥匙串授权弹窗）：`release.yml` 新增
  `Import code signing identity` 与 `Verify signing requirement` 两步，`bundle.sh`
  新增 `SIGNING_IDENTITY` 环境变量。配了 `MACOS_SIGNING_CERT_P12_BASE64` /
  `MACOS_SIGNING_CERT_PASSWORD` 两个 secret 就用证书签，没配则保持 ad-hoc、
  行为与之前完全一致（不阻断发布）。
  动机：ad-hoc 的 designated requirement 是 **cdhash**，每次构建都变；而 AI API key
  存在钥匙串里、用系统默认 ACL（只信任创建它的应用、按 code signature 判定），
  于是每次升级 ACL 都失配、用户看到一次「想要使用储存在钥匙串中的机密信息」弹窗。
  证书签名的 designated requirement 是**证书锚**（`certificate leaf = H"…"`），
  跨构建稳定。`Verify signing requirement` 会核对这一点——若还是 cdhash 直接失败，
  不出这种包。⚠️ 权衡：证书私钥进 CI secret；且自签名证书不解决 Gatekeeper
  （首次启动仍需右键 → Open），要两者都解决需 Developer ID + 公证。

### Fixed

- **`AIService.swift` 的假注释**：原写「Keychain 的宽松 ACL（`trustedList: nil`）已解决
  开发期替换二进制反复弹授权窗的问题」，与 `Keychain.swift` 已为安全移除
  `trustedList: nil` 的事实矛盾，描述的是被推翻的旧设计。改为如实说明默认 ACL 的代价
  （签名身份不稳定时升级后会弹一次授权窗，这是有意的安全取舍）。

- **官网下载按钮的版本标签停在 `v0.12.1`**（0.12.2 发版时漏改，实际提供的包一直是
  最新的）：`website/index.html` 与 `website/compare.html` 的硬编码标签同步为当前版本。
  下载链接本身是 `/update/pkg`（永远指向最新包），不受影响。

## [0.12.2] - 2026-10-15

**用户报的三件事 + 一个会让升级白干的打包 bug。** 按用户报告的顺序：预览支持 LaTeX
数学公式、关闭窗口不再退出应用、消除 Sparkle 自动更新的授权弹窗诱因。每条都附实测
记录；其中「更新弹密码」一项**只消除了诱因、尚未定论**，如实标注在文末。

### Added

- **Markdown 预览支持 LaTeX 数学公式**（KaTeX 0.19.0，资源离线内置，不联网）：
  行内 `$...$`、块级 `$$...$$`，覆盖矩阵、分数、积分、求和、希腊字母、上下标等。
  实现沿用 mermaid 的**占位符模式**——marked 解析前摘出公式、过完 DOMPurify 之后
  才交给 KaTeX 渲染，因此块级缓存与增量 DOM patch 照常生效；`nodesEqual` 增加了
  数学归一化比较，否则「DOM 里是渲染结果、新 HTML 里是空占位符」会让每次编辑都
  重建整块并重渲染全部公式（行内公式会把所在段落一起拖下水）。
  代码块与行内代码里的 `$` 不参与识别（先原地遮蔽成等长占位串再扫描），货币写法
  （`$5 到 $10`）按 KaTeX auto-render 的启发式排除。
  随包体积约 592KB（js 268K + css 28K + 20 个 woff2 共 296K）。

### Changed

- **关闭最后一个窗口不再退出应用**：SwiftUI 的单例 `Window` 场景默认关窗即终止进程
  （最小复现实测：`NSApp.windows.first?.close()` 之后进程立即以 `exit(0)` 结束）。
  现在 `applicationShouldTerminateAfterLastWindowClosed` 返回 false，应用驻留 Dock，
  点 Dock 图标经 `applicationShouldHandleReopen` 把主窗口原样唤回——窗口对象全程存活
  （实测 `NSApp.windows` 计数不变、只是 `isVisible` 变 false），标签页 / 滚动位置 /
  光标都不丢。冷启动引导加了「只跑一次」守卫：唤回窗口会再次触发 `onAppear`（实测），
  重跑 `restoreSession` 会把用户当前状态覆盖回上次落盘的快照。

### Fixed

- **预览资源镜像漏掉目录内新增文件**：`mirrorAssets` 对目录只比 mtime，目标目录
  mtime 更新时源目录里新增的资源会被整个跳过——表现为「升级后公式字体缺失」。
  目录改用**条目覆盖判据**（递归比较相对路径集合，含二级目录），补 4 个测试。
- **Sparkle.framework 的 `--deep` 签名**：Sparkle 自身的错误提示明确要求
  「do not sign your app by passing --deep」——`--deep` 会把外层签名选项套到
  Installer / Downloader 两个 XPC helper 上，破坏它们被判定的签名身份。
  `bundle.sh` 改为由内向外逐层签（XPCServices → Updater.app → Autoupdate → 框架本体）。
- `Info.plist` 显式写入 `SUEnableInstallerLauncherService = false`：该 XPC 服务只对
  沙箱应用必要，且需经 SMJobBless 安装（会引入一次系统授权）；非沙箱应用启用它
  Sparkle 会直接报错。
- Quick Look 扩展不再整目录拷贝 `css/`，只取它真正内联的 `themes.css` / `base.css`
  —— KaTeX 的样式与字体对 QL 无用（QL 走 JavaScriptCore 无 DOM，数学降级为原文），
  白占约 320KB。

### 已知未做（如实标注）

- **「自动更新时弹输入密码授权」只消除了诱因，未定论**：本机现场反证（`/Applications`
  组可写、app 属主为当前用户、bundle 可写）按 Sparkle 文档「能移动就不该要授权」
  本不该弹；排查中追到的一条「InstallerLauncher.xpc 缺失」线索已自我推翻——Sparkle
  2.9.5 的正常布局就是 `Downloader.xpc` + `Installer.xpc`。剩余最可疑项是**发布包为
  ad-hoc 签名、无 Developer ID**（`codesign` 显示所有组件 `TeamIdentifier=not set`），
  需发一版新包后实际更新一次才能验证。Developer-ID 签名 + 公证仍是路线图条目。

## [0.12.1] - 2026-10-14

**审计余项清理 + 两个用户可见 bug 修复**：0.12.0 修完全部 P0 与 P1 最高优先级的 4 项后，
本版把 review 分级里**其余可安全落地**的中低优先级项一次修完，并修掉两个用户报的
界面问题（左侧面板展开后 tab 栏消失、HTML 预览本地图片不显示）。每条附**反向验证**
（改坏实现 → 确认检查变红 → 恢复），并如实标注**不修**的部分及原因。

### Added

- **工具参数的运行时校验**（`AgentTool.validateArguments`）：对照 `spec.parameters` 检查
  必填缺失 / 类型不符 / enum 越界，失败以 `isError` 工具结果回灌让模型自纠（与
  `argumentsParseError` 同一处理），三个调用点（AgentRunner 只读并行组 / 写串行组、
  MCPServer）共用一把尺子。
  *此前*：类型不匹配时各工具 `?.stringValue` 拿到 nil 后静默走默认分支（如 `read_document`
  的 `start_line` 被解析成布尔值时，行区间读取静默退化成读全文），模型看到「正常返回」
  便以为参数生效，错误自我复制。新增 `AgentToolValidationTests` 覆盖（含变异验证）。
- `DS.Stroke` / `PaperTheme.Stroke` 两档描边宽度 token（`hairline` 0.5 / `regular` 1）。
- **`scripts/sign_update.swift` 的端到端测试**：签名是发布链路最后一环，签名错 ⇒ Sparkle
  自动更新对所有用户失效，而 `release.yml` 只在真发布时才跑它、出错已经晚了。测试用真脚本
  子进程（不重实现签名逻辑），覆盖正常签名可验签、64 字节 libsodium 私钥形态、
  `--expect-public-key` 守卫、参数与 base64 非法时的非零退出。

### Fixed

- **左侧面板展开后文件 tab 栏消失**：tab 条宽度此前按侧栏的**理想宽**（恒为 260）
  估算，而真实列宽由用户拖拽决定（220...320）。拖宽侧栏后算出的 tab 条超出 detail 列
  可用宽度，macOS 对超宽的 toolbar item 不裁剪而是整体塞进 `>>` 溢出菜单，于是整条 tab
  栏不见了。改为实测真实列宽（FileSidebar 的 GeometryReader 回传），理想宽只作兜底。
- **HTML 预览里本地路径图片不显示**（相对与绝对都修好了）：HTML 预览的 baseURL 是合成的
  `https://localhost/`（为了让内嵌 CDN 脚本能加载——WKWebView 会拦 `file://` 页面的
  外部网络请求），代价是相对路径被解析到 `https://localhost/…` 而加载失败。现在额外注入
  `<base href="meditor-asset://…文档目录/">`，本地图片与 CDN 脚本两者兼得（复用markdown
  预览已有的同一套 scheme handler 与敏感目录拦截）。
  按 RFC 3986，以 `/` 开头的绝对路径（absolute-path reference）只继承 base 的
  scheme + authority，所以 `/Users/me/a.png` 这类写法**一并被修好**。唯一仍不通的是
  `file:///…` 形态（带 scheme 的绝对 URL，`<base>` 按规范管不到）。
- **RestAgentBackend 的可重试状态码从 429/503 扩为 429 + 5xx（500/502/503/504）**：
  网关与负载均衡后的临时故障同样常以 5xx 返回，重试一次大概率即恢复；400/401/403/404/422
  等确定性错误仍不重试。
- **iOS `writeText` 的协调写入判据补上 `isUbiquitousItem`**：此前只判 `externalBookmark`，
  workspace 本身位于 iCloud Drive 时其中的文档没有 bookmark，直写会绕过 `NSFileCoordinator`
  与同步守护进程打架（丢更新 / 冲突副本）。
- **iOS `RootView` 页切换补 `accessibilityHidden`**：`opacity(0)` 不移出无障碍树，此前
  VoiceOver 会读到两页元素、焦点顺序按 ZStack 层序而非可见页。
- **`AgentResumeContext` 续跑指令改条件式措辞**：不再断言「写入已生效」，改为以工具结果
  为唯一事实来源（工具返回成功 ≠ 盘上一定写成功），避免在边缘场景对模型说假话。
- **WelcomeView 的品牌蓝硬编码改为 `Color.appAccent`**：卡片光晕与外发光此前写死蓝色，
  与已用强调色的 CTA 割裂；用户改系统强调色后即可整卡跟随。
- 移动端 `HeroOverlays` 的圆角 22 改回档位值（`PaperTheme.Radius.xlarge` = 20）。

### Changed

- **描边宽度全仓收口到两档 token**（桌面端 49 处、iOS 7 处）：`lineWidth: 0.5` → `DS.Stroke.hairline`、
  `lineWidth: 1` → `DS.Stroke.regular`。两处「半像素 hack」（发丝线对齐、描边防裁切）不改数值，
  改为就地注释说明意图 —— 它们是有意的像素对齐，不是同类问题。
- **`FileSidebar` 的目录枚举收口到 `FileService.listDocumentFiles`**：View 层不再直接
  `FileManager.contentsOfDirectory`（此前枚举规则在 View 与 Service 各写一份）。
- **`MEditorApp` 的冷启动三步收进 `bootSequence()`**：`warmUp → restoreSession → consumePendingOpens`
  的顺序此前靠注释维系，现成为代码结构（顺序写错会覆盖刚打开的外部文档）。
- 工具描述去掉全大写强指令（`ALWAYS` / `NEVER` → 常规措辞）：对弱模型减少指令过载。
- 覆盖率门禁给 `Views/` 补一个极低但存在的**棘轮 floor**（`--min-dir Views=1`）：此前该层
  无门槛，「把代码挪进 Views/ 绕过 logic 门槛」是一条免费通道；这是堵口，不是提目标。

### Removed

- 两个零引用协议 `PreviewResourceLocatorProtocol` / `FileTypeConfigurationProtocol`
  （`EditorViewProtocol` 保留 —— 它是 SwiftUI 关联类型限制下的**文档契约**，非空转）。
- `WelcomeView` 的死装饰：全透明的 `RoundedRectangle` 背景 + `.hoverBrightness(0.0)`
  （两者都不产生任何视觉输出）。

### 已知未做（如实标注）

- **iOS 能力差距不修**：行内 diff 审阅 UI、本地历史、MCP、局域网分享、PDF 导出、Todo/日历、
  Gist 在 iOS 端**没有实现** —— 这是「iOS 是编辑 / 聊天 / 发布的精简伴侣」的范围差异，
  不是隐藏缺陷；已列入 README「后续」。
- **需产品/视觉决策的项不擅自改**：跨后端 fallback、trace 落盘、价格表更新机制、
  「统一抬升语言」、行选中色定档、`PreviewTheme` 与 `DS.Color` 的收口口径。
- 存量：23 种字号 / 裸 `cornerRadius` 仍大量未收口；打包脚本 `bundle.sh` 无测试
  （`sign_update.swift` 本版已补端到端测试：生成临时密钥对 → 真脚本子进程签名 → 公钥验签
  + `expect-public-key` 守卫）。

## [0.12.0] - 2026-10-14

本版是**一次深度审计后的整改**：先对桌面端 + iOS 做了通读式的 review（覆盖 UI 质感、
架构合理性、Agent 架构），把结论按 P0/P1/P2 分级留档，然后按主题分批修、每批一个 PR、
每条附**反向验证**（改坏实现 → 确认检查变红 → 恢复）。主题是**「让检查真的会咬人」**。

### Added

- **iOS 共享内核护栏**：新增脚本机械核对 `Shared` 组的 49 条引用的完整性，
  并接进 CI —— 此前 iOS target 的共享文件是**手工清单**，漏一个只会在编译时炸。
- **Service 层依赖方向护栏**（`scripts/check_service_layer_deps.py`）：棘轮式，
  已搬到端口的文件不得再出现 ViewModel 类型；新出现的反向依赖必须显式登记。
- **设计 token 死代码护栏**（`scripts/check_dead_tokens.py`）：`DS.*` 成员必须有人引用，
  例外需登记理由。
- **CI 新增 job**：`worker/` 的 `node --test` 首次接进 CI（此前有测试但从不运行）；
  覆盖率门禁的**路径门槛**首次真正生效（此前 `--min-dir` 参数从未被 CI 传入，
  per-directory floor 形同未启用）。
- `CONTRIBUTING.md` · `AGENTS.md` · `SECURITY.md` · `CODE_OF_CONDUCT.md` · `CHANGELOG.md`、
  issue / PR 模板、`dependabot.yml`、`.editorconfig` · `.gitattributes`。

### Fixed

- **Agent 总超时与步数预算错配**：`timeoutSeconds` 硬编码 300s，而设置页
  `aiAgentMaxSteps` 允许调到 100 步 ⇒ 100 步任务的后半程永远走不到，墙钟先到时
  只报「超时」，误导成任务太重（实际是预算没给够）。现总超时 = max(300s,
  maxSteps × 10s)，默认 30 步仍是 300s（不改历史行为）；超时报错带上步数预算。
- **两处 `nonisolated(unsafe)` 静态量逃逸**：`AIAPIKeyStore.memoryFallback` 与
  mermaid 首调标志，无锁时多个异步上下文可交错写回旧值 / 重复拷贝（第二个
  `copyItem` 撞上已存在的目标文件，被 `try?` 静默吞掉 ⇒ 偶发没有 mermaid）。
  均按本仓既有样板（`_cachedShellEnv + _shellEnvLock`）加锁，读写收口到锁内。
- **iOS 重命名失败曾完全静默**：`renameDocument` 的 `try?` 让「名字没变但文件也
  没动」与「参数非法」对调用方同形（都只返回 nil），用户看到的是「点了重命名
  没反应」。现失败记 `lastError`（可读消息）后返回 nil。
- **管道写端 SIGPIPE 曾静默打死整个进程**：MCP server / Claude CLI 子进程退出后，往已无读端的
  stdin 写数据会触发 SIGPIPE，其默认动作是**终止进程且不打印任何诊断**。表现为 CI 上测试
  「跑到一半整个进程消失、无断言输出、无 crash report」。现对三个管道写端的 fd 调
  `fcntl(F_SETNOSIGPIPE)`，让 write 抛 `EPIPE` 走既有 catch 分支。
- **iOS 写路径两处数据安全问题**：10 MB 大小上限被绕过（先全量读入再判大小 ⇒ 超大文件仍进内存）；
  切换文档时取消 autosave 但不 flush ⇒ 防抖窗口内的手输内容被静默丢弃。
- **Agent 上下文预算会裁掉首条 user 指令** ⇒ 长会话模型忘记原始目标后继续错误编辑。现钉住首条指令。
- **Agent 停滞检测有盲区**：只覆盖「同参连续失败」⇒ 换参反复失败、或「成功但无进展」可以烧满
  30 步 / 300 秒，且报错不指向真因。补两条步级规则。
- **`coverage_gate.py` 覆盖率百分比算反**（`(found, hit)` 被当成 `(hit, tot)` 解包）⇒
  阈值方向相反，`floor 99` 会**通过**。这是加变异验证时当场抓到的。
- iOS 端 `AppSettings` 替身不再静默：此前替身返回**假默认值**（provider = disabled、model = ""），
  共享代码误读时表现为「功能莫名失效」；现在 DEBUG 下直接 `fatalError`，Release 下打印告警。

### Changed

- **后台 Agent 服务的宿主依赖改走端口**（`AgentHostPort`）：`BackgroundAgentTaskService` /
  `AgentSchedulerService` 原先直接持 `weak var appState: AppState?`。
- 两个后台服务的反馈路径（并发上限 / 完成 / 取消 / 写回失败）从「跑过但无痕」变为可断言。
- iOS 版本号与 macOS 版本号**保持各自独立**（本版未做对齐，这是设计）。

### Removed

- 三个全仓 0 调用的 `NSViewRepresentable`：`SidebarVibrancyView`、`SidebarMaterialFixer`、
  `Views/Shared/VisualEffect.swift`。侧栏材质实际由 `NavigationSplitView` 侧栏列原生提供。
- `DS.Shadow` 命名空间（半成品抬升系统，0 引用）与 3 个死 token
  （`Color.chromeBg` / `Color.statusBg` / `Color.rowSelected`，后者数值已与实况脱节）。

### 已知未做（如实标注）

- **P1/P2 余项未随本版处理**：本版修完**全部 P0** 与 P1 中优先级最高的 4 项
  （见上面 Fixed 的前三条）；review 分级里的其余中低优先级项（更多并发加固点、
  错误路径可观测性、UI 收口等）仍在，代表性存量见下面「存量债务」条。
- iOS 端仍**没有单元测试 target**（本版只补了共享集护栏，未补测试）。
- 「统一抬升语言」与「行选中色定档」两件**未做** —— 需要看着界面做视觉决策，
  已记入 `docs/design-as-built.md` §10。
- 存量债务仍在：23 种字号 / 裸 `cornerRadius` 大量未收口、`PreviewTheme` 与 `DS.Color`
  两套色彩真源并存、打包签名脚本无测试。
