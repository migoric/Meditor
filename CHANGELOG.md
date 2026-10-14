# Changelog

本文件记录 MEditor 的对外变更。格式按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号按 SemVer（`0.x` 阶段：破坏性变更走 minor）。

> ⚠️ 本文件从 **0.12.0** 起建立。更早的版本在文件创建前发布，只有 GitHub Release 上那条
> 自动生成的记录（`release.yml` 用 tag 区间的提交标题拼的），见
> <https://github.com/retrychx/Meditor/releases> —— 不在这里补写，补写就等于编历史。
>
> 发布时的 GitHub Release 正文由 `release.yml` 从提交标题自动生成（见 `CONTRIBUTING.md`「发版流程」）；
> 本文件是**人写的、按变更性质归类**的那一份，两者互补。

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
