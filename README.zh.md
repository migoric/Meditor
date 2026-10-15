<p align="center">
  <img src="assets/icon.png" width="128" alt="MEditor 图标" />
</p>

<h1 align="center">MEditor</h1>

<p align="center">
  <strong>macOS 上给技术人写文档的 Agent 工作台</strong>
</p>

<p align="center">
  <a href="https://github.com/retrychx/Meditor/actions/workflows/build.yml"><img src="https://github.com/retrychx/Meditor/actions/workflows/build.yml/badge.svg" alt="Build & Test" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0+-blue?logo=apple" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.2-orange?logo=swift" alt="Swift 6.2" />
  <a href="https://github.com/retrychx/Meditor/releases/latest"><img src="https://img.shields.io/github/v/release/retrychx/Meditor" alt="最新版本" /></a>
  <img src="https://img.shields.io/badge/%E5%8D%8F%E8%AE%AE-MIT-green" alt="MIT License" />
</p>

<p align="center">
  🌐 <strong>中文</strong> | <a href="README.md"><strong>English</strong></a> | <a href="https://meditorapp.pages.dev"><strong>官网</strong></a>
</p>

---

MEditor 是 **macOS 上给技术人写文档的 Agent 工作台**。核心闭环：**Agent 改文档 → 预览立即渲染 → 人机迭代**。

把它指向一个代码仓库或工作区，让 Agent 把工程师真正要写的文档写好 —— 周报、技术方案、changelog、API 文档、会议纪要。

纯 SwiftUI + AppKit，**无 Electron**；自带密钥（BYOK），**你的文档和模型密钥永远不离开你的机器**。

---

## ✨ 功能特性

### 🤖 真 Agent，不是聊天框

- **macOS 上 15 个工具（14 个跨平台），多轮循环** — Agent 读写、补丁式修改、搜索文档，操作工作区文件，驱动编辑器，执行沙盒 Shell 命令 —— 在多轮工具调用中持续推理，直到把活干完
- **三种后端** — OpenAI 兼容与 Anthropic（内置 9 家预设：Anthropic、OpenAI、DeepSeek、Kimi、GLM、通义千问、OpenRouter、Groq、Ollama），外加复用本机 Claude Code 登录态的 Claude CLI 后端
- **自带密钥（BYOK）** — 兼容任何 OpenAI 格式端点，密钥只存在本机 Keychain 里
- **全程流式** — 回复逐字流出；工具步骤内联展示，支持展开/折叠查看详情

### 🛡 敢让它动你的文件

- **写文件前确认** — Agent 写入前先问你；顺手时可"本次运行全部允许"
- **命令沙盒风险分级** — Shell 命令按风险分级后再执行
- **上下文预算** — token 预算自动淘汰，长会话不跑偏；停滞检测掐死空转循环；只读工具并行执行
- **运行可观测** — 每次运行展示 token 用量与耗时
- **行内 diff 审阅** — Agent 的修改以可审阅的 diff 落地，绝不覆盖你正在输入的内容；`@mention` 把文件拉进上下文；多会话历史保留每段对话

### ⚡ AI 织进写作流

- **斜杠命令库** — 编辑器里输入 `/` 唤出 `/ask` `/polish` `/outline` `/translate` `/summary` `/fix` `/table` 等命令；改文档的命令以流式 diff 呈现，确认后才写回
- **选区浮动操作条** — 选中文字浮出 改写 / 精简 / 扩写 / 翻译（选中列表还能转表格）；Esc 关闭
- **上下文自动化** — 对话自动附带当前文档（输入栏 chip 可移除、设置可关）；超预算时智能截取光标附近内容加首尾
- **诊断 → 一键修复** — 诊断面板和导出预检里点「让 Agent 修复」，模型修完自动重扫对比

### 🔄 闭环：改 → 渲染 → 迭代

