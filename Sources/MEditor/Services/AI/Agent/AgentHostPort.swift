#if os(macOS)
import Foundation

// MARK: - AgentHostPort

/// Service 层（后台 agent 任务 / 定时调度）对宿主（AppState）的**能力端口**。
///
/// 为什么存在（P0-10）：`BackgroundAgentTaskService` / `AgentSchedulerService` 原先各自
/// 持有 `weak var appState: AppState?`，于是 Service 层直接命名了 ViewModel 类型——
/// 依赖方向双向化，且「Service 能对宿主做什么」没有边界：每多一处调用就多一条隐式依赖，
/// 单测只能传 `nil`（旧 `appState: nil` 用法）把整条反馈路径静默吞掉，既测不到也留不下痕迹。
///
/// 端口成员 = 这两个服务的**真实最小需求集**，不预留提前量。新增需求必须先扩协议，
/// 端口因此同时充当白名单：Service 越界在编译期被拦住，而不是在评审时被发现。
///
/// 与 `AgentDocumentAdapter` 的分工：文档读写 / 写前审阅 / 命令确认走那条端口
/// （它已经是 AppState 与工具层之间的适配器，且已被 `AgentContext` 组合）；本端口只管
/// run 的生命周期反馈。唯一的重叠点是 `makeAgentContext`——它把 AppState 侧的组合根
/// （`AgentContext.make`）也收进端口，这样两个 Service 连 `AgentContext.make` 都不必自己调。
///
/// 实现见文件末尾 `extension AppState: AgentHostPort`——AppState 是唯一的装配点，
/// 此处出现 `AppState` 是设计意图（适配器层），不是 Service 层的反向依赖。
@MainActor
protocol AgentHostPort: AnyObject {

    // MARK: - 用户可见反馈

    /// 瞬时反馈条：后台任务的并发上限 / 完成 / 失败 / 取消，
    /// 定时任务的「AI 未配置」与「配置写回失败」。
    func showToast(_ text: String, icon: String?)

    // MARK: - 宿主上下文

    /// 当前工作区根：MCP 懒连接与定时配置加载的工作区来源。
    var rootURL: URL? { get }

    /// 本 run 要追加的 MCP 工具（懒连接有配置的 server；连接失败降级为跳过）。
    /// 端口给的是**工具**而不是 `MCPClientManager`：service 只消费结果，不操作 MCP
    /// 生命周期。收窄的直接收益是测试可完全隔离——假宿主返回 `[]` 即可，
    /// 不必构造真管理器、也就不会读真实 `mcp.json`（旧实现读 manager 会顺带触发配置 IO）。
    func mcpToolsForRun(workspaceURL: URL?) async -> [any AgentTool]

    /// 后台任务管理器：定时任务命中后复用同一发起链路
    /// （并发上限、完成通知、写确认 / 审阅链路全部沿用）。
    var backgroundAgentTasks: BackgroundAgentTaskService { get }

    // MARK: - 组合根

    /// 创建一次 run 的标准 AgentContext（写确认 / diff 审阅链路与聊天 run 完全一致）。
    /// 收进端口的理由：Service 不必自己命名 AppState 去调 `AgentContext.make`。
    func makeAgentContext(checkpoint: AgentRunCheckpoint) -> any AgentContextProtocol

    /// 为后台 / 定时 run 生成 agent system prompt：复用聊天运行的 grounding
    /// （工作区路径 / 预览主题 / 用户自定义技能），不另写一套。
    func agentGroundingPrompt(settings: AppSettings, includeFullDoc: Bool) -> String
}

// MARK: - AppState 装配

/// 宿主对端口的唯一实现。两个方法都是**转发**，不含业务逻辑——
/// 逻辑仍在 `AgentContext.make` / `AIChatCoordinator.systemContext` 里，此处只做接线。
extension AppState: AgentHostPort {

    func mcpToolsForRun(workspaceURL: URL?) async -> [any AgentTool] {
        await mcpClientManager.refreshForAgentRun(workspaceURL: workspaceURL)
    }

    func makeAgentContext(checkpoint: AgentRunCheckpoint) -> any AgentContextProtocol {
        AgentContext.make(appState: self, checkpoint: checkpoint)
    }

    func agentGroundingPrompt(settings: AppSettings, includeFullDoc: Bool) -> String {
        AIChatCoordinator(settings: settings, conversation: aiConversation, appState: self)
            .systemContext(includeFullDoc: includeFullDoc)
    }
}
#endif
