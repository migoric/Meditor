import XCTest
@testable import MEditor

// MARK: - AgentRunnerStabilityTests
//
// Agent 稳定性回归测试（eval 集）—— AgentRunner run loop：
//   B7  最终答案恰好在第 maxSteps 轮返回 → 不报步数超限（off-by-one 回归）
//   B8  工具执行中被 cancel 中断 → reconcileToolResults 保证 tool_calls 配对
//   B9  后端返回非法参数 JSON → 不执行工具、回灌「解析失败」tool result
//   B10 classifyError 文案：401→鉴权 / 429→频繁或额度 / URLError.timedOut→超时
//   B11 cancel 后旧 run 收尾不得覆盖新 run（generation 防护）
//   B12 停滞检测：相同 (工具, 参数) 连续失败 3 次 → 中断 run，不再发第 4 次请求
//   B13 工具耗时记录：真实执行分支写入 durationSeconds，短路分支为 nil
//   B16 停滞检测（规则 2）：换参反复失败 4 步 → 中断
//   B17 停滞检测（规则 3）：调用成功但结果重复、连续零进展 → 中断
//   B18 规则 3 不误杀：重复被新结果打断 → 不判定停滞
//   B19 超时与步数预算联动：30 步仍是 300s，100 步跟着放大到 1000s
//
// mock 模式沿用 AgentRunnerMultiTurnTests（其 mock 为 private，这里自带等价实现）。

@MainActor
final class AgentRunnerStabilityTests: XCTestCase {

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

    // MARK: - B7 maxSteps off-by-one：第 maxSteps 轮拿到 finalText 不算超限

    func test_finalAnswerExactlyAtMaxSteps_noStepLimitError() async {
        let spy = RunnerSpyTool(name: "read_document", result: "doc")
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "read_document", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "最终答案", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 2, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [spy])

