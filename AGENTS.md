# AGENTS.md —— 仓库结构与协作约定

> **定位**：macOS 原生 Markdown 文档工作台，核心是**「Agent 改文档 → 预览即时渲染 → 你来迭代」**。
> 不是「带 AI 的编辑器」，而是把 **AI 改文档**当作主路径、手动编辑当兜底的产品（`docs/design-as-built.md` §0 第 2 条）。
>
> 改这个仓库时**不要把 Agent 的写入路径当普通功能**：写前 diff 审阅、写确认、命令沙箱、
> run 级快照回滚，这四件是本仓的对外承诺。新增工具 / 新增写入入口若绕开它们，就是倒退。
> 唯一例外是 `schedules.json` 条目**显式声明**的 `autoApprove`（定时任务无人值守写入，
> 见 `ScheduledTaskConfig.writeAutoApproval`）：它只跳过确认条 / 审阅态，工作区边界与
> run 级快照回滚不变，且缺省关闭——交互 run 的确认链路不受影响。

本文档是**代码约定的唯一入口**（人和 AI coding agent 共用一份）。
面向**人**的流程（开分支、提 PR、发版）见 [`CONTRIBUTING.md`](./CONTRIBUTING.md)；
四条质量机制的**为什么**见 [`docs/engineering-practices.md`](./docs/engineering-practices.md) ——
本文只讲**怎么改代码**，不重复那两处，避免出现两套说法。

---

## 1. 布局与体量

```
Meditor/
├── Package.swift                 # swift-tools-version 6.2（⇒ 必须 Xcode 26 工具链）
├── VERSION                       # macOS 版本单源（bundle.sh 注入 Info.plist）
├── Sources/MEditor/              # 桌面端主体 —— 273 个 .swift / ~53.6k 行
│   ├── Models/  Protocols/       # 数据模型与结构接口（最底层，零上层依赖）
│   ├── Services/                 # 能力层：AI（Agent/Backends/Tools）、MCP、Core、File…
│   ├── Managers/                 # 状态管理：Tab / FileTree / Share / Template / Todo…
│   ├── ViewModels/               # AppState（组合式状态层）＋ 各 @Observable UI 状态
│   └── Views/                    # SwiftUI + AppKit 视图
├── Tests/MEditorTests/           # 130 个 .swift / ~25.8k 行
├── Mobile/                       # iOS 伴生 App（独立 Xcode 工程）
│   └── Sources/                  # 29 个 .swift / ~6.5k 行
├── worker/                       # Cloudflare Workers（在线发布后端，独立 toolchain）
├── website/  pages/              # 静态站与文档页
└── scripts/                      # 打包 / 测试 / 覆盖率 / 守卫脚本
```

**体量读数会腐烂** —— 上面的数字是 2026-10-23 的实测值，**引用前请现场复算**：

```bash
find Sources/MEditor -name '*.swift' | wc -l
find Sources/MEditor -name '*.swift' -exec cat {} + | wc -l
```

当前最大的五个文件（也是重构优先级最高的五个）：`Services/Core/Localization.swift` 1344 行、
`Services/AI/AIService.swift` 845 行、`Services/AI/Agent/AgentRunner.swift` 843 行、
`ViewModels/AppState.swift` 819 行、`Views/AI/AtMention/AtMentionComposerView.swift` 812 行。

（数字为 2026-10-22 实测。对比 10-17 那版：`AIService.swift` 与 `AppState.swift` 五天内各涨了
~90/~60 行并反超进榜——这两个正是打磨期要拆的热文件，涨速本身就是证据。）

---

## 2. 分层与依赖方向

```
Views ──▶ ViewModels(AppState) ──▶ Managers ──▶ Services ──▶ Models / Protocols
```

**只许自上而下**。三条会被守卫拦下的具体规则：

### 2.1 Service 层不得命名 ViewModel 类型（`AppState`）

Service 要宿主能力时走**端口**，不要直接抓 `AppState`。既有两个：

| 端口 | 管什么 | 装配点 |
|---|---|---|
| `AgentDocumentAdapter` | 文档读写 / Tab 查询 / 写前审阅 / 命令确认 | `AgentContext.make(appState:checkpoint:)`（组合根） |
| `AgentHostPort` | run 生命周期反馈：toast / 工作区 / MCP 工具 / 后台任务 / grounding | `extension AppState: AgentHostPort` |

守卫：`scripts/check_service_layer_deps.py`（CI `Layer Guard` job）。
**棘轮式** —— 已搬到端口的文件不得再出现 `AppState`；新出现的反向依赖必须显式登记
（改走端口，或写进 `KNOWN_HOST_AWARE` 并写明理由）。

