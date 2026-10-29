import XCTest
@testable import MEditor

// MARK: - AgentRunnerMultiTurnTests
//
// 覆盖 AgentRunner 的多轮工具调用、错误恢复、步数限制和超时等核心流程。

@MainActor
final class AgentRunnerMultiTurnTests: XCTestCase {

    private var ctx: MockAgentContext!
    private var cfg: AIConfig!

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        ctx.currentDocument     = "Initial document content"
        ctx.currentDocumentName = "test.md"
        cfg = AIConfig(
            kind: .disabled, baseURL: "", model: "", cliPath: "", cliModel: "", apiKey: "",
            requestTimeoutSeconds: 60
        )
    }

    // MARK: - Single Turn（无工具调用）

    func test_singleTurn_noTools_returnsFinalText() async {
        let runner = makeRunner(maxSteps: 5, responses: [
            .text("Hello from AI")
        ])
        await runAndWait(runner)

        XCTAssertEqual(runner.finalText, "Hello from AI")
        XCTAssertNil(runner.error)
        XCTAssertFalse(runner.isRunning)
    }

    // MARK: - 单次工具调用 → 工具结果 → 最终文本

    func test_singleToolCall_executesToolAndReturnsText() async throws {
        let spy = SpyTool(name: "read_document", result: "Document content: hello world")

        let runner = makeRunner(maxSteps: 5, responses: [
            .toolCall(id: "tc1", name: "read_document", args: "{}"),
            .text("I read: hello world")
        ])

        await runAndWait(runner, tools: [spy])

        XCTAssertTrue(spy.wasCalled, "工具应被调用一次")
        XCTAssertEqual(runner.finalText, "I read: hello world")
        // 应有两个 step：toolCall + toolCallDone
        let doneSteps = runner.steps.filter(\.isDone)
        XCTAssertEqual(doneSteps.count, 1)
    }

    // MARK: - 多次连续工具调用

    func test_multipleToolCalls_sequentialExecution() async {
        let readSpy  = SpyTool(name: "read_document",  result: "Doc: abc")
        let writeSpy = SpyTool(name: "write_document", result: "[OK] Written")

        let runner = makeRunner(maxSteps: 10, responses: [
            .toolCall(id: "tc1", name: "read_document",  args: "{}"),
            .toolCall(id: "tc2", name: "write_document", args: "{\"content\":\"new\"}"),
            .text("Done: read and wrote")
        ])

        await runAndWait(runner, tools: [readSpy, writeSpy])

        XCTAssertTrue(readSpy.wasCalled,  "read_document 应被调用")
        XCTAssertTrue(writeSpy.wasCalled, "write_document 应被调用")
        XCTAssertEqual(runner.finalText, "Done: read and wrote")

        let doneSteps = runner.steps.filter(\.isDone)
        XCTAssertEqual(doneSteps.count, 2, "应有两个已完成的工具步骤")
    }

    // MARK: - 工具调用失败（工具抛出错误）

    func test_toolThrowsError_marksStepAsError_continues() async {
        let failTool = FailingTool(name: "patch_document", error: AgentError.executionError("找不到目标文本"))

        let runner = makeRunner(maxSteps: 5, responses: [
            .toolCall(id: "tc1", name: "patch_document", args: "{\"find\":\"x\",\"replace\":\"y\"}"),
            .text("patch failed but I recovered")
        ])

        await runAndWait(runner, tools: [failTool])

        // Runner 应继续运行，不崩溃
        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(runner.error, "工具错误不应导致 runner 整体失败")
        XCTAssertEqual(runner.finalText, "patch failed but I recovered")

        // 错误步骤应被标记
        let errorSteps = runner.steps.filter(\.isError)
        XCTAssertEqual(errorSteps.count, 1, "应有一个错误标记的工具步骤")
    }

    // MARK: - _parse_error 特殊工具（JSON 解析失败）

    func test_parseErrorTool_recoversAndContinues() async {
        let runner = makeRunner(maxSteps: 5, responses: [
            .toolCallRaw(id: "e1", name: "_parse_error",
                         args: "{\"original_tool\":\"patch_document\",\"raw_arguments\":\"bad json\"}"),
            .text("Recovered from parse error")
        ])

        await runAndWait(runner)

        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.finalText, "Recovered from parse error")
    }

    // MARK: - 未知工具名（graceful fallback）

    func test_unknownToolName_returnsError_doesNotCrash() async {
        let runner = makeRunner(maxSteps: 5, responses: [
            .toolCall(id: "tc1", name: "nonexistent_tool", args: "{}"),
            .text("Handled unknown tool")
        ])

        await runAndWait(runner, tools: [])

        XCTAssertFalse(runner.isRunning)
        // Runner 应返回最终文本，不崩溃
        XCTAssertEqual(runner.finalText, "Handled unknown tool")
    }

    // MARK: - maxSteps 超限

    func test_maxSteps_exceeded_setsError() async {
        // 无限返回 toolCall，永远不给 stop
        let infiniteTool = SpyTool(name: "read_document", result: "still reading")
        let infiniteBackend = InfiniteToolCallBackend(toolName: "read_document")

        let runner = AgentRunner(
            maxSteps: 3,
            backendFactory: { _ in infiniteBackend }
        )

        await runAndWait(runner, tools: [infiniteTool])

        XCTAssertFalse(runner.isRunning)
        XCTAssertNotNil(runner.error, "超过最大步数应设置 error")
        XCTAssertTrue(runner.error?.contains("步数") == true || runner.error?.contains("step") == true,
                      "错误消息应提示步数超限")
    }

    // MARK: - 取消

    func test_cancel_setsErrorAndStopsRunning() async {
        let slowBackend = SlowBackend(delay: 5.0, response: .text("Too late"))
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in slowBackend })
        runner.run(messages: [AgentMessage(role: .user, content: "Hi")],
                   tools: [], config: cfg, context: ctx)

        // 短暂等待后取消
        try? await Task.sleep(for: .milliseconds(50))
        runner.cancel()

        // 等待 runner 停止
        let deadline = Date().addingTimeInterval(2)
        while runner.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runner.isRunning)
        XCTAssertNotNil(runner.error, "取消后 error 应非 nil")
    }

    // MARK: - Timeout

    func test_timeout_setsTimeoutError() async {
        let slowBackend = SlowBackend(delay: 10.0, response: .text("Never arrives"))
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in slowBackend })
        runner.timeoutSeconds = 0.3   // 300ms 超时

        await runAndWait(runner, timeout: 5.0)

        XCTAssertFalse(runner.isRunning)
        XCTAssertNotNil(runner.error, "超时后应设置 error")
        XCTAssertTrue(runner.error?.contains("超时") == true || runner.error?.contains("timeout") == true,
                      "错误消息应提示超时")
    }

    // MARK: - onChunk / 流式输出

    func test_onChunk_calledDuringStreaming() async {
        var chunks: [String] = []
        let runner = makeRunner(maxSteps: 5, responses: [.text("final text")])
        runner.onChunk = { chunk in chunks.append(chunk) }

        await runAndWait(runner)

        // SequentialBackend 走 completeStreaming 的默认回退实现，onTextChunk 不被调用，
        // 但 runner 在拿到最终回复时会用 onChunk 推一次全文——这里断言确实推送过，
        // 而不是只断言 finalText（否则测试名与验证内容不符）。
        XCTAssertFalse(chunks.isEmpty, "run 结束前应至少推送一次累积文本")
        XCTAssertEqual(chunks.last, "final text")
        XCTAssertEqual(runner.finalText, "final text")
    }

    func test_streaming_chunksAccumulateCorrectly() async {
        // 流式 backend：每次 completeStreaming 分 3 次回调 onTextChunk，最终返回完整文本
        let streamingBackend = ChunkingBackend(chunks: ["Hello", " ", "World"], finalText: "Hello World")
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in streamingBackend })

        var receivedChunks: [String] = []
        runner.onChunk = { chunk in receivedChunks.append(chunk) }

        await runAndWait(runner)

        // 最终文本正确
        XCTAssertEqual(runner.finalText, "Hello World")
        // onChunk 至少被调用了（包括 chunk 和最终 finalText 回调）
        XCTAssertFalse(receivedChunks.isEmpty, "onChunk 应被调用")
        // 最后一次 onChunk 是完整文本
        XCTAssertEqual(receivedChunks.last, "Hello World")
    }

    func test_streaming_toolCallRound_chunkIgnored_finalTextCorrect() async {
        // 工具调用轮次的 chunk 被忽略，最终文本轮次的 chunk 正确输出
        let spy = SpyTool(name: "read_document", result: "doc content")
        let streamingBackend = ChunkingBackend(
            toolCallName: "read_document",
            finalChunks: ["Done", "!"],
            finalText: "Done!"
        )
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in streamingBackend })

        var receivedChunks: [String] = []
        runner.onChunk = { chunk in receivedChunks.append(chunk) }

        await runAndWait(runner, tools: [spy])

        XCTAssertTrue(spy.wasCalled)
        XCTAssertEqual(runner.finalText, "Done!")
        XCTAssertEqual(receivedChunks.last, "Done!")
    }

    // MARK: - 工具调用后继续多轮

    func test_threeRound_toolCallChain() async {
        let spyA = SpyTool(name: "list_files",   result: "[\"a.md\",\"b.md\"]")
        let spyB = SpyTool(name: "read_document", result: "content of a.md")
        let spyC = SpyTool(name: "write_document", result: "[OK]")

        let runner = makeRunner(maxSteps: 15, responses: [
            .toolCall(id: "1", name: "list_files",    args: "{}"),
            .toolCall(id: "2", name: "read_document", args: "{\"filename\":\"a.md\"}"),
            .toolCall(id: "3", name: "write_document", args: "{\"content\":\"updated\"}"),
            .text("All done in 3 steps")
        ])

        await runAndWait(runner, tools: [spyA, spyB, spyC])

        XCTAssertTrue(spyA.wasCalled)
        XCTAssertTrue(spyB.wasCalled)
        XCTAssertTrue(spyC.wasCalled)
        XCTAssertEqual(runner.finalText, "All done in 3 steps")
        XCTAssertEqual(runner.steps.filter(\.isDone).count, 3)
    }

    // MARK: - 只读工具并行执行

    /// 一轮返回 3 个只读调用：全部执行、结果按 response.toolCalls 原顺序回灌、确实并行
    func test_parallelReadOnlyCalls_allExecute_resultsFedBackInOriginalOrder() async {
        let log = ToolExecutionLog()
        let tools: [any AgentTool] = [
            RecordingTool(name: "list_files",       delay: 0.3, log: log),
            RecordingTool(name: "read_file",        delay: 0.3, log: log),
            RecordingTool(name: "search_workspace", delay: 0.3, log: log),
        ]
        let runner = makeRunner(maxSteps: 5, responses: [
            .multiToolCalls(calls: [
                (id: "tc1", name: "list_files",       args: "{}"),
                (id: "tc2", name: "read_file",        args: "{\"filename\":\"a.md\"}"),
                (id: "tc3", name: "search_workspace", args: "{\"query\":\"x\"}"),
            ]),
            .text("done")
        ])

        await runAndWait(runner, tools: tools)

        XCTAssertEqual(runner.finalText, "done")
        XCTAssertEqual(runner.steps.filter(\.isDone).count, 3, "三个只读调用都应完成")
        // 回灌顺序必须与 response.toolCalls 原顺序一致（配对合法性）
        let toolMessages = runner.finalMessages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.map(\.toolCallID), ["tc1", "tc2", "tc3"])
        // 确实并行：三个 300ms 调用串行需 ≥900ms，并行时执行窗口应重叠
        XCTAssertTrue(log.overlapped("list_files", "read_file"), "只读调用应并行执行")
        XCTAssertTrue(log.overlapped("read_file", "search_workspace"), "只读调用应并行执行")
    }

    /// 读写混合（响应顺序：写在前）：必须先写再读，回灌仍按原顺序
    func test_readWriteMixed_preservesResponseOrder_feedbackInOriginalOrder() async {
        let log = ToolExecutionLog()
        let tools: [any AgentTool] = [
            RecordingTool(name: "write_document", log: log),
            RecordingTool(name: "read_document",  log: log),
            RecordingTool(name: "read_file",      log: log),
        ]
        let runner = makeRunner(maxSteps: 5, responses: [
            .multiToolCalls(calls: [
                (id: "w1", name: "write_document", args: "{\"content\":\"x\"}"),
                (id: "r1", name: "read_document",  args: "{}"),
                (id: "r2", name: "read_file",      args: "{\"filename\":\"a.md\"}"),
            ]),
            .text("done")
        ])

        await runAndWait(runner, tools: tools)

        // 执行顺序：写必须先完成，后续两个只读调用才可并行启动
        XCTAssertEqual(log.startOrder.first, "write_document", "写调用不得被后续只读调用抢跑")
        XCTAssertEqual(Set(log.startOrder.suffix(2)), ["read_document", "read_file"],
                       "写后连续只读调用仍应组成并行批")
        // 回灌顺序：按 response.toolCalls 原顺序
        let toolMessages = runner.finalMessages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.map(\.toolCallID), ["w1", "r1", "r2"])
        XCTAssertEqual(runner.finalText, "done")
    }

    /// 并行只读批执行期间取消：已启动的工具正常收尾，tool_calls 配对由 reconcile 兜底
    func test_cancelDuringParallelRead_finishesCleanly_resultsReconciled() async {
        let log = ToolExecutionLog()
        let tools: [any AgentTool] = [
            RecordingTool(name: "list_files", delay: 5.0, log: log),
            RecordingTool(name: "read_file",  delay: 5.0, log: log),
        ]
        let runner = makeRunner(maxSteps: 5, responses: [
            .multiToolCalls(calls: [
                (id: "tc1", name: "list_files", args: "{}"),
                (id: "tc2", name: "read_file",  args: "{\"filename\":\"a.md\"}"),
            ]),
            .text("不应到达")
        ])

        var completed = false
        runner.onComplete = { completed = true }
        runner.run(messages: [AgentMessage(role: .user, content: "test")],
                   tools: tools, config: cfg, context: ctx)
        try? await Task.sleep(for: .milliseconds(150))
        runner.cancel()

        let deadline = Date().addingTimeInterval(3)
        while !completed && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(completed, "取消后 run 应收尾并触发 onComplete")
        XCTAssertFalse(runner.isRunning)
        XCTAssertNotNil(runner.error)
        // 每个 assistant toolCall 都有对应 tool result（执行结果或 reconcile 合成）
        let calls = runner.finalMessages.flatMap { $0.toolCalls ?? [] }
        let answered = Set(runner.finalMessages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { answered.contains($0.id) }, "tool_calls 与 tool result 应严格配对")
        // 取消传播给了已启动的并行工具（5s 睡眠被立即打断，收尾远早于 5s）
        XCTAssertTrue(Date() < deadline, "取消应及时打断并行工具")
    }

    // MARK: - token 用量累计

    /// 各 step 响应的 usage 累计到 state.usage；run 结束写入总耗时
    func test_usage_accumulatesAcrossSteps() async {
        let spy = SpyTool(name: "read_document", result: "content")
        let runner = makeRunner(maxSteps: 5, responses: [
            .toolCallWithUsage(id: "tc1", name: "read_document", args: "{}",
                               usage: AgentUsage(promptTokens: 100, completionTokens: 10)),
            .textWithUsage("done", AgentUsage(promptTokens: 50, completionTokens: 20))
        ])

        await runAndWait(runner, tools: [spy])

        XCTAssertEqual(runner.state.usage, AgentUsage(promptTokens: 150, completionTokens: 30))
        XCTAssertNotNil(runner.state.runDurationSeconds, "run 收尾应写入总耗时")
    }

    /// 后端不返回 usage：state.usage 保持 nil（UI 降级不显示），run 正常完成
    func test_noUsage_stateUsageNil_runUnaffected() async {
        let runner = makeRunner(maxSteps: 5, responses: [.text("plain")])
        await runAndWait(runner)

        XCTAssertEqual(runner.finalText, "plain")
        XCTAssertNil(runner.state.usage)
        XCTAssertNil(runner.error)
    }

    // MARK: - Helpers

    private func makeRunner(maxSteps: Int, responses: [MockResponse]) -> AgentRunner {
        AgentRunner(
            maxSteps: maxSteps,
            backendFactory: { _ in SequentialBackend(responses: responses) }
        )
    }

    private func runAndWait(_ runner: AgentRunner, tools: [any AgentTool] = [], timeout: TimeInterval = 10.0) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runner.onComplete = { cont.resume() }
            runner.run(
                messages: [AgentMessage(role: .user, content: "test")],
                tools: tools,
                config: cfg,
                context: ctx
            )
        }
    }
}

