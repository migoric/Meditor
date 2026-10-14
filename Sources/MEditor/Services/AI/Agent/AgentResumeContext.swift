import Foundation

/// 断点续传的上下文构造（纯函数，便于单测）。
///
/// 策略：继续运行的上下文 = 原始会话历史（system + 原始指令 + 已完成工具调用
/// 及其结果）+ 一条续跑指令。失败中断时 finalMessages 已由 AgentRunner 的
/// reconcileToolResults 补齐配对（未执行的调用带「中断未执行」合成结果），
/// 因此历史本身就是合法请求；模型能从中分辨：哪些步骤已完成（结果已生效，
/// 不要重复执行）、哪些未执行（如仍需则重新调用）。
enum AgentResumeContext {

    /// 续跑指令（追加为新的 user 消息）。不走 L()：这是发给模型的 prompt 而非
    /// UI 文案，固定英文即可（与各后端系统提示同语言，测试断言不依赖 locale）。
    ///
    /// 措辞纪律：对「已生效」只做**条件式**陈述（以工具结果为准），不断言。
    /// 工具返回成功 ≠ 盘上一定写成功（如协调写被外部进程拒绝、沙盒策略变更），
    /// 让模型把结果当唯一事实来源，比替它下断言更不容易在边缘场景说假话。
    static let resumeInstruction = """
    The previous run was interrupted before completion (network/timeout error). \
    The conversation above is the full execution record up to the interruption:
    - Tool calls that already have results are DONE — do NOT repeat them. The result \
    is the source of truth for what took effect: if a result reports success, treat \
    the write as in place; if it reports an error, re-issue that call.
    - Tool calls whose results say the run was interrupted did NOT execute — \
    re-issue them if they are still needed.
    Continue the original task from where it stopped and finish the remaining work.
    """

    /// 构造续跑消息列表：历史 + 刷新后的 system prompt + 续跑指令。
    /// - Parameter history: 上次 run 保存的 agentHistory（含已完成工具调用结果）。
    /// - Parameter freshSystemPrompt: 重建的 system prompt（文档/选区快照已过期，
    ///   用当前状态刷新，历史里的旧 system 被替换而非保留）。
    /// - Returns: nil 表示没有可续跑的历史（首轮即失败且无任何记录），
    ///   调用方不应提供续跑入口。
    static func makeMessages(history: [AgentMessage], freshSystemPrompt: String) -> [AgentMessage]? {
        guard !history.isEmpty else { return nil }
        var messages = history
        if messages.first?.role == .system {
            messages[0] = AgentMessage(role: .system, content: freshSystemPrompt)
        } else {
            messages.insert(AgentMessage(role: .system, content: freshSystemPrompt), at: 0)
        }
        messages.append(AgentMessage(role: .user, content: resumeInstruction))
        return messages
    }
}
