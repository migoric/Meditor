import Foundation

// MARK: - AgentRunTrace

/// 一次 agent run 的**元数据**轨迹。
///
/// 只记录"做了什么、成没成、多久、多少 token"，**不记录正文**：工具参数与结果里
/// 可能有用户的文档内容，轨迹是拿来排障和做回归比对的，不该变成第二份文档副本。
/// 这条约束由 `make(from:)` 的构造方式保证——它只读 `args`/`result` 的 `count`，
/// 从不把它们存进结构体（有测试钉住）。
///
/// 与 `AgentRunState` 的分工：State 是运行时的 UI 状态（含正文、含 checkpoint），
/// Trace 是可落盘、可跨机器比对的最小信息集。
struct AgentRunTrace: Codable, Equatable {
    /// 结构版本。加字段不必动它，**改语义**（比如把 argsBytes 换成 argsHash）必须 +1，
    /// 否则旧轨迹会被新代码误读成同一含义。
    static let currentSchemaVersion = 1

    var schemaVersion: Int = AgentRunTrace.currentSchemaVersion
    var runID: UUID
    var createdAt: Date
    /// 发起它的会话（便于把多条轨迹串起来看一次任务的全过程）
    var sessionID: UUID?
    var termination: String
    var model: String?
    var durationSeconds: Double?
    var usage: AgentUsage?
    var stepCount: Int
    var toolCalls: [ToolCall]
    /// 停滞诊断摘要（正常结束为 nil）
    var stall: String?
    /// 错误文案**只留首行 + 截断**：堆栈与路径不该进轨迹
    var errorSummary: String?

    struct ToolCall: Codable, Equatable {
        var name: String
        var argsBytes: Int
        var resultBytes: Int
        var isError: Bool
        var durationSeconds: Double?
    }

    // MARK: - Build

    @MainActor
    static func make(
        from state: AgentRunState,
        runID: UUID = UUID(),
        sessionID: UUID? = nil,
        createdAt: Date = Date()
    ) -> AgentRunTrace {
        var calls: [ToolCall] = []
        for step in state.steps {
            guard case .toolCallDone(_, let name, let args, let result, let isError, let duration) = step else {
                continue
            }
            calls.append(ToolCall(
                name: name,
                argsBytes: args.count,
                resultBytes: result.count,
                isError: isError,
                durationSeconds: duration
            ))
        }
        return AgentRunTrace(
            runID: runID,
            createdAt: createdAt,
            sessionID: sessionID,
            termination: state.termination.rawValue,
            model: state.modelName,
            durationSeconds: state.runDurationSeconds,
            usage: state.usage,
            stepCount: state.steps.count,
            toolCalls: calls,
            stall: state.stall.map { "\($0.toolName)×\($0.repeatCount)" },
            errorSummary: summarize(state.error)
        )
    }

    /// 错误留首行、最多 160 字符：足够定位类别，又不至于把路径/片段带出去。
    static func summarize(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let firstLine = error.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? error
        return firstLine.count <= 160 ? firstLine : String(firstLine.prefix(160)) + "…"
    }

    /// 工具序列（回归比对最常看的一列）。
    var toolSequence: [String] { toolCalls.map(\.name) }
}
