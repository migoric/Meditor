import XCTest
@testable import MEditor

/// Agent 工具循环的**金标准**（离线 eval）。
///
/// 这不是单功能测试，而是一张行为账本：每个场景写死「模型说了什么 → 工具按什么顺序
/// 被调用 → 期望的落盘结果」，任何改动让循环语义漂移（顺序变了、拒绝后仍写入、
/// 少记一步）都会在这里红。
///
/// 与其它 agent 测试的分工：`AgentRunnerMultiTurnTests` 问「某个分支对不对」，
/// `AgentWriteReviewTests` 问「审阅态对不对」，这里问「整轮交互还是不是原来那样」——
/// 也就是改 harness 时最先该跑的那张表。
@MainActor
final class AgentEvalGoldenTests: XCTestCase {

    // MARK: - 场景表

    fileprivate struct Reply {
        var text: String = ""
        var call: Call?
        struct Call { let name: String; let args: String }
    }

    private struct Golden {
        let name: String
        let replies: [Reply]
        let approveWrites: Bool
        /// 期望的工具调用顺序（只算执行完的步骤）
        let expectSequence: [String]
        /// 期望真正落盘的写入次数
        let expectWrites: Int
        let expectFinalText: String
    }

    private var ctx: MockAgentContext!
    private var cfg: AIConfig!

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        ctx.currentDocument = "line one\nline two"
        ctx.currentDocumentName = "eval.md"
        cfg = AIConfig(kind: .disabled, baseURL: "", model: "", cliPath: "", cliModel: "",
                       apiKey: "", requestTimeoutSeconds: 30)
    }

    private var toolsToExpose: [any AgentTool] {
        BuiltinAgentTools.all.filter { ["read_document", "write_document"].contains($0.spec.name) }
    }

    // MARK: - 金标准

    func test_goldenScenarios() async {
        let scenarios: [Golden] = [
            Golden(
                name: "读一眼再回答，不动文档",
                replies: [
                    Reply(call: .init(name: "read_document", args: "{}")),
                    Reply(text: "文档只有两行")
                ],
                approveWrites: false,
                expectSequence: ["read_document"],
                expectWrites: 0,
                expectFinalText: "文档只有两行"
            ),
            Golden(
                name: "写入被拒绝 ⇒ 不落盘，但步骤要留痕",
                replies: [
                    Reply(call: .init(name: "read_document", args: "{}")),
                    Reply(call: .init(name: "write_document", args: #"{"content":"rewritten"}"#)),
                    Reply(text: "用户拒绝了这次改写")
                ],
                approveWrites: false,
                expectSequence: ["read_document", "write_document"],
                expectWrites: 0,
                expectFinalText: "用户拒绝了这次改写"
            ),
            Golden(
                name: "写入被接受 ⇒ 恰好落盘一次",
                replies: [
                    Reply(call: .init(name: "read_document", args: "{}")),
                    Reply(call: .init(name: "write_document", args: #"{"content":"rewritten"}"#)),
                    Reply(text: "已改写")
                ],
                approveWrites: true,
                expectSequence: ["read_document", "write_document"],
                expectWrites: 1,
                expectFinalText: "已改写"
            )
        ]

        for scenario in scenarios {
            let runner = AgentRunner(
                maxSteps: 6,
                backendFactory: { [replies = scenario.replies] _ in ScriptedEvalBackend(replies: replies) }
            )
            // 每个场景独立上下文：写入计数不能互相污染
            ctx = MockAgentContext()
            ctx.currentDocument = "line one\nline two"
            ctx.currentDocumentName = "eval.md"
            ctx.writeConfirmResult = scenario.approveWrites

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                runner.onComplete = { cont.resume() }
                runner.run(
                    messages: [AgentMessage(role: .user, content: "改一下")],
                    tools: toolsToExpose,
                    config: cfg,
                    context: ctx
                )
            }

            let sequence = runner.steps.compactMap { step -> String? in
                if case .toolCallDone(_, let name, _, _, _, _) = step { return name }
                return nil
            }
            XCTAssertEqual(sequence, scenario.expectSequence, "工具顺序漂移：\(scenario.name)")
            XCTAssertEqual(ctx.writtenContents.count, scenario.expectWrites, "落盘次数不符：\(scenario.name)")
            XCTAssertEqual(runner.finalText, scenario.expectFinalText, "终态文案不符：\(scenario.name)")
            XCTAssertNil(runner.error, "不该以错误结束：\(scenario.name)")
        }
    }

    /// 步数上限必须真的收住，且以可续跑的 `.failed` 结束（不是 `.completed`）。
    func test_golden_maxStepsTerminatesAsFailed() async {
        let runner = AgentRunner(
            maxSteps: 2,
            backendFactory: { _ in InfiniteEvalBackend(toolName: "read_document") }
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runner.onComplete = { cont.resume() }
            runner.run(messages: [AgentMessage(role: .user, content: "loop")],
                       tools: toolsToExpose, config: cfg, context: ctx)
        }

        XCTAssertNotNil(runner.error)
        XCTAssertEqual(runner.state.termination, .failed, "超步数属于可续跑失败，不是正常完成")
        XCTAssertEqual(ctx.writtenContents.count, 0)
    }
}

// MARK: - Eval backends

/// 按场景脚本依次回放的 backend。与 MultiTurn 的私有 backend 分开：
/// 这个只服务于金标准表，字段刻意少（多了就会变成第二套语义）。
private final class ScriptedEvalBackend: AgentBackend, @unchecked Sendable {
    private let replies: [ScriptedReply]
    private var index = 0
    private let lock = NSLock()

    struct ScriptedReply {
        var text: String
        var name: String?
        var args: String
    }

    init(replies: [AgentEvalGoldenTests.Reply]) {
        self.replies = replies.map { ScriptedReply(text: $0.text, name: $0.call?.name, args: $0.call?.args ?? "{}") }
    }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        let reply = lock.withLock { () -> ScriptedReply in
            let r = index < replies.count ? replies[index] : ScriptedReply(text: "done", name: nil, args: "{}")
            index += 1
            return r
        }
        if let name = reply.name {
            return AgentCompletionResponse(
                text: reply.text,
                toolCalls: [AgentToolCall(id: "eval-\(index)", name: name, argumentsJSON: reply.args)],
                finishReason: "tool_calls"
            )
        }
        return AgentCompletionResponse(text: reply.text, toolCalls: [], finishReason: "stop")
    }
}

private final class InfiniteEvalBackend: AgentBackend, @unchecked Sendable {
    private let toolName: String
    private var count = 0

    init(toolName: String) { self.toolName = toolName }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        count += 1
        return AgentCompletionResponse(
            text: "",
            toolCalls: [AgentToolCall(id: "loop-\(count)", name: toolName, argumentsJSON: "{}")],
            finishReason: "tool_calls"
        )
    }
}
