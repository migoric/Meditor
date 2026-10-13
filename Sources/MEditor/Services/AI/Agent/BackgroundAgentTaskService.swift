#if os(macOS)
import Foundation
import Observation
import UserNotifications

// MARK: - BackgroundAgentTask

/// 一条后台 Agent 任务：脱离聊天会话 UI 独立运行的 agent run。
/// 不持久化（重启清空）——完成任务的结果摘要已在完成时经 toast/系统通知送达，
/// 列表只是本次 App 会话内的进行中/最近完成视图。
@MainActor
@Observable
final class BackgroundAgentTask: Identifiable {
    let id = UUID()
    /// 展示标题（prompt 首行截断）
    let title: String
    let startedAt: Date
    var endedAt: Date? = nil
    /// 结束方式（复用 AgentRunTermination 语义；.running = 进行中）。
    /// 由 Runner 收尾回调从 runState.termination 同步过来，UI 据此渲染状态图标。
    var termination: AgentRunTermination = .running
    /// 结果摘要：done = finalText 首行；failed = 错误首行；cancelled = nil（状态图标已表达）。
    var resultSummary: String? = nil
    /// run 级文件快照（一键回滚数据挂在 runState 上，与聊天 run 同一语义）
    let checkpoint: AgentRunCheckpoint
    /// 持有 Runner：取消走 runner.cancel()（含挂起确认解除），
    /// 步骤摘要直接复用 runner.state.steps 展示，不另起存储。
    let runner: AgentRunner

    var isRunning: Bool { termination == .running }

    /// 耗时（进行中按当前时间实时计，结束后定格）
    var durationSeconds: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    init(title: String, runner: AgentRunner, checkpoint: AgentRunCheckpoint) {
        self.title = title
        self.startedAt = Date()
        self.runner = runner
        self.checkpoint = checkpoint
    }
}

// MARK: - BackgroundAgentTaskService

/// 后台 Agent 任务管理：新建独立 AgentRunner + 独立 AgentContext，
/// 与聊天会话的流式渲染完全解耦，用户发起后可继续编辑/聊天。
///
/// 安全边界：写入仍走现有确认条 / diff 审阅链路（contextFactory 默认经
/// `AgentHostPort.makeAgentContext` 产出标准 context，reviewFileWrite /
/// confirmFileWrite 一套不变）。后台任务没人盯着时确认条挂着不响应是预期行为，
/// 超时路径由 AgentRunner 兜底。
///
/// 宿主依赖收在 `AgentHostPort` 端口上（P0-10）：本文件不直接命名 ViewModel 类型，
/// 「Service 能对宿主做什么」由协议成员白名单限定（护栏见
/// `scripts/check_service_layer_deps.py`）。
@MainActor
@Observable
final class BackgroundAgentTaskService {

    /// 同时运行的后台任务上限；超出的发起请求直接拒绝并 toast（拒绝比排队简单可控）。
    static let maxConcurrent = 2
    /// 已完成任务保留上限：防列表无限增长（仅内存，重启即清）
    static let maxFinishedKept = 20

    /// 任务列表，最新在前
    private(set) var tasks: [BackgroundAgentTask] = []

    /// 宿主能力端口（弱引用：服务不得延长宿主生命周期）。nil = 无宿主（测试 / headless）。
    private weak var host: (any AgentHostPort)?
    private let backendFactory: @Sendable (AIConfig) -> any AgentBackend
    /// context 工厂（测试注入 MockAgentContext；默认经宿主的 `makeAgentContext` 创建标准
    /// context，写确认/审阅链路与聊天 run 完全一致）。返回 nil = 无法创建（宿主已释放）。
    var contextFactory: @MainActor (AgentRunCheckpoint) -> (any AgentContextProtocol)?
    /// 系统通知发送（测试注入 spy；默认 UNUserNotificationCenter，
    /// 权限被拒 / 未签名 / 非 .app 环境一律静默降级为仅 toast，不崩溃）。
    var systemNotify: @MainActor (String, String) -> Void

    init(host: (any AgentHostPort)? = nil,
         backendFactory: @escaping @Sendable (AIConfig) -> any AgentBackend = { AgentBackendFactory.make(config: $0) }) {
        self.host = host
        self.backendFactory = backendFactory
        self.contextFactory = { [weak host] checkpoint in
            host?.makeAgentContext(checkpoint: checkpoint)
        }
        self.systemNotify = { title, body in
            BackgroundTaskNotifier.post(title: title, body: body)
        }
    }

    // MARK: - 发起