// MARK: - Mock Responses

private enum MockResponse {
    case text(String)
    case toolCall(id: String, name: String, args: String)
    case toolCallRaw(id: String, name: String, args: String)  // same as toolCall for now
    /// 单轮响应内携带多个 tool call（验证并行只读执行与回灌顺序）
    case multiToolCalls(calls: [(id: String, name: String, args: String)])
    /// 带 token 用量的响应（验证 usage 累计）
    case toolCallWithUsage(id: String, name: String, args: String, usage: AgentUsage)
    case textWithUsage(String, AgentUsage)

    var asCompletion: AgentCompletionResponse {
        switch self {
        case .text(let t):
            return AgentCompletionResponse(text: t, toolCalls: [], finishReason: "stop")
        case .toolCall(let id, let name, let args), .toolCallRaw(let id, let name, let args):
            return AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: name, argumentsJSON: args)],
                finishReason: "tool_calls"
            )
        case .multiToolCalls(let calls):
            return AgentCompletionResponse(
                text: "",
                toolCalls: calls.map { AgentToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.args) },
                finishReason: "tool_calls"
            )
        case .toolCallWithUsage(let id, let name, let args, let usage):
            return AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: name, argumentsJSON: args)],
                finishReason: "tool_calls",
                usage: usage
            )
        case .textWithUsage(let t, let usage):
            return AgentCompletionResponse(text: t, toolCalls: [], finishReason: "stop", usage: usage)
        }
    }
}

