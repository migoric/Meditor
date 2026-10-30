# MEditor UI Design As-Built（现状文档）

> 版本：对应 macOS 端 0.13（macOS 26 / Xcode 26 SDK，Liquid Glass）
> 依据：2026-08 对 Sources/MEditor 源码的只读调研（三个独立调研报告交叉验证），
> 此后按版本增量维护。**版本号与 `VERSION` 的一致性由
> `scripts/check_docs_consistency.py` 在 CI 里看住**——改版忘了改这一行会直接红。
> 用途：作为 design-spec-v3.md 的现状对照——记录**当前实际设计**，而非目标设计。

---

## 0. 与 spec v3 的关系（先读这段）

spec v3 写于 Craft 卡片风 + 三栏右面板时代。此后发生了两次方向性变化：

1. **视觉**：0.6.x 起转向 macOS 26 Tahoe 的 Liquid Glass 原生外观（2cfd2a1 迁移 macOS 26 SDK，8731e9f 截图更新）——**该方向已确认是既定设计，不再回退**。
2. **交互模型**：产品核心从"手动编辑文档"转变为"**通过 AI 修改文档**"——用户通过斜杠命令/选区动作条/对话给指令，AI 产出 diff，用户审阅确认后落盘。由此**编辑态不再是设计目标**：spec 的块级编辑（块 hover 手柄/插入入口/多选）整体取消，手动逐字编辑退居次要路径（NSTextView 保留，但不再围绕它设计编辑交互）。

3. **勘误（2026-10）**：§1 曾把侧栏玻璃记作 `SidebarVibrancyView` / `SidebarMaterialFixer` 的功劳。实测这两个 `NSViewRepresentable` 在全仓 **0 调用**（从未接上去），已随 P0-4 一并删除；侧栏材质实际来自 `NavigationSplitView` 侧栏列的原生实现（`FileSidebar` 用 `.listStyle(.sidebar)`，`AppShell.swift:37-40` 的注释也这么写）。成因是本文档依据「读源码」而非「查调用点」—— **文件存在 ≠ 生效**，本仓凡是描述"某机制负责某外观"的句子，都必须落到调用点上核一遍。

同时交互骨架从自定义三栏改为 Apple 标准 NavigationSplitView 两栏（f0796ce 侧栏原生化）。
因此本文档是 spec v3 的演进后现状，差异对照见文末 §9。

---

## 1. 设计方向（as-built）

- **原生优先**：NavigationSplitView 侧栏通顶、红绿灯进侧栏材质、分隔线/拖拽宽度全交系统，不做私有 titlebar 手术（AppShell.swift:37-40）
- **Liquid Glass**：macOS 26 玻璃材质贯穿工具栏（含显式拆掉 toolbar item 默认玻璃胶囊的 ToolbarItemGlassDisabler）、侧栏（**由 NavigationSplitView 侧栏列原生提供**，见 §0 第 3 条勘误）、浮条（regularMaterial）
- **键盘优先**：52 处 keyboardShortcut + 全弹层 Esc 关闭 + 斜杠菜单全键盘操作
- **AI 修改文档为核心**：主写作路径 = 指令（斜杠/选区/对话）→ AgentRunner 流式产出 → diff 审阅确认 → 可撤销落盘；手动编辑是兜底而非主路径（无编辑态设计）
- **AI 上下文驱动**：选区内联编辑条、@提及、斜杠 AI 命令、diff 审阅覆盖层——AI 融入编辑流而非独立对话框
- **克制反馈**：toast/呼吸光晕/悬停底色/统一 DS.Motion 动效时长

---

## 2. 信息架构（as-built）

```
MEditorApp → ContentView (Views/AppShell/)
├─ rootURL == nil → WelcomeView（像素风启动 + 最近文件夹）
└─ rootURL != nil → AppShell = NavigationSplitView（两栏）
   ├─ 左栏 FileSidebar
   │   ├─ 项目名标题（rootURL.lastPathComponent）
   │   ├─ 搜索框（文件名过滤）
   │   ├─ 四分区：用户文档 / 应用文档 / 散文件 / 文件夹树(含 Git 标记 M/A/?/D/R/!)
   │   └─ 底部工具：新建文档 | 新建文件夹 | 待办 | 日历 | 专注 | 设置
   └─ detail 列：
      ├─ editor: DocumentHeader(46pt) + 原生 NSTextView 编辑器
      ├─ 1pt 分隔线（编辑+预览同时显示时）
      ├─ preview: [TOC 大纲 220pt] + WKWebView 预览 + DocumentActionBar(右上悬浮)
      ├─ 覆盖层：DiffReviewOverlay / Focus 控件 / AI 面板 / 各 Sheet
      └─ StatusBar（光标行列/字数/大小/语言/未保存/已保存/分享 chip；专注模式隐藏）
窗口 toolbar：系统侧栏开关 + EditorTabBar（唯一自定义项，动态宽度）
```

