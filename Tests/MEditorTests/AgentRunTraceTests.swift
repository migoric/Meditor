import XCTest
@testable import MEditor

/// 运行轨迹（`AgentRunTrace` / `AgentTraceStore`）的契约测试。
///
/// 两条必须守住的性质：
/// 1. **不含正文**——轨迹会被写到用户磁盘上，参数与结果里有文档内容的话
///    就等于偷偷做了第二份副本；
/// 2. **容量有上限**——排障材料不该无限增长。
@MainActor
final class AgentRunTraceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meditor-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try super.tearDownWithError()
    }

    // MARK: - make(from:)

    private func makeState(steps: [AgentRunnerStep] = []) -> AgentRunState {
        let state = AgentRunState()
        state.steps = steps
        state.termination = .completed
        state.modelName = "claude-sonnet-4-5"
        state.runDurationSeconds = 12.5
        state.usage = AgentUsage(promptTokens: 1000, completionTokens: 200,
                                 cacheReadTokens: 800, cacheWriteTokens: 0)
        return state
    }

    func test_make_recordsToolSequenceAndSizes() {
        let state = makeState(steps: [
            .thinking(label: "planning"),
            .toolCall(id: "c1", name: "read_document", args: "{}"),
            .toolCallDone(id: "c1", name: "read_document", args: "{}", result: "0123456789",
                          isError: false, durationSeconds: 0.02),
            .toolCallDone(id: "c2", name: "write_document", args: "{\"content\":\"x\"}",
                          result: "denied", isError: true, durationSeconds: nil)
        ])

        let trace = AgentRunTrace.make(from: state, sessionID: nil)

        XCTAssertEqual(trace.toolSequence, ["read_document", "write_document"], "只记真正执行完的调用")
        XCTAssertEqual(trace.toolCalls[0].argsBytes, 2)
        XCTAssertEqual(trace.toolCalls[0].resultBytes, 10)
        XCTAssertFalse(trace.toolCalls[0].isError)
        XCTAssertTrue(trace.toolCalls[1].isError)
        XCTAssertNil(trace.toolCalls[1].durationSeconds, "短路分支没有耗时")
        XCTAssertEqual(trace.stepCount, 4)
        XCTAssertEqual(trace.termination, "completed")
        XCTAssertEqual(trace.usage?.cacheReadTokens, 800)
        XCTAssertEqual(trace.schemaVersion, AgentRunTrace.currentSchemaVersion)
    }

    func test_make_neverStoresDocumentContent() throws {
        let secret = "SECRET-DOC-BODY-不要把这段写进轨迹"
        let state = makeState(steps: [
            .toolCallDone(id: "c1", name: "write_document",
                          args: "{\"content\":\"\(secret)\"}", result: "ok \(secret)",
                          isError: false, durationSeconds: 0.01)
        ])
        state.finalText = secret

        let trace = AgentRunTrace.make(from: state, sessionID: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(String(data: try encoder.encode(trace), encoding: .utf8))

        XCTAssertFalse(json.contains(secret), "轨迹里绝不能出现文档正文")
        XCTAssertFalse(json.contains("content"), "连参数键名都不该留")
        // 但"发生了多长的一次写入"要留下——排障靠的是这个
        XCTAssertGreaterThan(trace.toolCalls[0].argsBytes, 0)
    }

    func test_errorSummary_keepsFirstLineOnly() {
        let state = makeState()
        state.error = "HTTP 500: upstream exploded\nstack trace line 1\nstack trace line 2"
        let trace = AgentRunTrace.make(from: state, sessionID: nil)
        XCTAssertEqual(trace.errorSummary, "HTTP 500: upstream exploded")
    }

    func test_errorSummary_truncatesVeryLongLine() {
        let state = makeState()
        state.error = String(repeating: "x", count: 400)
        let trace = AgentRunTrace.make(from: state, sessionID: nil)
        XCTAssertEqual(trace.errorSummary?.count, 161, "160 + 省略号")
        XCTAssertTrue(trace.errorSummary?.hasSuffix("…") ?? false)
    }

    func test_stall_isSummarized() {
        let state = makeState()
        state.termination = .failed
        state.stall = AgentStallDiagnostic(toolName: "read_file", repeatCount: 4, lastErrorSummary: "ENOENT")
        let trace = AgentRunTrace.make(from: state, sessionID: nil)
        XCTAssertEqual(trace.stall, "read_file×4")
        XCTAssertEqual(trace.termination, "failed")
    }

    // MARK: - Store

    private func trace(at offset: TimeInterval, runID: UUID = UUID()) -> AgentRunTrace {
        AgentRunTrace(
            runID: runID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            sessionID: nil,
            termination: "completed",
            model: "m",
            durationSeconds: 1,
            usage: nil,
            stepCount: 1,
            toolCalls: [],
            stall: nil,
            errorSummary: nil
        )
    }

    func test_store_saveAndLoadRoundTrip() {
        let store = AgentTraceStore(baseDir: tmpDir)
        XCTAssertTrue(store.save(trace(at: 0)))
        XCTAssertTrue(store.save(trace(at: 1)))

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.allSatisfy { $0.schemaVersion == AgentRunTrace.currentSchemaVersion })
    }

    func test_store_roundTripPreservesFields() throws {
        let store = AgentTraceStore(baseDir: tmpDir)
        let original = trace(at: 5)
        store.save(original)
        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded.runID, original.runID)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970,
                       original.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(loaded.termination, original.termination)
    }

    func test_store_prunesToMaxFiles() {
        let store = AgentTraceStore(baseDir: tmpDir, maxFiles: 3)
        for i in 0..<5 { store.save(trace(at: TimeInterval(i))) }

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 3, "只留最近 3 个")
        // 留下的应是最新三个（201..204），不是最老三个
        let kept = Set(loaded.map { Int($0.createdAt.timeIntervalSince1970 - 1_700_000_000) })
        XCTAssertEqual(kept, [2, 3, 4])
    }

    func test_store_skipsUnknownSchemaVersion() throws {
        // 手工写一条未来版本的轨迹：解码得出来但语义不认识 ⇒ 必须跳过，不能误读
        let future = """
        {"schemaVersion": 99, "runID": "\(UUID().uuidString)", "createdAt": "2026-01-01T00:00:00Z",
         "termination": "completed", "stepCount": 0, "toolCalls": []}
        """
        let dir = AgentTraceStore(baseDir: tmpDir).directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try future.data(using: .utf8)!.write(to: dir.appendingPathComponent("20990101-000000-deadbeef.json"))

        XCTAssertTrue(AgentTraceStore(baseDir: tmpDir).loadAll().isEmpty)
    }

    func test_fileName_isSortableByTime() {
        XCTAssertEqual(AgentTraceStore.fileName(for: trace(at: 0, runID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)),
                       "20231114-221320-AAAAAAAA.json")
    }

    func test_directory_isUnderInjectedBase() {
        XCTAssertEqual(AgentTraceStore(baseDir: tmpDir).directory.lastPathComponent, "traces")
        XCTAssertEqual(AgentTraceStore(baseDir: tmpDir).directory.deletingLastPathComponent().lastPathComponent,
                       tmpDir.lastPathComponent)
    }
}