        XCTAssertTrue(spy.wasCalled)
        XCTAssertEqual(runner.finalText, "最终答案")
        XCTAssertNil(runner.error, "最终答案恰好在第 maxSteps 轮返回时不应误报步数超限")
    }

    // MARK: - B8 工具执行中被 cancel → 未应答的 tool call 补合成中断结果

    func test_cancelledDuringToolExecution_toolResultsReconciled() async {
        let backend = ScriptedBackend(script: [
            // 第一轮：一次返回两个 tool call；第一个工具在执行时 cancel 整个 runner。
            // 注意：tc2 用写工具（write_document）——只读工具在新并行策略下会先执行，
            // 「取消后不再执行后续工具」的语义只约束串行组（写工具/短路分支）。
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [
                    AgentToolCall(id: "tc1", name: "cancel_tool", argumentsJSON: "{}"),
                    AgentToolCall(id: "tc2", name: "write_document", argumentsJSON: "{}"),
                ],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })
        let cancelTool = SelfCancellingTool(name: "cancel_tool") { [weak runner] in
            runner?.cancel()
        }
        let spy = RunnerSpyTool(name: "write_document", result: "doc")

        await runAndWait(runner, tools: [cancelTool, spy])

        // tc2 不应被执行（循环在 tc1 之后检测到取消）
        XCTAssertFalse(spy.wasCalled, "取消后不应继续执行后续工具")

        // finalMessages 中每个 assistant tool_call 都必须有配对的 tool result
        let allCalls = runner.finalMessages.flatMap { $0.toolCalls ?? [] }
        XCTAssertEqual(Set(allCalls.map(\.id)), ["tc1", "tc2"])
        let answered = Set(runner.finalMessages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        for call in allCalls {
            XCTAssertTrue(answered.contains(call.id), "tool_call \(call.id) 必须有配对 tool result")
        }

        // tc2 的配对结果应是合成的「中断」结果
        let synthetic = runner.finalMessages.first { $0.role == .tool && $0.toolCallID == "tc2" }
        XCTAssertTrue(synthetic?.content.contains("中断") == true,
                      "未执行的工具调用应补合成含「中断」字样的错误结果，实际：\(synthetic?.content ?? "nil")")
    }

    // MARK: - B14 工具抛 CancellationError → rethrow 走向收尾，不包装成 tool error

    func test_toolThrowingCancellationError_notWrappedAsToolError() async {
        // 取消信号若被无差别包装成 AgentToolResult(isError: true)，会变成一条误导性
        // tool error 回灌历史并计入停滞指纹。应 rethrow：run 走向收尾，未应答的
        // tool call 由 reconcileToolResults 补合成「中断」结果。
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "write_document", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })
        let tool = ThrowingTool(name: "write_document", error: CancellationError())

        await runAndWait(runner, tools: [tool])

        XCTAssertNil(runner.error, "取消不应被归类为 run 错误，实际：\(runner.error ?? "nil")")
        XCTAssertEqual(backend.receivedMessages.count, 1, "取消后不应再发第二次后端请求")
        let feedback = runner.finalMessages.first { $0.role == .tool && $0.toolCallID == "tc1" }
        XCTAssertTrue(feedback?.content.contains("中断") == true,
                      "未应答的 tool call 应补合成中断结果，实际：\(feedback?.content ?? "nil")")
    }

    func test_toolThrowingWrappedCancellationError_notWrappedAsToolError() async {
        // 底层 cause 是 CancellationError 的包装错误（工具内部重新封装子任务错误）同样处理
        let wrapped = NSError(domain: "ToolWrap", code: 1,
                              userInfo: [NSUnderlyingErrorKey: CancellationError()])
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "write_document", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })
        let tool = ThrowingTool(name: "write_document", error: wrapped)

        await runAndWait(runner, tools: [tool])

        XCTAssertNil(runner.error, "包装后的取消也不应被归类为 run 错误，实际：\(runner.error ?? "nil")")
        XCTAssertEqual(backend.receivedMessages.count, 1)
        let feedback = runner.finalMessages.first { $0.role == .tool && $0.toolCallID == "tc1" }
        XCTAssertTrue(feedback?.content.contains("中断") == true,
                      "应补合成中断结果而非 tool error，实际：\(feedback?.content ?? "nil")")
    }

    // MARK: - B9 非法参数 JSON → 短路：不执行工具、回灌解析失败

    func test_invalidArgumentsJSON_toolSkipped_parseErrorFedBack() async {
        let spy = RunnerSpyTool(name: "patch_document", result: "patched")
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "bad1", name: "patch_document", argumentsJSON: "{not valid json")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "已重新生成参数", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [spy])

        XCTAssertFalse(spy.wasCalled, "参数 JSON 非法时工具闭包不应被调用")
        XCTAssertEqual(runner.finalText, "已重新生成参数")

        // 回灌的 tool result 含「解析失败」
        let feedback = runner.finalMessages.first { $0.role == .tool && $0.toolCallID == "bad1" }
        XCTAssertTrue(feedback?.content.contains("解析失败") == true,
                      "回灌的 tool result 应含「解析失败」，实际：\(feedback?.content ?? "nil")")

        // 第二轮请求应携带该错误 tool result（模型据此恢复）
        XCTAssertGreaterThanOrEqual(backend.receivedMessages.count, 2)
        let secondRound = backend.receivedMessages[1]
        XCTAssertTrue(secondRound.contains {
            $0.role == .tool && $0.toolCallID == "bad1" && $0.content.contains("解析失败")
        }, "第二轮发给后端的 messages 应包含解析失败的 tool result")
    }

    // MARK: - B9 附带：AgentToolCall 模型行为钉死（解析失败保留原文）

    func test_toolCallInit_invalidJSON_setsParseErrorAndKeepsRaw() {
        let raw = "{not valid json"
        let call = AgentToolCall(id: "x", name: "t", argumentsJSON: raw)
        XCTAssertNotNil(call.argumentsParseError)
        XCTAssertEqual(call.rawArgumentsJSON, raw, "rawArgumentsJSON 必须保留原始非法文本")
        XCTAssertTrue(call.arguments.isEmpty)

        // 回归：JSONSerialization 的 NSNumber 桥接下，整数 0/1 过去会被误判为 Bool，
        // 导致 read_document 的 start_line:1 拿不到 intValue → 读全文。
        // 现在用 CFBoolean 类型判定，0/1 保持为 .int，true/false 才是 .bool。
        let good = AgentToolCall(id: "y", name: "t",
                                 argumentsJSON: #"{"a":"ok","n":42,"start_line":1,"zero":0,"flag":true}"#)
        XCTAssertNil(good.argumentsParseError)
        XCTAssertEqual(good.arguments["a"], .string("ok"))
        XCTAssertEqual(good.arguments["n"], .int(42))
        XCTAssertEqual(good.arguments["start_line"], .int(1))
        XCTAssertEqual(good.arguments["zero"], .int(0))
        XCTAssertEqual(good.arguments["flag"], .bool(true))
    }

    // MARK: - B10 classifyError 文案（private，经 runner 错误路径断言 state.error）

    func test_classifyError_401_mapsToAuthMessage() async {
        let runner = await runBackendThrowing(AIError.server(401, "invalid api key"))
        XCTAssertTrue(runner.error?.contains("鉴权") == true,
                      "401 应映射为鉴权文案，实际：\(runner.error ?? "nil")")
    }

    func test_classifyError_429_mapsToRateLimitMessage() async {
        let runner = await runBackendThrowing(AIError.server(429, "rate limited"))
        let error = runner.error ?? ""
        XCTAssertTrue(error.contains("频繁") || error.contains("额度"),
                      "429 应映射为频率/额度文案，实际：\(error)")
    }

    func test_classifyError_urlTimedOut_mapsToTimeoutMessage() async {
        let runner = await runBackendThrowing(URLError(.timedOut))
        XCTAssertTrue(runner.error?.contains("超时") == true,
                      "URLError.timedOut 应映射为超时文案，实际：\(runner.error ?? "nil")")
    }

    // MARK: - B11 cancel 后旧 run 与新 run 的竞态：旧收尾不得覆盖新 run 状态
    //
    // 场景：旧 run 卡在不可取消点（工具确认 continuation）→ cancel() 同步放行
    // isRunning → 新 run 立即启动并完成 → 旧 run 被放行走到收尾。
    // 断言：旧收尾因 generation 不匹配静默放弃（不覆盖 finalText/isRunning/error、
    // 不再次触发 onComplete）。覆盖的是收尾守卫 + 循环顶代际检查整条路径。

    func test_staleRunCleanup_doesNotOverwriteNewRun() async {
        let stuck = StuckTool(name: "stuck_tool")
        // 旧 run 的 backend：第一轮发起会卡住的工具调用
        let oldBackend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "stuck_tool", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )),
        ])
        // 新 run 的 backend：直接给出最终答案
        let newBackend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(text: "新 run 答案", toolCalls: [], finishReason: "stop")),
        ])
        let queue = BackendQueue([oldBackend, newBackend])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in queue.next() })

        // 1) 启动旧 run，等它卡进工具
        runner.run(messages: [AgentMessage(role: .user, content: "old")],
                   tools: [stuck], config: cfg, context: ctx)
        let startDeadline = Date().addingTimeInterval(2)
        while !stuck.didStart && Date() < startDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(stuck.didStart, "旧 run 应已进入卡住的工具")

        // 2) cancel：同步放行 isRunning（旧 _run 仍卡在 continuation 上）
        runner.cancel()
        XCTAssertFalse(runner.isRunning)

        // 3) 新 run 立即启动（旧 _run 还没退出），等待其完成
        var completeCount = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runner.onComplete = { completeCount += 1; cont.resume() }
            runner.run(messages: [AgentMessage(role: .user, content: "new")],
                       tools: [], config: cfg, context: ctx)
        }
        XCTAssertEqual(runner.finalText, "新 run 答案")

        // 4) 放行旧 run：其 _run 走到收尾，必须因代际不匹配静默放弃
        stuck.release()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(runner.finalText, "新 run 答案", "旧 run 收尾不得覆盖新 run 的 finalText")
        XCTAssertFalse(runner.isRunning, "旧 run 收尾不得重置 isRunning")
        XCTAssertNil(runner.error, "旧 run 收尾不得写入 error")
        XCTAssertEqual(completeCount, 1, "旧 run 收尾不得再次触发 onComplete")
    }

    // MARK: - B12 停滞检测：相同 (工具, 参数) 连续失败 3 次 → 中断 run

    func test_stallDetection_sameFailingCallThreeTimes_abortsRun() async {
        let tool = FailingTool(name: "failing_tool")
        let failingCall = { (id: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "failing_tool",
                                          argumentsJSON: #"{"path":"missing.md"}"#)],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(failingCall("tc1")),
            .respond(failingCall("tc2")),
            .respond(failingCall("tc3")),
            // 第 4 轮不应被消费：停滞中断后不再发后端请求
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 10, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [tool])

        XCTAssertEqual(tool.callCount, 3, "工具应恰好执行 3 次")
        XCTAssertEqual(backend.receivedMessages.count, 3,
                       "停滞中断后不应再发第 4 次后端请求，实际：\(backend.receivedMessages.count)")
        XCTAssertFalse(runner.isRunning)

        // 错误文案：指出卡住的工具、连续失败次数、建议换说法
        let error = runner.error ?? ""
        XCTAssertTrue(error.contains("failing_tool"), "文案应指出卡住的工具，实际：\(error)")
        XCTAssertTrue(error.contains("停滞"), "文案应说明停滞中断，实际：\(error)")
        XCTAssertTrue(error.contains("3"), "文案应包含连续失败次数，实际：\(error)")

        // 诊断信息写入 run state
        let stall = runner.state.stall
        XCTAssertEqual(stall?.toolName, "failing_tool")
        XCTAssertEqual(stall?.repeatCount, 3)
        XCTAssertTrue(stall?.lastErrorSummary.contains("总是失败") == true,
                      "诊断应含最后一次错误摘要，实际：\(stall?.lastErrorSummary ?? "nil")")

        // 不是误报步数超限
        XCTAssertFalse(error.contains("最大步数"), "停滞中断不应报步数超限，实际：\(error)")
    }

    func test_stallDetection_sameToolDifferentArgs_notStalled() async {
        // 同工具但参数不同 → 指纹不同，不计入连续失败
        let tool = FailingTool(name: "failing_tool")
        let failingCall = { (id: String, path: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "failing_tool",
                                          argumentsJSON: "{\"path\":\"\(path)\"}")],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(failingCall("tc1", "a.md")),
            .respond(failingCall("tc2", "b.md")),
            .respond(failingCall("tc3", "c.md")),
            .respond(AgentCompletionResponse(text: "最终答案", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 10, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [tool])

        XCTAssertEqual(runner.finalText, "最终答案")
        XCTAssertNil(runner.error)
        XCTAssertNil(runner.state.stall, "参数不同的失败不应判定停滞")
        XCTAssertEqual(backend.receivedMessages.count, 4)
    }

    func test_stallDetection_successResetsConsecutiveCount() async {
        // fail fail success fail fail：成功会重置连续计数，达不到阈值
        let tool = FlappingTool(name: "flapping_tool", successArg: "good.md")
        let call = { (id: String, path: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "flapping_tool",
                                          argumentsJSON: "{\"path\":\"\(path)\"}")],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(call("tc1", "bad.md")),
            .respond(call("tc2", "bad.md")),
            .respond(call("tc3", "good.md")),   // 成功：重置连续失败计数
            .respond(call("tc4", "bad.md")),
            .respond(call("tc5", "bad.md")),
            .respond(AgentCompletionResponse(text: "最终答案", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 10, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [tool])

        XCTAssertEqual(runner.finalText, "最终答案")
        XCTAssertNil(runner.state.stall, "中间有成功不应判定停滞（只计「连续」失败）")
        XCTAssertEqual(backend.receivedMessages.count, 6)
    }

    // MARK: - B16 停滞检测（规则 2）：换参反复失败 4 步 → 中断

    func test_stallDetection_allFailedStepsWithDifferentArgs_abortsRun() async {
        // 规则 1 只认「相同 (工具, 参数) 连续失败」，模型每次微调一点参数就完全绕过。
        // 规则 2 改判「本步所有工具调用都失败」连续达阈值。
        let tool = FailingTool(name: "failing_tool")
        let call = { (id: String, path: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "failing_tool",
                                          argumentsJSON: "{\"path\":\"\(path)\"}")],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(call("tc1", "a.md")),
            .respond(call("tc2", "b.md")),
            .respond(call("tc3", "c.md")),
            .respond(call("tc4", "d.md")),
            // 第 5 轮不应被消费：规则 2 在连续 4 步全失败后中断
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 20, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [tool])

        XCTAssertEqual(tool.callCount, 4, "应执行 4 次后中断")
        XCTAssertEqual(backend.receivedMessages.count, 4,
                       "规则 2 中断后不应再发第 5 次后端请求，实际：\(backend.receivedMessages.count)")
        XCTAssertFalse(runner.isRunning)

        let error = runner.error ?? ""
        XCTAssertTrue(error.contains("全部失败"), "文案应说明整步全失败，实际：\(error)")
        XCTAssertTrue(error.contains("failing_tool"), "文案应指出涉及的工具，实际：\(error)")
        XCTAssertFalse(error.contains("最大步数"), "不应误报步数超限，实际：\(error)")
        XCTAssertEqual(runner.state.stall?.repeatCount, 4)
    }

    // MARK: - B17 停滞检测（规则 3）：成功但零进展连续 5 步 → 中断

    func test_stallDetection_repeatedIdenticalSuccessfulResults_abortsRun() async {
        // 规则 1 只认失败调用。「调用都成功、结果却始终相同」（反复读同一文件、
        // 反复把同一段写回去）不报错，却能烧满 maxSteps 并报「超过最大步数」，
        // 错误文案还不指向真因。规则 3 用「结果签名是否本 run 已出现过」判定零进展。
        let spy = RunnerSpyTool(name: "read_document", result: "SAME CONTENT")
        let call = { (id: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "read_document",
                                          argumentsJSON: #"{"path":"doc.md"}"#)],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(call("tc1")), .respond(call("tc2")), .respond(call("tc3")),
            .respond(call("tc4")), .respond(call("tc5")),
            // 第 6 轮不应被消费（第 1 步是新结果，故连续零进展从第 2 步开始计数）
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 20, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [spy])

        XCTAssertEqual(backend.receivedMessages.count, 5,
                       "连续 5 步零进展后应中断，不应发第 6 次请求，实际：\(backend.receivedMessages.count)")
        let error = runner.error ?? ""
        XCTAssertTrue(error.contains("没有"), "文案应说明无有效进展，实际：\(error)")
        XCTAssertFalse(error.contains("最大步数"), "不应误报步数超限，实际：\(error)")
        XCTAssertEqual(runner.state.stall?.repeatCount, 4,
                       "第 1 步算新结果，零进展从第 2 步起计，触发时为 4")
    }

    // MARK: - B18 规则 3 不误杀：重复被「新结果」打断则不计停滞

    func test_stallDetection_repeatedResultsBrokenByNewResult_notStalled() async {
        // 结果序列 A A A B：第 4 步出现新结果 → 零进展计数归零，不应判定停滞
        let tool = SequencedResultTool(name: "seq_tool", results: ["A", "A", "A", "B"])
        let call = { (id: String) in
            AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: id, name: "seq_tool", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )
        }
        let backend = ScriptedBackend(script: [
            .respond(call("tc1")), .respond(call("tc2")),
            .respond(call("tc3")), .respond(call("tc4")),
            .respond(AgentCompletionResponse(text: "最终答案", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 20, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [tool])

        XCTAssertEqual(runner.finalText, "最终答案")
        XCTAssertNil(runner.error, "有进展的重复不应判定停滞，实际：\(runner.error ?? "nil")")
        XCTAssertNil(runner.state.stall)
    }

    // MARK: - B13 工具耗时记录：真实执行分支写入 durationSeconds

    func test_toolCallDone_recordsDuration() async {
        let spy = RunnerSpyTool(name: "read_document", result: "doc")
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "read_document", argumentsJSON: "{}")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })

        await runAndWait(runner, tools: [spy])

        let done = runner.steps.first { $0.isDone }
        guard case .toolCallDone(_, _, _, _, _, let duration)? = done else {
            XCTFail("应有 toolCallDone step，实际：\(String(describing: done))")
            return
        }
        XCTAssertNotNil(duration, "真实执行的工具应记录耗时")
        XCTAssertGreaterThanOrEqual(duration ?? -1, 0)
    }

    func test_toolCallDone_parseErrorBranch_noDuration() async {
        // 参数解析失败的短路分支不执行工具，duration 应为 nil
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "bad1", name: "read_document", argumentsJSON: "{bad")],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })

        await runAndWait(runner)

        let done = runner.steps.first { $0.isDone }
        guard case .toolCallDone(_, _, _, _, _, let duration)? = done else {
            XCTFail("应有 toolCallDone step")
            return
        }
        XCTAssertNil(duration, "短路分支不应有执行耗时")
    }

    // MARK: - B15 用户 Stop 解除挂起的写审阅（continuation 不响应 Task 取消）

    func test_cancel_releasesPendingWriteReview_andPreventsLateWrite() async {
        // 真实 WriteDocumentTool + 挂起式审阅的 mock context：工具卡在 reviewFileWrite
        // 的 continuation 上（不响应 Task 取消）。用户点 Stop（runner.cancel）必须经
        // context 解除挂起，否则 run 卡到超时，且审阅随后被批准时写入仍会落盘。
        let backend = ScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "write_document",
                                          argumentsJSON: #"{"content":"rewritten"}"#)],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "不应到达", toolCalls: [], finishReason: "stop")),
        ])
        let runner = AgentRunner(maxSteps: 5, backendFactory: { _ in backend })
        ctx.reviewHangsUntilCancelled = true
        var completed = false
        runner.onComplete = { completed = true }

        runner.run(messages: [AgentMessage(role: .user, content: "rewrite")],
                   tools: [WriteDocumentTool()], config: cfg, context: ctx)

        // 等工具进入挂起的写审阅
        let startDeadline = Date().addingTimeInterval(2)
        while ctx.reviewedWritePreviews.isEmpty && Date() < startDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ctx.reviewedWritePreviews.count, 1, "工具应已进入写审阅并挂起")

        // 用户点 Stop：cancel 必须解除挂起的审阅，run 及时收尾而非卡到超时
        runner.cancel()

        let doneDeadline = Date().addingTimeInterval(2)
        while !completed && Date() < doneDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed, "cancel 后 run 应及时收尾，不卡到超时")
        XCTAssertGreaterThanOrEqual(ctx.cancelPendingWriteConfirmationCallCount, 1,
                                    "cancel 应经 context 解除挂起的写审阅")
        XCTAssertTrue(ctx.writtenContents.isEmpty, "已取消的 run 不得再写入文档")
        XCTAssertEqual(ctx.currentDocument, "Initial document content")
        XCTAssertEqual(backend.receivedMessages.count, 1, "取消后不应再发后端请求")
    }

    // MARK: - B19 超时与步数预算联动
    //
    // 背景：timeoutSeconds 曾硬编码 300s，而 aiAgentMaxSteps 是用户可配的
    // （设置页允许 5–100）。调到 100 步时墙钟先到，后半程永远走不到，且报错
    // 只说是「超时」，误导成任务太重而不是预算没给足。
    func test_B19_timeoutScalesWithStepBudget() {
        XCTAssertEqual(AgentRunner(maxSteps: 30).timeoutSeconds, 300,
                       "30 步应与历史默认 300s 一致——不改默认行为")
        XCTAssertEqual(AgentRunner(maxSteps: 5).timeoutSeconds, 300,
                       "步数很少时保留下限 300s")
        XCTAssertEqual(AgentRunner(maxSteps: 100).timeoutSeconds, 1000,
                       "设置页允许 100 步，总超时必须跟上（100 × 10s）")
        XCTAssertEqual(AgentRunner(maxSteps: 0).timeoutSeconds, 300,
                       "0 步是退化输入，保留下限而不是 0s（0 = 不限的语义不能被误触发）")
    }

    // MARK: - Helpers

    private func runAndWait(_ runner: AgentRunner, tools: [any AgentTool] = []) async {
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

    /// 用一个首轮即抛错的 backend 跑 runner，返回结束后的 runner 供断言 error。
    private func runBackendThrowing(_ error: Error) async -> AgentRunner {
        let backend = ScriptedBackend(script: [.fail(error)])
        let runner = AgentRunner(maxSteps: 3, backendFactory: { _ in backend })
        await runAndWait(runner)
        return runner
    }
}

