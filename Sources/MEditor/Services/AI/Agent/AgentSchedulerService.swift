#if os(macOS)
import Foundation
import Observation

// MARK: - AgentSchedulerService（cron 定时触发的后台 Agent 任务，macOS-only）
//
// 每分钟 tick 一次，命中 cron 的启用条目即复用 BackgroundAgentTaskService
// 发起后台 run——写文件默认仍走标准确认条 / diff 审阅链路，scheduler 不绕过任何安全边界；
// 条目显式声明 autoApprove 时按 writeAutoApproval 策略免确认（只跳确认条，工作区边界
// 与 run 级快照回滚不变，见 ScheduledTaskConfig）；AI 未配置时触发优雅失败
// （toast 提示，不崩溃不静默）。
//
// 宿主依赖收在 `AgentHostPort` 端口上（P0-10）：本文件不直接命名 ViewModel 类型。
// 端口同时被 BackgroundAgentTaskService 使用，两个服务共用同一份宿主能力白名单
// （护栏见 scripts/check_service_layer_deps.py）。
//
// 定价线（战略复核 §6）：定时自动化是 Pro 功能——fire 前查 ProEntitlementService 的
// 缓存判定（isProEntitled 注入点，门控本身不联网）；聊天侧手动发起的后台任务
// （BackgroundAgentTaskService.start）不门控，免费档含「手动触发 agent」。
// 本仓 MIT 开源，本地门控是「官方分发二进制的荣誉系统」——不试图拦自己编译的人。
//
// 已知取舍（有意从简）：
// - App 睡眠 / 未运行期间错过的触发不补跑——定位是「App 在线时的定时触发」，不是精确闹钟
// - 触发去重粒度为「分钟」：同一分钟内不会重复触发同一条目
// - 手动编辑 schedules.json 不热加载：工作区切换 / 设置页打开时才重载
@MainActor
@Observable
final class AgentSchedulerService {

    /// 合并后的条目列表（设置页数据源）
    private(set) var entries: [ScheduledTaskConfig] = []
    /// 配置解析容错记录（坏条目说明）
    private(set) var configIssues: [String] = []

    private weak var host: (any AgentHostPort)?

    /// 时钟（测试注入固定值，不依赖真实时间等待）
    var now: () -> Date = { Date() }
    /// cron 求值用的日历（默认本地时区；测试注入固定时区）
    var calendar: Calendar = .current
    /// 触发动作（测试注入记录器；默认在 init 末尾指向 fire → BackgroundAgentTaskService.start）
    var trigger: (ScheduledTaskConfig) -> Void = { _ in }
    /// Pro 资格判定（测试注入；默认读 ProEntitlementService 的缓存判定——
    /// 门控不联网，离线宽限语义由 ProEntitlementService 的 verdict 缓存保证）
    var isProEntitled: () -> Bool = { ProEntitlementService.shared.isProActive }
    /// 全局配置路径（测试指向临时目录）
    var globalConfigURL: URL
    /// 最近一次 reload 时的工作区（启用开关写回工作区文件时用）
    private var currentWorkspaceURL: URL?

    /// 触发去重：条目名 → 上次触发的分钟桶（同分钟不重复触发）
    private var lastFiredMinute: [String: Date] = [:]
    /// 分钟 tick 计时器。服务挂在宿主上（App 生命周期），无需 deinit 里
    /// invalidate；即便释放，Timer 闭包持 weak self 也只是空转。
    private var timer: Timer?