Presenter / 组合根（`AIChatCoordinator`、`InlineEditSession`、`SlashAICommandExecutor`、
`AgentDemoFlow`）命名 `AppState` 是职责所在，已登记在名单里 —— 但**往名单里加东西要先问为什么**。

### 2.2 设计 token 必须有人用

UI 常量走 `DS.*`（`Views/Shared/DesignTokens.swift`）。**定义了没人用的 token 不是无害的备件**：
它看起来像某个用途的官方取值，下一个人就会照着用，然后和界面实际行为悄悄分叉。

守卫：`scripts/check_dead_tokens.py`（CI `UI Guard` job）。例外（半径档位这类「菜单」）登记在
`ALLOW_UNUSED` 并写明理由；**登记项一旦被采用也要从名单删掉**（同一条棘轮）。

同理，**写新 UI 时不要硬编码**字号 / 圆角 / 动效 —— 现状是裸 `.system(size:` 与数字
`cornerRadius:` 仍大量存在（收口未完成，见 `docs/design-as-built.md` §10），别再加。

### 2.3 共享内核：iOS 侧是**手工清单**

iOS target 在 `Mobile/MEditorMobile.xcodeproj/project.pbxproj` 的 `Shared` 组里**逐条枚举**
`../Sources/MEditor/**` 的文件（当前 **50 条**），不是文件系统同步组。后果：

- **新增一个共享文件，必须同时改 pbxproj**，否则 iOS 静默缺文件、编译红。
- 共享文件里**不许有未包裹的 AppKit 依赖**（用 `#if os(macOS)`）。目前唯一合法的
  `import AppKit` 在 `AIImageAttachment.swift` 的 `#if` 内。
- 共享代码**不许直接读 `AppSettings.shared`** —— iOS 上是 `Mobile/Sources/Shims/AppSettingsShim.swift`
  这个替身，取到的是假值。shim 文件里自带「命中清单」，新增引用要一并复核。

复算当前条目数：

```bash
python3 - <<'PY'
import re
s = open('Mobile/MEditorMobile.xcodeproj/project.pbxproj').read()
for b in re.findall(r'isa = PBXGroup;(.*?)\};', s, re.S):
    if re.search(r'name = Shared;', b):
        print(len(set(re.findall(r'^\s*([0-9A-F]{24}) /\*', b, re.M))))
PY
```

> ⚠️ **别用 `grep 'path = \.\./Sources/MEditor/.*\.swift'` 数** —— 文件名含 `+` 的
> （如 `FileManager+Directories.swift`）在 pbxproj 里是**带引号**写的，裸正则静默漏掉它。
> 本仓真踩过：据此把 39 个 `.swift` 数成 38，还反过来「纠正」了正确的数字。

### 2.4 Swift 6 严格并发

app 与测试 target 都在 `.swiftLanguageMode(.v6)` 下编译。几条本仓的实际做法：

- ViewModel / Manager / Service 大多 `@MainActor`；跨线程数据用 `Sendable` 值类型。
- 逃逸到并发域的引用必须显式标注（`@unchecked Sendable` / `nonisolated(unsafe)`）**并写清为什么安全** ——
  裸加标注等于关掉编译器在这处的检查。
- 主 actor 上同步调用 `nonisolated` API 用 `MainActor.assumeIsolated`；
  它只在调用点确实位于主线程时正确，**不要拿它当消音器**。
- 逃逸清单必须与代码同步。这里曾经列着两处「未加锁可变 static」，实测**早已加锁**
  （`AIService.memoryFallback` → `fallbackLock`，`PreviewAssetMirror.mermaidProvisioned`
  → `mermaidLock`），而真正没加锁的 `LocalizationManager.language` 反倒不在清单里。
  现状：三处都已改成锁内访问，**清单为空**。
  ⇒ 下次加 `@unchecked Sendable` 就往这里补一条并写清为什么安全；改完记得删。

---

## 3. 构建 / 测试 / 门禁

```bash
swift build                 # 编译桌面端（前提：xcode-select 指向 Xcode，见下）
./scripts/test.sh           # = swift test（显式指向 Xcode 工具链）
make test                   # 上面那条的别名
make version                # 打印版本 + 改哪里

# iOS（只 build，无测试 target）
xcodebuild -project Mobile/MEditorMobile.xcodeproj -scheme MEditorMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

# Lint（与 CI 同一条命令；--strict 让 warning 也算失败）
swiftlint lint --strict --config .swiftlint.yml Sources

# 本文提到的守卫（都可单独跑，退出码非 0 = 红）
python3 scripts/check_service_layer_deps.py
python3 scripts/check_dead_tokens.py
python3 scripts/check_docs_consistency.py   # 文档断言 vs 代码事实
python3 scripts/check_bare_numbers.py       # 裸字号/圆角/路径 try? 棘轮（只许降）
```

