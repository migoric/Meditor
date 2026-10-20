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

### Changed

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