    init(host: (any AgentHostPort)? = nil,
         globalConfigURL: URL = ScheduledTaskConfigLoader.defaultGlobalConfigURL,
         startTimer: Bool = true) {
        self.host = host
        self.globalConfigURL = globalConfigURL
        // 默认触发动作走真实发起链路（弱引用 self，测试可整体替换为记录器）
        self.trigger = { [weak self] entry in self?.fire(entry) }
        reload(workspaceURL: host?.rootURL)
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }
    }

    // MARK: - 配置重载

    /// 重载配置（App 启动 / 工作区切换 / 设置页操作时调用）。
    /// 触发去重表跨 reload 保留：重载后同分钟内不会重复触发同一条目。
    func reload(workspaceURL: URL?) {
        currentWorkspaceURL = workspaceURL
        let result = ScheduledTaskConfigLoader.load(globalConfigURL: globalConfigURL,
                                                    workspaceRoot: workspaceURL)
        entries = result.entries
        configIssues = result.issues
        for issue in result.issues {
            AppLog.app.warning("schedules.json: \(issue, privacy: .public)")
        }
    }

    /// 条目的下一次触发时间（设置页展示用；nil = 永不命中，如 "0 0 30 2 *"）
    func nextFireDate(for entry: ScheduledTaskConfig) -> Date? {
        entry.schedule.nextFire(after: now(), calendar: calendar)
    }

    // MARK: - 启用开关写回

    /// 切换条目启用状态：写回其来源文件后重载。失败 toast 提示。
    func setEnabled(_ enabled: Bool, entry: ScheduledTaskConfig) {
        let url: URL
        switch entry.source {
        case .global:
            url = globalConfigURL
        case .workspace:
            guard let root = currentWorkspaceURL else { return }
            url = ScheduledTaskConfigLoader.workspaceConfigURL(root: root)
        }
        do {
            try ScheduledTaskConfigWriter.setEnabled(enabled, forName: entry.name, configURL: url)
        } catch {
            AppLog.app.error("schedules.json write-back failed: \(error.localizedDescription, privacy: .public)")
            host?.showToast(error.localizedDescription, icon: "exclamationmark.triangle")
        }
        reload(workspaceURL: currentWorkspaceURL)
    }

    // MARK: - tick

    /// 检查到期条目并触发。Timer 每分钟调用一次，测试也可直接调用。
    /// Timer 不保证对齐整分钟且可能被 UI 卡顿顺延——matches 按当前分钟判定，
    /// 分钟粒度去重保证每个命中分钟最多触发一次。
    func tick() {
        let nowDate = now()
        let minuteBucket = Date(timeIntervalSince1970: floor(nowDate.timeIntervalSince1970 / 60) * 60)
        for entry in entries where entry.enabled {
            guard entry.schedule.matches(nowDate, calendar: calendar) else { continue }
            guard lastFiredMinute[entry.name] != minuteBucket else { continue }
            lastFiredMinute[entry.name] = minuteBucket
            trigger(entry)
        }
    }

    // MARK: - 触发

    /// 默认触发动作：无 Pro 资格时 toast 引导（不发起 run）；AI 未配置时 toast 优雅失败；
    /// 否则复用宿主的 backgroundAgentTasks 发起后台 run（写入确认/审阅链路、并发上限、
    /// 完成通知全部沿用）。
    private func fire(_ entry: ScheduledTaskConfig) {
        guard let host else { return }
        // Pro 门控在 AI 配置检查之前：无资格时只需一条引导提示，
        // 与 AI 是否配置无关。toast 走宿主端口，测试经 RecordingAgentHost 可断言。
        guard isProEntitled() else {
            host.showToast(L("ai.schedule.proRequired", entry.name),
                           icon: "lock.fill")
            return
        }
        let settings = AppSettings.shared
        let config = AIConfig.current(settings, scene: .agent)
        guard config.isConfigured else {
            host.showToast(L("ai.schedule.notConfigured", entry.name),
                           icon: "exclamationmark.triangle")
            return
        }
        host.backgroundAgentTasks.start(
            prompt: entry.prompt,
            // system prompt 复用聊天/手动后台任务同一份 grounding（不附带当前文档全文）
            systemPrompt: host.agentGroundingPrompt(settings: settings, includeFullDoc: false),
            config: config,
            maxSteps: settings.aiAgentMaxSteps,
            writeAutoApproval: entry.writeAutoApproval
        )
    }
}
#endif