// MARK: - Test Backends

/// 按顺序返回预设响应的测试 backend。
private final class SequentialBackend: AgentBackend, @unchecked Sendable {
    private let responses: [MockResponse]
    private var index = 0
    private let lock  = NSLock()

    init(responses: [MockResponse]) { self.responses = responses }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        let resp = lock.withLock { () -> MockResponse in
            let r = index < responses.count ? responses[index] : MockResponse.text("done")
            index += 1
            return r
        }
        return resp.asCompletion
    }
}

/// 无限返回同一个工具调用（用于测试 maxSteps）。
private final class InfiniteToolCallBackend: AgentBackend, @unchecked Sendable {
    private let toolName: String
    private var callCount = 0

    init(toolName: String) { self.toolName = toolName }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        callCount += 1
        return AgentCompletionResponse(
            text: "",
            toolCalls: [AgentToolCall(id: "tc\(callCount)", name: toolName, argumentsJSON: "{}")],
            finishReason: "tool_calls"
        )
    }
}

/// 慢速 backend，模拟网络延迟（用于测试超时 / 取消）。
private final class SlowBackend: AgentBackend, @unchecked Sendable {
    private let delay: TimeInterval
    private let response: MockResponse

    init(delay: TimeInterval, response: MockResponse) {
        self.delay    = delay
        self.response = response
    }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        try await Task.sleep(for: .seconds(delay))
        return response.asCompletion
    }
}