// MARK: - 私有测试 doubles

/// 按脚本依次返回响应或抛错的 backend；记录每轮收到的 messages。
private final class ScriptedBackend: AgentBackend, @unchecked Sendable {
    enum Step {
        case respond(AgentCompletionResponse)
        case fail(Error)
    }

    private var script: [Step]
    private let lock = NSLock()
    private(set) var receivedMessages: [[AgentMessage]] = []

    init(script: [Step]) { self.script = script }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        let step = lock.withLock { () -> Step in
            receivedMessages.append(messages)
            return script.isEmpty
                ? Step.respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop"))
                : script.removeFirst()
        }
        switch step {
        case .respond(let response): return response
        case .fail(let error):       throw error
        }
    }
}

/// 记录是否被调用的 spy 工具。
private final class RunnerSpyTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let result: String
    private(set) var wasCalled = false

    init(name: String, result: String) {
        self.spec   = AgentToolSpec(name: name, description: "Spy tool: \(name)")
        self.result = result
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        wasCalled = true
        return result
    }
}

/// 执行时抛出固定错误的工具——用于验证 CancellationError 不被包装成 tool error。
private final class ThrowingTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let error: Error

    init(name: String, error: Error) {
        self.spec  = AgentToolSpec(name: name, description: "Throwing tool: \(name)")
        self.error = error
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        throw error
    }
}