关键点：**两栏，不是三栏**。spec 的右侧上下文面板体系未实现（见 §9）。

---

## 3. 侧栏

- 分区：userDocs / appDocs / looseFiles / folders（FileSidebar.swift:126-204）；无 All Docs/Recent/Favorites/Shared/Trash 顶层入口
- 右键菜单：目录=新建文件/新建文件夹；所有行=重命名/删除/复制路径(绝对/相对)/在 Finder 中显示（FileRow.swift:62,117-130）
- 新建/重命名/删除走 InputDialog + confirmationDialog（FileSidebar.swift:90-121）
- **无拖拽**（排序/归档/移入文件夹均不支持）
- Git 状态：行尾单字母标记 + 目录橙色圆点（FileRow.swift:44-54）
- 侧栏宽度：min 220 / ideal clamped / max 320，系统接管（AppShell.swift:42-44）

---

## 4. 编辑器

- **模型**：整页 NSTextView（MEditorTextView 子类，非块级）；allowsNonContiguousLayout 优化大文件（NativeEditorView.swift:83-99,132）
- 行号：NSRulerView 子类，只画可见行；行首偏移表共享自 EditorHighlightScheduler（LineNumberRulerView.swift）
- 高亮：EditorHighlightScheduler——击键 0.3s 后高亮 + 滚动停稳补可见区，只重绘可见范围±2000 字符；>150KB 跳过正则高亮
- 行偏移表：击键按 `shouldChangeTextIn` 记录的编辑 delta 增量维护（平移编辑点之后的行首），delta 对不上时回退全量重扫
- 滚动同步：EditorScrollSyncHandler 缓存行偏移二分求顶行，双向 + ScrollSyncState 防回环
- Markdown 输入：⌘B/⌘I/⌘K 选区包裹（可解包+占位符）、括号引号自动配对、图片 ⌘V 落盘 assets/ 插入相对路径
- 标题区 DocumentHeader（图标+名+相对路径+语言胶囊+未保存圆点）；底部 StatusBar 齐全

---

## 5. 预览

- 渲染：marked + highlight.js + mermaid（template.html 同步加载）；`Sources/MEditor/Resources/Preview/scripts/render.js` 只保留主流程与公开 API，`Sources/MEditor/Resources/Preview/scripts/render/` 按共享状态、Markdown 解析、分块、数学、Mermaid、DOM patch、增强后处理分模块，普通 script 固定顺序加载；段落级缓存(LRU 300)、同类松散列表稳定分块（≤50 项 / 16KB，出口并回单一列表容器）、hljs 空闲批量高亮、mermaid IntersectionObserver 懒渲染
- 更新：WKWebView 长驻 + JS 块对齐原地替换（不整页刷新，保留滚动；失稳回退全树 diff）；WebViewPool 预热复用
- 工具栏 DocumentActionBar（右上悬浮）：演示 → 美化（Markdown 走 diff 预览/HTML 走 sheet）→ 导出（富文本/HTML/PDF/图片，含预检）→ 分享（LAN/Gist/ShareLink）→ 收起手柄
- 主题：不在工具栏——QuickOpen 命令 + 设置 General（github/nord/dracula 三主题）
- 双向滚动同步 + TOC 大纲（220pt，点击双向跳转）

---

## 6. AI 交互（项目特色）

