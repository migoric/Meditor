# Changelog

本文件记录 MEditor 的对外变更。格式按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号按 SemVer（`0.x` 阶段：破坏性变更走 minor）。

> ⚠️ 本文件从 **0.12.0** 起建立。更早的版本在文件创建前发布，只有 GitHub Release 上那条
> 自动生成的记录（`release.yml` 用 tag 区间的提交标题拼的），见
> <https://github.com/retrychx/Meditor/releases> —— 不在这里补写，补写就等于编历史。
>
> 发布时的 GitHub Release 正文由 `release.yml` 从提交标题自动生成（见 `CONTRIBUTING.md`「发版流程」）；
> 本文件是**人写的、按变更性质归类**的那一份，两者互补。

## [Unreleased]

**数学公式渲染 + 关闭窗口不再退出应用。**

### Added

- **Markdown 预览支持 LaTeX 数学公式**（KaTeX 0.19.0，资源离线内置，不联网）：
  行内 `$...$`、块级 `$$...$$`，覆盖矩阵、分数、积分、求和、希腊字母、上下标等。
  实现沿用 mermaid 的**占位符模式**——marked 解析前摘出公式、过完 DOMPurify 之后
  才交给 KaTeX 渲染，因此块级缓存与增量 DOM patch 照常生效；`nodesEqual` 增加了
  数学归一化比较，否则「DOM 里是渲染结果、新 HTML 里是空占位符」会让每次编辑都
  重建整块并重渲染全部公式（行内公式会把所在段落一起拖下水）。
  代码块与行内代码里的 `$` 不参与识别（先原地遮蔽成等长占位串再扫描），货币写法
  （`$5 到 $10`）按 KaTeX auto-render 的启发式排除。

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
  目录改用**条目覆盖判据**（递归比较相对路径集合，含二级目录）。
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
