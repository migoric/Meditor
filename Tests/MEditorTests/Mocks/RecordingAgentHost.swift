import Foundation
@testable import MEditor

// MARK: - RecordingAgentHost

/// `AgentHostPort` 的记录型假宿主：每次端口调用都留痕，供断言「Service 对宿主的反馈」。
///
/// 这是 P0-10（Service 层反向依赖 ViewModel）修复带来的直接可测性收益——
/// 修复前 `BackgroundAgentTaskService` / `AgentSchedulerService` 各自持
/// `weak var appState: AppState?`，单测只能传 `nil`，于是并发上限 / 完成 / 取消 /
/// 写回失败这些反馈分支「跑过但没有任何痕迹」，既断言不了也 review 不到。
/// 现在反馈经端口，假宿主即可把它们变成可断言的记录。
///
/// `mcpToolsForRun` 恒返回 `[]`：既满足协议，又让测试完全不碰真实 `mcp.json`
/// （生产实现会读配置、必要时拉起 MCP 子进程，那不是单测该做的事）。
@MainActor
final class RecordingAgentHost: AgentHostPort {

    /// 端口收到的 toast 序列（text, icon）
    var toasts: [(text: String, icon: String?)] = []
    /// `mcpToolsForRun` 收到的 workspaceURL 序列
    var mcpCalls: [URL?] = []
    /// `makeAgentContext` 调用次数
    var contextsMade = 0
    /// `agentGroundingPrompt` 调用次数
    var groundingCalls = 0

    var rootURL: URL? = URL(fileURLWithPath: "/tmp/recording-agent-host-ws")
    /// 注入的 context（避免走真实 `AgentContext.make`）
    var context: (any AgentContextProtocol)?
    /// 仅为满足协议——用到定时任务链路的测试可替换为真实服务
    lazy var backgroundAgentTasks = BackgroundAgentTaskService(host: nil)

    func showToast(_ text: String, icon: String?) {
        toasts.append((text, icon))
    }

    func mcpToolsForRun(workspaceURL: URL?) async -> [any AgentTool] {
        mcpCalls.append(workspaceURL)
        return []
    }

    func makeAgentContext(checkpoint: AgentRunCheckpoint) -> any AgentContextProtocol {
        contextsMade += 1
        return context ?? MockAgentContext()
    }

    func agentGroundingPrompt(settings: AppSettings, includeFullDoc: Bool) -> String {
        groundingCalls += 1
        return "host-grounding-prompt"
    }
}