> ⚠️ **`swift build` 的前提是 `xcode-select -p` 指向 Xcode**。指向 CommandLineTools 时
> 连清单都解析不了，报的是 `Invalid manifest` 这种完全不指向真因的错——
> 解法是 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`。
> `scripts/test.sh` 已经内置了这一步，裸 `swift build` 没有。

CI 里三个编译 gate（其余见 `docs/engineering-practices.md` §1）：
`Build & Test (macOS 26)` · `Build (x86_64)` · `Build (iOS Simulator)`。
`SwiftLint` 与 `Coverage Gate` 已并入 `Build & Test`（同一台 macOS runner 里顺序执行）。
`Build (x86_64)` 只 `swift build --arch x86_64`：runner 是 arm64，不编这一条的话
「发布包（Universal）的 Intel 半边能不能编」要等打 tag 才知道。
分支保护（`protected: true`）的必需检查共 **8 个**：上面三个编译 gate 加五个守卫 job
（`Layer Guard` / `UI Guard` / `Docs Guard` / `Worker Tests` / `iOS Shared Source Guard`，
2026-10-22 起全部必需）—— 改任何一个的名字或给 `pull_request` 加
`paths-ignore` 都会让 PR 卡在一个永不出现的检查上。

**本地跑不动的两处，如实说明**：

- 覆盖率门槛要 lcov，得先 `swift test --enable-code-coverage` 再 `llvm-profdata` + `llvm-cov export`，
  完整命令见 `docs/engineering-practices.md` §3。
- ⚠️ 本机网络若被中间人代理拦（Cloudflare / `registry.npmjs.org` 之类），SwiftPM 拉 Sparkle
  二进制会失败。逃生舱：把 `Sparkle-for-Swift-Package-Manager.zip` 解出的
  `Sparkle.xcframework` 放到 `Vendor/`（`Package.swift` 会自动检测并改走本地 binaryTarget；
  `Vendor/` 已 gitignore）。

---

## 4. 版本号：**两处单源，各自独立**

| 平台 | 改哪里 | 注入方式 |
|---|---|---|
| macOS | 仓根 `VERSION` | `scripts/bundle.sh` 写进 `MEditor.app` 的 `Info.plist`（源码里的版本键是占位符） |
| iOS | `Mobile/MEditorMobile.xcodeproj` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `Info.plist` 用 `$(MARKETING_VERSION)` 引用 |

两端按设计**各自独立演进**，两个数字不必相等 —— 别「顺手对齐」。
`release.yml` 只校验 macOS 侧（已知覆盖缺口：iOS 的 `MARKETING_VERSION` 目前没有自动校验）。

---

## 5. 提交与 PR

- 分支：`feat/…` · `fix/…` · `docs/…` · `chore/…` · `refactor/…` · `ci/…`
- 提交信息：Conventional Commits 前缀；正文讲**为什么**（不只是做了什么）。
  语义有变更的用 `!` 标记并说明兼容性影响。
- `main` 受保护：直接 push 会被拒（`enforce_admins` 也开着）。改动一律走 PR，CI 全绿才能合。
- PR 模板里那份自查清单**是清单，不是仪式** —— 尤其「新增/修改的守卫做过反向验证」那一条。

---

## 6. 守卫必须反向验证过

新增一条检查（lint 规则、脚本、测试断言）时，**先证明它会咬人**：
把实现改回有问题的样子 → 确认它变红 → 再恢复。

没做过反向验证的守卫很可能是**永远绿的空断言** —— 它不产生任何保护，却让人以为有。
本仓已有的守卫都附了变异验证结论（见对应 PR 说明）。

同理，凡是文档里出现「某机制负责某外观 / 某文件负责某路径」这类句子，
**都要落到调用点上核一遍**：`SidebarVibrancyView` 这类文件长期存在于仓库却 0 调用，
而 `docs/design-as-built.md` 曾把它当生效的机制来写。**文件存在 ≠ 生效**。

---

## 7. 决策记录落在哪儿

| 内容 | 位置 |
|---|---|
| 设计现状（实际长什么样） | `docs/design-as-built.md` |
| 设计目标与演进 | `docs/design-spec-v3.md` · `docs/design-spec-v3-implementation-plan.md` |
| 质量机制是什么 / 为什么 | `docs/engineering-practices.md` |
| 版本变更 | [`CHANGELOG.md`](./CHANGELOG.md) |
| 深度审计与整改记录 | 审计报告在仓外维护；**进仓的是结论与被证伪的断言** —— 见 `CHANGELOG.md` 与 `docs/engineering-practices.md` |

改语义要同步 `CHANGELOG.md`；改现状要同步 `docs/design-as-built.md`。
**报告里被证伪的断言要留着并标注**，不要悄悄改掉 —— 那是后来人最容易重犯的坑。