// MARK: - Test Tools

/// 记录是否被调用，返回固定结果的 spy 工具。
private final class SpyTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let result: String
    private(set) var wasCalled = false
    private(set) var lastArguments: [String: AnySendableValue] = [:]

    init(name: String, result: String) {
        self.spec   = AgentToolSpec(name: name, description: "Spy tool: \(name)")
        self.result = result
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        wasCalled = true
        lastArguments = arguments
        return result
    }
}

/// 流式 Backend：分 chunk 回调 onTextChunk，支持纯文本和单次工具调用两种模式。
private final class ChunkingBackend: AgentBackend, @unchecked Sendable {
    private enum Mode {
        case textOnly(chunks: [String], finalText: String)
        case oneToolCall(name: String, finalChunks: [String], finalText: String)
    }
    private let mode: Mode
    private var callCount = 0
    private let lock = NSLock()

    /// 纯文本流式模式
    init(chunks: [String], finalText: String) {
        self.mode = .textOnly(chunks: chunks, finalText: finalText)
    }

    /// 工具调用 + 最终文本流式模式
    init(toolCallName: String, finalChunks: [String], finalText: String) {
        self.mode = .oneToolCall(name: toolCallName, finalChunks: finalChunks, finalText: finalText)
    }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        try await completeStreaming(messages: messages, tools: tools, onTextChunk: { _ in })
    }

    func completeStreaming(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        let call = lock.withLock { () -> Int in
            let c = callCount
            callCount += 1
            return c
        }

        switch mode {
        case .textOnly(let chunks, let finalText):
            for chunk in chunks { onTextChunk(chunk) }
            return AgentCompletionResponse(text: finalText, toolCalls: [], finishReason: "stop")

        case .oneToolCall(let toolName, let finalChunks, let finalText):
            if call == 0 {
                // 第一轮：返回工具调用，chunk 被 Runner 忽略
                return AgentCompletionResponse(
                    text: "",
                    toolCalls: [AgentToolCall(id: "tc1", name: toolName, argumentsJSON: "{}")],
                    finishReason: "tool_calls"
                )
            } else {
                // 第二轮：流式输出最终文本
                for chunk in finalChunks { onTextChunk(chunk) }
                return AgentCompletionResponse(text: finalText, toolCalls: [], finishReason: "stop")
            }
        }
    }
}