    /// 发起后台任务。达到并发上限或无法创建 context 时返回 nil（已 toast 提示）。
    @discardableResult
    func start(prompt: String, systemPrompt: String, config: AIConfig, maxSteps: Int) -> BackgroundAgentTask? {
        let running = tasks.filter(\.isRunning).count
        guard running < Self.maxConcurrent else {
            host?.showToast(L("ai.background.limitReached", Self.maxConcurrent), icon: "hourglass")
            return nil
        }
        let checkpoint = AgentRunCheckpoint()
        guard let context = contextFactory(checkpoint) else { return nil }

        let runner = AgentRunner(maxSteps: maxSteps, backendFactory: backendFactory)
        let task = BackgroundAgentTask(title: Self.title(from: prompt), runner: runner, checkpoint: checkpoint)
        tasks.insert(task, at: 0)
        trimFinished()

        let workspaceURL = host?.rootURL
        Task { [weak self, weak task] in
            // MCP 工具与聊天 run 同一来源：run 开始时懒连接，连接失败的降级为跳过
            var tools = BuiltinAgentTools.all
            if let host = self?.host {
                tools.append(contentsOf: await host.mcpToolsForRun(workspaceURL: workspaceURL))
            }
            // 取消竞态：MCP 懒连接期间用户已从任务列表取消——直接放弃启动
            guard let self, let task, task.isRunning else { return }
            runner.onComplete = { [weak self, weak task] in
                guard let self, let task else { return }
                self.handleFinish(task)
            }
            runner.run(systemPrompt: systemPrompt, userMessage: prompt,
                       tools: tools, config: config, context: context)
        }
        return task
    }

    /// 取消单个任务（走 runner.cancel()：挂起的命令/写入确认与 diff 审阅一并解除）。
    /// 先落终态再 cancel runner：onComplete 异步触发的 handleFinish 以 isRunning
    /// 守卫保证只收尾一次；runner 尚未真正启动（MCP 懒连接的 Task 窗口）时
    /// onComplete 不会来，此处的直接收尾就是唯一收尾。
    func cancel(_ task: BackgroundAgentTask) {
        guard task.isRunning else { return }
        task.termination = .cancelled
        task.endedAt = Date()
        task.runner.cancel()
        notifyFinish(task)
    }

    // MARK: - 收尾

    private func handleFinish(_ task: BackgroundAgentTask) {
        // cancel() 已直接收尾的场景（runner 的 onComplete 晚到）：静默跳过
        guard task.isRunning else { return }
        let state = task.runner.state
        task.termination = state.termination
        task.endedAt = Date()
        // run 级快照挂入 runState（与聊天 run 同一语义）：确有写入时数据可用于回滚
        if task.checkpoint.hasWrites {
            state.checkpoint = task.checkpoint
        }
        switch state.termination {
        case .completed:
            task.resultSummary = Self.firstLine(state.finalText)
        case .failed:
            task.resultSummary = Self.firstLine(state.error ?? "")
        case .cancelled, .running:
            task.resultSummary = nil
        }
        notifyFinish(task)
    }

    /// 完成通知：宿主 toast + 系统通知（失败时带原因摘要；通知失败静默降级为仅 toast）
    private func notifyFinish(_ task: BackgroundAgentTask) {
        let toastText: String
        let icon: String
        switch task.termination {
        case .completed:
            toastText = L("ai.background.done", task.title)
            icon = "checkmark.circle"
        case .failed:
            toastText = L("ai.background.failed", task.title, task.resultSummary ?? "")
            icon = "exclamationmark.triangle"
        case .cancelled:
            toastText = L("ai.background.cancelled", task.title)
            icon = "xmark.circle"
        case .running:
            return
        }
        host?.showToast(toastText, icon: icon)
        systemNotify(L("ai.background.notificationTitle"), toastText)
    }

    // MARK: - Helpers

    /// 标题 = prompt 首行，截断 40 字
    private static func title(from prompt: String) -> String {
        let line = prompt.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? prompt
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// 结果摘要 = 首行，截断 120 字（多行结果只露第一行）
    private static func firstLine(_ text: String) -> String? {
        let line = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    /// 已完成任务超过保留上限时从最老一端丢弃（进行中的永不清理）
    private func trimFinished() {
        let finished = tasks.filter { !$0.isRunning }
        guard finished.count > Self.maxFinishedKept else { return }
        let dropIDs = Set(finished.suffix(finished.count - Self.maxFinishedKept).map(\.id))
        tasks.removeAll { dropIDs.contains($0.id) }
    }
}

// MARK: - BackgroundTaskNotifier

/// 系统通知封装：UNUserNotificationCenter 需要签名 bundle + 用户授权，
/// 未签名开发构建 / 权限被拒 / 非 .app 环境（如测试 runner）一律静默不发送，
/// 调用方保证 toast 已发，通知只是增强通道。
enum BackgroundTaskNotifier {
    static func post(title: String, body: String) {
        // 只在真实 .app bundle 里尝试：SwiftPM 测试 runner / 裸可执行环境下
        // UNUserNotificationCenter.current() 可能直接异常，先挡掉
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            // 权限被拒：静默降级（toast 已展示），不弹错不崩溃
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
#endif
