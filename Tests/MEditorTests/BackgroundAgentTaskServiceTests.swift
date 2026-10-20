import XCTest
@testable import MEditor

// MARK: - BackgroundAgentTaskServiceTests
//
// 后台 Agent 任务（BackgroundAgentTaskService）回归测试：
//   生命周期：发起 → running → completed/failed，结果摘要生成、完成通知触发
//   并发上限：第 3 个任务被拒（返回 nil）；任务结束后槽位释放
//   取消链路：service.cancel → runner.cancel → 挂起的写审阅被解除，任务归类 cancelled
//   宿主端口（P0-10）：toast 反馈与默认 contextFactory 经 AgentHostPort 可观测
//
// 不依赖真实 AI 后端：mock 模式沿用 AgentRunnerStabilityTests（ScriptedBackend / 挂起式审阅）。
// 断言不写死中文文案（CI 英文 locale）：结果摘要对脚本化 finalText / 注入错误原文断言；
// toast 断言只看 icon 与「含任务标题」（两种 locale 的格式串都带 %@）。

@MainActor
final class BackgroundAgentTaskServiceTests: XCTestCase {

    private var ctx: MockAgentContext!
    private var cfg: AIConfig!
    private var notifications: [(title: String, body: String)]!

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        ctx.currentDocument     = "Initial document content"
        ctx.currentDocumentName = "test.md"
        cfg = AIConfig(
            kind: .disabled, baseURL: "", model: "", cliPath: "", cliModel: "", apiKey: "",
            requestTimeoutSeconds: 60
        )
        notifications = []
    }

    private func makeService(backend: any AgentBackend,
                             host: (any AgentHostPort)? = nil) -> BackgroundAgentTaskService {
        // host: nil —— 不触碰真实宿主；context / 系统通知走注入
        let service = BackgroundAgentTaskService(host: host, backendFactory: { _ in backend })
        service.contextFactory = { [weak self] _, _ in self?.ctx }
        service.systemNotify = { [weak self] title, body in
            self?.notifications.append((title, body))
        }
        return service
    }

    /// 轮询等待条件满足（后台任务的 run 经 Task 异步启动，完成回调同理）
    private func waitUntil(_ timeout: TimeInterval = 3,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - 生命周期：发起 → running → completed，结果摘要生成

    func test_taskLifecycle_completes_withResultSummary() async {
        let backend = BGScriptedBackend(script: [
            .respond(AgentCompletionResponse(text: "All done\nsecond line", toolCalls: [], finishReason: "stop")),
        ])
        let service = makeService(backend: backend)

        let task = service.start(prompt: "summarize this doc", systemPrompt: "sys",
                                 config: cfg, maxSteps: 5)
        XCTAssertNotNil(task)
        XCTAssertEqual(service.tasks.count, 1)
        XCTAssertEqual(task?.title, "summarize this doc")
        XCTAssertEqual(task?.termination, .running, "发起后应立即处于 running")

        let finished = await waitUntil { task?.termination == .completed }
        XCTAssertTrue(finished, "任务应正常完成")
        // 结果摘要 = finalText 首个非空行
        XCTAssertEqual(task?.resultSummary, "All done")
        XCTAssertNotNil(task?.endedAt)
        XCTAssertFalse(task?.isRunning ?? true)
        XCTAssertEqual(notifications.count, 1, "完成时应触发一次通知回调")
    }

    // MARK: - 生命周期：失败 → failed + 错误摘要

    func test_taskLifecycle_failure_recordsErrorSummary() async {
        let backend = BGScriptedBackend(script: [
            .fail(NSError(domain: "BGTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "backend boom"])),
        ])
        let service = makeService(backend: backend)

        let task = service.start(prompt: "do something", systemPrompt: "sys",
                                 config: cfg, maxSteps: 5)
        let finished = await waitUntil { task?.termination == .failed }
        XCTAssertTrue(finished, "后端错误应归类为 failed")
        XCTAssertTrue(task?.resultSummary?.contains("backend boom") == true,
                      "失败摘要应含错误原文，实际：\(task?.resultSummary ?? "nil")")
        XCTAssertNotNil(task?.endedAt)
        XCTAssertEqual(notifications.count, 1)
    }

    // MARK: - 并发上限：第 3 个任务被拒；结束后槽位释放

    func test_concurrencyLimit_thirdTaskRejected_slotFreedAfterFinish() async {
        // 挂起式 backend：两个任务保持 running（不响应取消的 continuation 会泄漏，
        // 这里用可取消的长 sleep）
        let backend = BGHangingBackend()
        let service = makeService(backend: backend)

        let t1 = service.start(prompt: "task one", systemPrompt: "sys", config: cfg, maxSteps: 5)
        let t2 = service.start(prompt: "task two", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNotNil(t1)
        XCTAssertNotNil(t2)

        let t3 = service.start(prompt: "task three", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNil(t3, "达到并发上限（2）时第 3 个任务应被拒绝")
        XCTAssertEqual(service.tasks.count, 2, "被拒绝的任务不应进入列表")

        // 取消两个在途任务 → 槽位释放后可再次发起
        if let t1 { service.cancel(t1) }
        if let t2 { service.cancel(t2) }
        let freed = await waitUntil {
            service.tasks.filter(\.isRunning).isEmpty
        }
        XCTAssertTrue(freed, "取消后不应再有 running 任务")

        let t4 = service.start(prompt: "task four", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNotNil(t4, "任务结束后槽位应释放")
        if let t4 { service.cancel(t4) }
    }

    // MARK: - 取消链路：挂起的写审阅被解除，任务归类 cancelled

    func test_cancel_releasesPendingWriteReview_andMarksCancelled() async {
        // 真实 WriteDocumentTool + 挂起式写审阅（continuation 不响应 Task 取消）：
        // service.cancel 必须经 runner.cancel → context 解除挂起，否则任务卡到超时。
        let backend = BGScriptedBackend(script: [
            .respond(AgentCompletionResponse(
                text: "",
                toolCalls: [AgentToolCall(id: "tc1", name: "write_document",
                                          argumentsJSON: #"{"content":"rewritten"}"#)],
                finishReason: "tool_calls"
            )),
            .respond(AgentCompletionResponse(text: "should not reach", toolCalls: [], finishReason: "stop")),
        ])
        let service = makeService(backend: backend)
        ctx.reviewHangsUntilCancelled = true

        let task = service.start(prompt: "rewrite the doc", systemPrompt: "sys",
                                 config: cfg, maxSteps: 5)
        XCTAssertNotNil(task)

        // 等工具进入挂起的写审阅
        let reviewReached = await waitUntil { [weak self] in
            self?.ctx.reviewedWritePreviews.isEmpty == false
        }
        XCTAssertTrue(reviewReached, "工具应已进入写审阅并挂起")

        service.cancel(task!)

        let settled = await waitUntil { task?.termination == .cancelled }
        XCTAssertTrue(settled, "取消后任务应及时收尾为 cancelled，不卡到超时")
        XCTAssertGreaterThanOrEqual(ctx.cancelPendingWriteConfirmationCallCount, 1,
                                    "取消应经 context 解除挂起的写审阅")
        XCTAssertTrue(ctx.writtenContents.isEmpty, "已取消的任务不得再写入文档")
        XCTAssertNil(task?.resultSummary, "取消不生成结果摘要")
    }

    // MARK: - 标题：取 prompt 首个非空行

    func test_title_takesFirstNonEmptyLine() async {
        let backend = BGHangingBackend()
        let service = makeService(backend: backend)

        let task = service.start(prompt: "\nfirst line here\nsecond line",
                                 systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertEqual(task?.title, "first line here")
        if let task { service.cancel(task) }
    }

    // MARK: - 宿主端口（P0-10）：toast 反馈可观测
    //
    // 修复前：服务持 `weak var appState: AppState?`，单测只能传 nil，
    // 于是这些 toast 分支「跑了但没有任何痕迹」——既没断言也没日志。
    // 修复后：宿主是注入的端口，假宿主即可把反馈留痕。

    func test_concurrencyLimit_toastReachesHost() async {
        let host = RecordingAgentHost()
        let service = makeService(backend: BGHangingBackend(), host: host)

        let t1 = service.start(prompt: "one", systemPrompt: "sys", config: cfg, maxSteps: 5)
        let t2 = service.start(prompt: "two", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNotNil(t1)
        XCTAssertNotNil(t2)

        let t3 = service.start(prompt: "three", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNil(t3, "并发上限外的任务应被拒绝")
        XCTAssertEqual(host.toasts.count, 1, "被拒时应经端口给宿主一条提示")
        XCTAssertEqual(host.toasts.first?.icon, "hourglass")

        // 收尾：取消会让 host 再收到 cancelled toast，故上面的计数断言必须在取消之前
        if let t1 { service.cancel(t1) }
        if let t2 { service.cancel(t2) }
    }

    func test_taskCompletion_toastReachesHost() async {
        let backend = BGScriptedBackend(script: [
            .respond(AgentCompletionResponse(text: "All done", toolCalls: [], finishReason: "stop")),
        ])
        let host = RecordingAgentHost()
        let service = makeService(backend: backend, host: host)

        let task = service.start(prompt: "summarize", systemPrompt: "sys", config: cfg, maxSteps: 5)
        let finished = await waitUntil { task?.termination == .completed }
        XCTAssertTrue(finished)

        XCTAssertEqual(host.toasts.count, 1, "完成时应经端口通知宿主")
        XCTAssertEqual(host.toasts.first?.icon, "checkmark.circle")
        XCTAssertTrue(host.toasts.first?.text.contains("summarize") == true,
                      "提示应带上任务标题，实际：\(host.toasts.first?.text ?? "nil")")
    }

    func test_mcpToolsRequestedFromHost_withHostWorkspaceURL() async {
        let host = RecordingAgentHost()
        let service = makeService(backend: BGHangingBackend(), host: host)

        let task = service.start(prompt: "p", systemPrompt: "sys", config: cfg, maxSteps: 5)
        let asked = await waitUntil { host.mcpCalls.isEmpty == false }
        XCTAssertTrue(asked, "发起 run 时应向宿主索取本轮的 MCP 工具")
        XCTAssertEqual(host.mcpCalls.first ?? nil, host.rootURL,
                       "索取 MCP 工具时应带上宿主自己的工作区根")

        if let task { service.cancel(task) }
    }

    /// 默认 contextFactory 必须经宿主的 makeAgentContext（关键接线断言）：
    /// 若有人把它改回直接调 `AgentContext.make(appState:)`，宿主计数会停在 0 而失败。
    func test_defaultContextFactory_routesThroughHost() async {
        let host = RecordingAgentHost()
        host.context = ctx
        // 不覆盖 contextFactory：走默认实现
        let service = BackgroundAgentTaskService(host: host, backendFactory: { _ in
            BGScriptedBackend(script: [
                .respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop")),
            ])
        })
        service.systemNotify = { _, _ in }

        let task = service.start(prompt: "p", systemPrompt: "sys", config: cfg, maxSteps: 5)
        XCTAssertNotNil(task, "默认工厂应经宿主拿到 context")
        let finished = await waitUntil { task?.termination == .completed }
        XCTAssertTrue(finished)
        XCTAssertEqual(host.contextsMade, 1, "默认工厂应调用宿主的 makeAgentContext")
        XCTAssertEqual(host.lastWriteAutoApproval, WriteAutoApproval.none,
                       "未声明 autoApprove 的发起默认每步写入都确认")
    }

    /// autoApprove 接线：start 的免确认策略必须原样到达 context 工厂
    /// （定时任务无人值守写入的关键链路；断在这里 = 策略被静默吞掉，写仍卡确认条）。
    func test_start_threadsWriteAutoApproval_intoContextFactory() async {
        let service = BackgroundAgentTaskService(host: nil, backendFactory: { _ in
            BGScriptedBackend(script: [
                .respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop")),
            ])
        })
        var received: WriteAutoApproval?
        service.contextFactory = { [weak self] _, approval in
            received = approval
            return self?.ctx
        }
        service.systemNotify = { _, _ in }

        let task = service.start(prompt: "p", systemPrompt: "sys", config: cfg, maxSteps: 5,
                                 writeAutoApproval: .dirs(["weekly/"]))
        XCTAssertNotNil(task)
        XCTAssertEqual(received, .dirs(["weekly/"]))

        if let task { service.cancel(task) }
    }
}

// MARK: - 私有测试 doubles

/// 按脚本依次返回响应或抛错的 backend（模式同 AgentRunnerStabilityTests.ScriptedBackend）。
private final class BGScriptedBackend: AgentBackend, @unchecked Sendable {
    enum Step {
        case respond(AgentCompletionResponse)
        case fail(Error)
    }

    private var script: [Step]
    private let lock = NSLock()

    init(script: [Step]) { self.script = script }

    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        let step = lock.withLock { () -> Step in
            script.isEmpty
                ? Step.respond(AgentCompletionResponse(text: "done", toolCalls: [], finishReason: "stop"))
                : script.removeFirst()
        }
        switch step {
        case .respond(let response): return response
        case .fail(let error):       throw error
        }
    }
}

/// 永不完成的 backend（长 sleep，响应 Task 取消）：让任务保持 running 以测并发上限。
private final class BGHangingBackend: AgentBackend, @unchecked Sendable {
    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        try await Task.sleep(for: .seconds(3600))
        return AgentCompletionResponse(text: "unreachable", toolCalls: [], finishReason: "stop")
    }
}