- **实时预览** — 基于 marked.js 的 Markdown 渲染、highlight.js 代码高亮、Mermaid.js 图表、KaTeX 数学公式
- **跟得上的编辑器** — 原生 `NSTextView` 编辑，40+ 语言高亮，双向滚动同步，查找替换，快速打开（⌘P），标签页，FSEvents 驱动的文件浏览器
- **图片自动落盘** — 截图 ⌘V 或拖入图片，自动存入 `assets/` 并插入相对路径
- **本地历史快照** — 每次保存落快照（时间分层保留）；「文件历史」（⌃⌘H）面板 diff 对比、一键恢复，恢复本身也可撤销
- **全局搜索（⌘⇧F）**、TOC 大纲、标签页右键菜单（关闭其他 / Finder 显示 / 存为模板），以及 Finder 里的 Quick Look 空格预览
- **Todo 收件箱** — 侧栏收集任务，支持日历与周日程视图（EventKit）

### 🚀 交付与分享

- **局域网分享** — 内置 HTTP 服务，一次性令牌鉴权；也支持一键发布 **Gist**
- **在线发布** — 经 Cloudflare 一键发布到公网。托管免费档：每个 token 每月 20 篇、链接保留 30 天；Pro（Early access）不限量、永不过期
- **iOS 伴侣** — 在手机上通过 iCloud 编辑、聊天、发布（暂未上架 App Store；源码构建：Xcode 26+ 打开 `Mobile/MEditorMobile.xcodeproj`，选自己的签名团队，iOS 17+ 模拟器或真机）
- **放映模式与专注模式**，HTML / PDF / 2× PNG 导出，预览主题（GitHub / Nord / Dracula）
- **导出前检查** — 导出 PDF/HTML 前自动诊断死链、缺图、标题问题（设置可关）
- **PDF 导出主题** — 纸张、边距、页眉页脚、封面页可选；默认导出的 PDF 保留可点击链接
- **复制为富文本** — ⌥⌘C 复制渲染后的格式，贴到飞书 / 邮件保留排版
- **Sparkle 自动更新** — 安装包见 [meditorapp.pages.dev](https://meditorapp.pages.dev)

---

## 📋 系统要求

- **macOS** 14.0+ (Sonoma) · **iOS** 17.0+（伴生 App）
- **Xcode** 26+ —— `Package.swift` 是 `swift-tools-version: 6.2`，旧版 Xcode 连包都加载不了
- **Swift** 6.2+ (app and test targets in Swift 6 language mode, strict concurrency)

> **首次启动**：发布构建目前是 ad-hoc 签名（尚未公证），macOS 可能提示一次
> 「无法验证开发者」。右键 `MEditor.app` → **打开** 并确认即可，之后正常启动，
> 应用内自动更新不受影响。

## 🔧 构建与运行

### 快速启动

```bash
# 克隆仓库
git clone https://github.com/retrychx/Meditor.git
cd Meditor

# 使用 SPM 构建
swift build

# 直接运行（轻量模式，无应用图标）
swift run
```

### 运行测试

```bash
# 自动使用完整 Xcode toolchain
./scripts/test.sh

# 更短的别名
make test

# 静态守卫（与 CI 跑的是同一批脚本）
swiftlint lint --strict --config .swiftlint.yml Sources
python3 scripts/check_service_layer_deps.py
python3 scripts/check_dead_tokens.py
```

> **首次构建卡在下载 Sparkle** 通常是网络被中间人代理拦了。逃生舱：把
> `Sparkle-for-Swift-Package-Manager.zip` 解出的 `Sparkle.xcframework` 放进 `Vendor/`
> —— `Package.swift` 会自动检测并改用本地 binaryTarget（`Vendor/` 已 gitignore）。

### 生成 .app 包

```bash
# 构建后打包为 .app
swift build
bash scripts/bundle.sh

# 启动（带图标、Dock 驻留、文档类型关联）
open .build/debug/MEditor.app
```

> **注意：** `bundle.sh` 会自动对 `.app` 包进行 ad-hoc 签名。打开一次后，即可在任意 `.md` 或 `.html` 文件上使用 **显示简介 → 打开方式 → MEditor → 全部更改** 来关联文件类型。

### 版本号

每个平台的版本号都有唯一来源——**版本号在这里改**：

- **macOS**：编辑仓库根目录的 [`VERSION`](VERSION)。`scripts/bundle.sh` 打包时会把它注入 `MEditor.app` 的 `Info.plist`（`Sources/MEditor/Info.plist` 里的版本号只是占位符）。
- **iOS**：编辑 `Mobile/MEditorMobile.xcodeproj` 的构建设置 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。`Mobile/MEditorMobile/Info.plist` 通过 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 引用它们。

运行 `make version` 可查看当前版本号和上述提示。

### 稳定性承诺

Pre-1.0，但刻意保持无聊：语义化版本号、每个发布版都有 CHANGELOG 条目、破坏性变更
显式标注——至今没有过。更新包带 Ed25519 签名，Sparkle 安装前先验签。
**1.0 判据**：当前功能集稳定跑完一个完整发布周期——不承诺日期，不预留功能。

### 在 Xcode 中打开

```bash
open Package.swift
```

---

## ⚙️ AI 设置

打开 **设置（⌘,）→ AI**，选择一种后端：

| 后端 | 需要什么 |
|------|----------|
| 内置预设 | 从 9 家预设（Anthropic、OpenAI、DeepSeek、Kimi、GLM、通义千问、OpenRouter、Groq、Ollama）中选一个，填入 API Key，选模型 |
| Claude CLI | 什么都不用 —— 直接复用本机 Claude Code 登录态 |
| 自定义端点 | 任何 OpenAI 兼容的 Base URL + Key + 模型 |

没有 key？选 Claude CLI 后端，零配置跑起来。

### MCP Server（Claude Desktop、Cursor 等）

MEditor 内置基于 stdio 的 [MCP](https://modelcontextprotocol.io) Server，外部 agent 可以借此操作工作区——复用的正是应用内 Agent 的同一套工具层（文件读写/补丁、列目录、全局搜索，共 11 个；`open_file` / `insert_at_cursor` 等依赖 UI 的工具不在无头模式暴露，shell 工具 `run_command` 默认关闭）。

Claude Desktop 配置（`~/Library/Application Support/Claude/claude_desktop_config.json`）：

```json
{
  "mcpServers": {
    "meditor": {
      "command": "/Applications/MEditor.app/Contents/MacOS/MEditor",
      "args": ["mcp", "--workspace", "/path/to/your/workspace"]
    }
  }
}
```

不传 `--workspace` 时默认使用当前目录。shell 命令**默认不暴露**——加 `--allow-shell` 才会注册 `run_command`（共 12 个工具）。启用后走与应用内 Agent 相同的风险分级沙箱：blocked 级一律拒绝；warn 级（如 `git push`、`mv`）在无头模式下默认拒绝，可加 `--allow-warn-commands` 显式放开。无头模式没有确认弹窗，静态命令黑名单不构成安全边界——只对信任的工作区开启 `--allow-shell`。

---

## 🏗 项目结构

```
MEditor/
├── Package.swift
├── scripts/
│   ├── bundle.sh          # .app 包组装脚本
│   └── test.sh            # Xcode toolchain 测试脚本
├── docs/                  # 设计文档与历史分析
└── Sources/MEditor/
    ├── Models/            # EditorTab、FileItem、AgentTool、PluginSkill…
    ├── Protocols/         # FileService、SyntaxHighlight、AgentContext…
    ├── Services/
    │   ├── AI/
    │   │   ├── Agent/
    │   │   │   ├── AgentRunner.swift          # 多轮循环与状态
    │   │   │   ├── CommandSandbox.swift       # 风险分级的 Shell 沙盒
    │   │   │   ├── AgentHistoryBudget.swift   # 上下文 token 预算
    │   │   │   ├── Backends/
    │   │   │   │   ├── AgentBackend.swift     # 协议 + 默认流式回退
    │   │   │   │   ├── RestAgentBackend.swift # OpenAI 与 Anthropic SSE
    │   │   │   │   └── ClaudeCLIBackend.swift # claude CLI 子进程
    │   │   │   └── Tools/                     # 文档、编辑器、工作区、Shell 工具
    │   │   ├── InlineEditAction.swift         # 选区级修改 + diff 审阅（UI：Views/Editor/InlineEditBar、Views/Preview/PreviewInlineEditBar）
    │   │   ├── AIService.swift                # 对话补全与 provider 预设
    │   │   └── BeautifyAgent.swift            # 单发文档润色
    │   ├── MCP/           # MCP Server（stdio）：JSON-RPC、工具桥接、无头上下文
    │   ├── Core/          # AppSettings、Localization、MarkdownFormatter
    │   ├── File/          # FileService、FileWatcher、文件类型配置
    │   └── Calendar/      # CalendarService（EventKit）
    ├── Managers/          # Tab、FileTree、Share、Template、Todo…
    └── Views/
        ├── Agent/         # AgentStepView、AgentResultPanel
        ├── AI/            # AIAssistant、@mention 输入器
        ├── Editor/        # NativeEditorView、TabBar、InlineEdit…
        ├── Preview/       # MarkdownWebPreview、TOC、ExportBar
        ├── Sidebar/       # FileSidebar、FileRow、TodoSidebar…
        └── Shared/        # DesignTokens、ChromeButton、Toast…
```

---

## 🗺 路线图

**已交付**
- [x] 真 Agent：macOS 上 15 个工具（14 个跨平台）、多轮循环、三种后端（OpenAI 兼容 / Anthropic / Claude CLI）、BYOK
- [x] Agent 加固：写文件确认、命令沙盒风险分级、上下文预算、停滞检测、只读工具并行、用量显示
- [x] 行内编辑 diff 审阅、`@mention` 上下文、多会话历史
- [x] 斜杠命令库、选区浮动操作条、文档上下文自动附带
- [x] 图片粘贴/拖拽自动落盘、本地历史快照、标签页右键菜单
- [x] 导出预检 + 一键 Agent 修复、PDF 导出主题、复制为富文本
- [x] 全局搜索（⌘⇧F）、Quick Look 插件、Spotlight 索引与 Shortcuts intents
- [x] 局域网分享 + Cloudflare 在线发布（免费档 + Pro）
- [x] iOS 伴侣（iCloud 编辑 / 聊天 / 发布）
- [x] 放映与专注模式、HTML 导出、预览主题、Sparkle 自动更新
- [x] MCP Server —— 把 Agent 工具暴露给 Claude Desktop / Cursor
- [x] Onboarding —— 首启引导、零配置 Claude CLI、脚本化演示
- [x] Agent 运行一键回滚（run 级检查点）
- [x] Agent 写入默认 diff 审阅、连续微调、断点续传
- [x] 写入后自动诊断自检、Prompt 缓存、单次运行成本透明
- [x] 预览支持 LaTeX 数学公式渲染（KaTeX，资源离线内置）

**后续**
- [ ] 多窗口支持
- [ ] 编辑器字体/字号偏好
- [ ] Developer-ID 签名 + 公证（去掉首次启动的右键步骤）
- [ ] iOS 端补齐 macOS 已有能力：行内 diff 审阅 UI、本地历史、MCP server/client、
      局域网分享、PDF 导出、Todo/日历、Gist。iOS 端的定位是「编辑 / 聊天 / 发布」的
      精简伴侣（见上「iOS 伴侣」），这些能力在 `Mobile/` 下确实没有对应实现 ——
      属**范围差异**而非隐藏缺陷，列在这里以免被误读为「已具备」。

---

## 🤝 参与贡献

欢迎提 PR。`main` 是受保护分支 —— CI 全绿才能合并。

- **[CONTRIBUTING.md](CONTRIBUTING.md)** —— 人的流程：工具链要求、提交前必须跑什么、发版流程。
- **[AGENTS.md](AGENTS.md)** —— 代码约定（分层依赖、iOS 共享内核、Swift 6 并发规则、版本单源），
  同时也是 AI 编码助手的入口。
- **[docs/engineering-practices.md](docs/engineering-practices.md)** —— 四道质量闸门为什么存在、本地怎么跑。
- **[CHANGELOG.md](CHANGELOG.md)** —— 各版本的对外变更。
- **[SECURITY.md](SECURITY.md)** —— 安全漏洞走私有通道上报，别开公开 issue。

---

## 📄 开源协议

[MIT](LICENSE)

---

*用心打造 · 纯原生 macOS 体验*