/// 总是抛出错误的工具（测试错误恢复）。
private struct FailingTool: AgentTool, Sendable {
    let spec: AgentToolSpec
    let error: Error

    init(name: String, error: Error) {
        self.spec  = AgentToolSpec(name: name, description: "Failing tool: \(name)")
        self.error = error
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        throw error
    }
}

/// 线程安全的工具执行时间线（验证并行度与读写执行顺序）。
private final class ToolExecutionLog: @unchecked Sendable {
    /// 工具进入 execute 的顺序
    private(set) var startOrder: [String] = []
    private(set) var starts: [String: Date] = [:]
    private(set) var ends: [String: Date] = [:]
    private let lock = NSLock()

    func recordStart(_ name: String) {
        lock.lock(); startOrder.append(name); starts[name] = Date(); lock.unlock()
    }
    func recordEnd(_ name: String) {
        lock.lock(); ends[name] = Date(); lock.unlock()
    }
    /// 两个工具的执行时间窗口是否重叠（重叠 = 确实并行执行过）
    func overlapped(_ a: String, _ b: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let sa = starts[a], let ea = ends[a], let sb = starts[b], let eb = ends[b] else { return false }
        return sa < eb && sb < ea
    }
}

/// 记录执行时间线、可带延迟的工具（验证只读并行与读写顺序）。
private final class RecordingTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let delay: TimeInterval
    private let log: ToolExecutionLog

    init(name: String, delay: TimeInterval = 0, log: ToolExecutionLog) {
        self.spec  = AgentToolSpec(name: name, description: "Recording tool: \(name)")
        self.delay = delay
        self.log   = log
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        log.recordStart(spec.name)
        defer { log.recordEnd(spec.name) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return "ok-\(spec.name)"
    }
}