/// 执行时在 MainActor 上调用给定闭包的工具——用于在工具执行中途 cancel runner。
private final class SelfCancellingTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let body: @MainActor @Sendable () -> Void

    init(name: String, body: @escaping @MainActor @Sendable () -> Void) {
        self.spec = AgentToolSpec(name: name, description: "Self-cancelling tool")
        self.body = body
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        await body()
        return "cancel issued"
    }
}

/// 卡在不可取消点的工具：execute 挂起在 continuation 上，直到 release() 手动放行
/// （模拟命令确认对话框——continuation 不响应 Task 取消）。
private final class StuckTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var didStart = false

    init(name: String) {
        self.spec = AgentToolSpec(name: name, description: "Stuck tool: \(name)")
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        lock.withLock { didStart = true }
        return await withCheckedContinuation { cont in
            lock.withLock { continuation = cont }
        }
    }

    func release() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: "stuck tool released")
    }
}

/// 按序派发 backend 的队列（backendFactory 是 @Sendable 闭包，用锁盒避免捕获可变 var）。
private final class BackendQueue: @unchecked Sendable {
    private let backends: [ScriptedBackend]
    private var index = 0
    private let lock = NSLock()

    init(_ backends: [ScriptedBackend]) { self.backends = backends }

    func next() -> ScriptedBackend {
        lock.lock(); defer { lock.unlock() }
        let backend = backends[min(index, backends.count - 1)]
        index += 1
        return backend
    }
}

/// 总是失败的工具：用于停滞检测（相同调用连续失败）。
private final class FailingTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private(set) var callCount = 0

    init(name: String) {
        self.spec = AgentToolSpec(name: name, description: "Failing tool: \(name)")
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        callCount += 1
        throw AgentError.executionError("总是失败")
    }
}

/// 按参数决定成败的工具：arguments["path"] == successArg 时成功，否则失败。
/// 用于验证「成功会重置连续失败计数」。
private final class FlappingTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let successArg: String

    init(name: String, successArg: String) {
        self.spec = AgentToolSpec(name: name, description: "Flapping tool: \(name)")
        self.successArg = successArg
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        if arguments["path"]?.stringValue == successArg { return "ok" }
        throw AgentError.executionError("总是失败")
    }
}

/// 依次返回预设结果的工具（用完后重复最后一个）——用于验证规则 3 的「新结果会
/// 打断零进展计数」。
private final class SequencedResultTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private let results: [String]
    private var index = 0

    init(name: String, results: [String]) {
        self.spec    = AgentToolSpec(name: name, description: "Sequenced tool: \(name)")
        self.results = results
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        let result = results[min(index, results.count - 1)]
        index += 1
        return result
    }
}