- **面板形态**：右下角悬浮胶囊按钮 → hero overlay 缩放展开（非右侧面板）；三态内容：首启引导 → 建议页 → Transcript；Esc 关闭
- **流式**：400ms 节流 Markdown 重解析防跳动；闪烁光标 + TypingDots；滚动只在贴底时跟随
- **工具步骤**：紧凑单行渲染在回复上方；长结果可展开/折叠(200pt)；失败抖动；完成后面板带 usage 脚注 + **一键回滚**
- **@提及**：自定义 NSTextView chip 渲染 + 浮动候选（↑↓/回车/Esc，IME 组字放行）；file/dir/@current/@workspace；单 token 32KB/消息 8 个/目录 40 子项
- **会话**：多会话 + 草稿 + 首条自动命名 + 100 条 FIFO + 防抖落盘 ai-sessions.json；在途 run 按发起会话 id 定向写回
- **斜杠命令**：9 静态 Markdown 展开 + 10 注册表 AI 命令；NSPopover 光标定位；模糊搜索（别名/标题/关键词）；↑↓/回车/Tab/Esc 全键盘；takesArgument 命令空格放行
- **内联编辑条**：编辑器底部胶囊（≤4 主动作 + 更多 + 插件 + 问 AI）/ 预览选区跟随胶囊（无转表格）→ AgentRunner 流式 → DiffReviewOverlay 段落级审阅（接受/跳过/连续微调）→ 可撤销写回
- **写确认**：命令/写文件确认条 + diff 展示 + 本次运行全部允许
- **写后自检**：Agent 写入防抖合并后跑本地诊断（死链/缺图/标题/围栏），含 ```mermaid 块时再用隐藏 WKWebView 跑真 mermaid.parse 异步校验，错误合并进报告条（报在开栏行，reportOnly——修复走「让 Agent 修复」回传模型）

---

## 7. 设置 / 反馈 / 键盘 / 视觉 token

### 设置（5 Tab）
general（主题/强调色/语言/编辑器字号/预览字号/自动保存/导出预检/关于）· ai（provider/模型/Keychain/agentMaxSteps/自定义 prompt/Claude Code 监听）· sharing（端口/Gist/ShareLink）· plugins（内置+我的+精选库）· paths（文档路径）——无独立外观 Tab

### 反馈
toast（底部胶囊 2.5s，可带操作按钮）/ EmptyStateView / WelcomeView（像素字符洗牌动画+最近文件夹）/ 诊断面板一键修复（/fix 链路+前后对比横幅）/ Sparkle 更新面板（全阶段）

### 键盘（节选）
⌘⇧O 打开文件夹 · ⌘N 新建 · ⌘S 保存 · ⌘F/⌘G/⇧⌘G/⌥⌘F 查找系 · ⌘B/⌘I/⌘K 加粗/斜体/链接 · ⌘W/⇧⌘T/⇧⌘]/⇧⌘[ tab 系 · ⌘P/⇧⌘P 快速打开/命令面板 · ⌘J AI · ⌥⌘D 诊断 · ⌃⌘H 历史 · ⌥⌘B 侧栏 · Esc 全弹层关闭/退专注

### 视觉 token
- DS（DesignTokens.swift）：Space 4pt 网格(2-32)、Radius(3/5/8/12/16/999)、Font、Motion（micro .10s/fast .15s/standard .22s/spring/panel）、Shadow、Color（sidebarBg/editorBg/chromeBg 等随系统明暗）
- PreviewTheme 三主题：github(亮)/nord(暗冷蓝灰)/dracula(暗暖紫)，每主题含 editor/chrome/windowBackground + craft 交互 token
- AI 品牌色渐变（blue/violet/pink/orange）

---

## 8. 已实现但 spec 未覆盖的能力（as-built 增量）

- Liquid Glass / macOS 26 适配（工具栏玻璃、侧栏材质、tab 条玻璃胶囊拆解）
- AI 修改文档闭环（核心交互）：斜杠命令/选区动作条/对话 → AgentRunner 流式 → DiffReviewOverlay 段落级审阅（接受/跳过/连续微调）→ 可撤销写回；写文件前确认 + 本次运行全部允许
  - 写入约束：所有写工具默认要求确认，截断文本不得作为写前原文；审阅期间目标变化时拒绝覆盖，
    当前文档写入校验源 Tab，定时任务免确认与各写工具共用同一策略。
  - 工具调度：仅连续只读调用段并行，写调用与后续读取保持模型给出的因果顺序；回滚写盘失败保留重试入口。
  - 工作区索引：扫描与构建均校验最新 root，旧工作区结果不得晚到覆盖；iOS 与 macOS 均限制 Agent 读取目标。
    搜索最多四路并行且保持路径顺序，连续输入仅复用未截断的前缀结果，索引变化同时使排序与查询缓存失效。
- Git 状态标记（侧栏）· 本地历史快照（⌃⌘H）· 导出预检 · 全局搜索浮层 · LAN 分享 + Gist + ShareLink · 演示模式（放映 + 导出 HTML/.pptx）· Quick Look 扩展 · 模板系统

---

## 9. 与 spec v3 差异对照表

| spec v3 承诺 | as-built 现状 | 状态 |
|---|---|---|
| 三栏（导航/中央/右侧上下文面板） | NavigationSplitView 两栏（侧栏 + 编辑器/预览分屏） | **已变更** |
| 右侧互斥面板体系（Insert/Style/PageInfo/Comments/Share/SearchResults） | 不存在（仅 Localization 残留 key）；TOC 内联预览左侧；Share=工具栏菜单+状态栏 chip | 未实现 |
| 块级编辑模型（12 块类型 + Rest/Hover/Active + 拖拽手柄/插入入口） | 无。产品转向 AI 修改文档，编辑态整体取消；整页 NSTextView 仅作兜底输入 | **已取消**（设计决策） |
| 多选模型 + 轻量上下文条 | 无（无块概念） | **已取消**（设计决策，随编辑态一并取消） |
| Slash 分组展示 + 最近使用前置 | 扁平列表（无分组标题、无最近优先），其余（光标定位/模糊/全键盘）全实现 | 部分 |
| Quick Open 全局命令面板 | **已实现**：⌘P/⌘⇧P 同一面板，文件模糊匹配（名称/路径）+ 8 条全局命令，全键盘操作；spec 的"搜正文/最近文档"由 ⌘⇧F 全局搜索与最近文件夹（Welcome 页）分工承担 | **已实现**（分工明确） |
| 三层搜索 + 右侧结果面板 | 三入口全实现（侧栏过滤/⌘F 内联 find bar+预览 find bar/⌘⇧F 浮层）；结果在浮层非右面板 | 部分 |
| 视觉：Craft 卡片风自定义色彩体系 | Liquid Glass 原生材质 + DS token + 三主题 | **已变更**（0.6.x 转折，**Liquid Glass 为既定方向**） |
| 独立 38px Tab 栏（bg-chrome） | Tab 进系统窗口 toolbar（自动位、动态宽度、玻璃胶囊拆解） | **已变更** |
| 顶部工具区（面包屑/搜索/分享/评论/布局） | 工具栏仅系统开关+tab 条；功能分散至侧栏/预览浮条/状态栏 | **已变更** |
| 侧栏分层导航（Space 切换/顶层入口/树/底部工具） | 四分区 + 底部工具；无顶层入口；Space 仅标题 | 部分 |
| 侧栏拖拽排序/归档/移入文件夹 | 无任何侧栏拖拽 | 未实现 |
| 焦点模式（收缩周边噪音） | 完整实现且超 spec：隐藏侧栏/toolbar/StatusBar/动作条、编辑器居中 740pt、ESC 双通道退出、hero 过渡、呼吸光晕 | **已实现（超 spec）** |
| 组件规范（按钮三态/圆角/高度） | DS token 统一（Radius/Space/Motion/Color），非逐组件硬编码 | 已实现（token 化） |
| 状态与反馈规范（Empty/Loading/Error） | toast/EmptyState/Welcome/诊断一键修复/更新面板 | 已实现 |
| 动效规范表（100-220ms ease-out） | DS.Motion 统一 + 大量 withAnimation（63 处） | 已实现 |

---

## 10. 已知短板（与 spec 无关，纯现状）

1. 无障碍覆盖极低：21.4k 行视图里 `accessibilityLabel` 仅 22 处、
   `accessibilityIdentifier` 为 0（等于没有 UI 测试挂点）、无 VoiceOver 走查
2. 减少动态效果适配刚起步（`accessibilityReduceMotion` 仅 1 处：欢迎页，#68 接入；其余动画未覆盖）
3. 侧栏无拖拽（spec 遗留，若要恢复分层导航需补）
4. 单文件偏大：`Localization.swift` 1344 行、`AIService.swift` 845 行、`AgentRunner.swift` 843 行
5. **抬升语言已统一**（2026-10 修复）：`dsElevation` 24 处 + `DS.Elevation` 3 处；
   裸 `.shadow(` 从 29 处降到 9 处。原「无抬升 token」条目作废。
6. **行选中色已有 token**（2026-10 修复）：`selectionFill` 12 处统一取档；
   原先 `appAccent.opacity(0.16)` / `0.12` 两档并存的问题已收口。
