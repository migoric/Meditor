import XCTest
@testable import MEditor

// MARK: - AgentRunCheckpointTests
//
// run 级文件快照 + 一键回滚单测：
//   A. 快照数据层：capture / markWritten / planRollback 纯逻辑
//   B. AgentContext 采集：五个写路径的快照挂载（真实临时目录 + DefaultAgentFileRepository）
//   C. AppState 回滚执行：磁盘恢复 / 新建删除 / tab 同步 / 用户编辑跳过（MockFileService）
// mock 模式参照 AgentToolTests / FileWriteConfirmationTests。

@MainActor
final class AgentRunCheckpointTests: XCTestCase {

    // MARK: - A. 快照数据层

    func testCaptureBeforeWrite_recordsOriginalContent() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/a.md")
        ckpt.captureBeforeWrite(url: url, knownContent: "原始内容")
        ckpt.markWritten(url: url, content: "agent 写入")

        XCTAssertEqual(ckpt.snapshots.count, 1)
        XCTAssertEqual(ckpt.snapshots[0].preWrite, .existed("原始内容"))
        XCTAssertEqual(ckpt.snapshots[0].postWriteContent, "agent 写入")
        XCTAssertTrue(ckpt.hasWrites)
        XCTAssertEqual(ckpt.rollbackableCount, 1)
    }

    func testCapture_sameFileTwice_onlyFirstPreStateKept() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/a.md")
        ckpt.captureBeforeWrite(url: url, knownContent: "v0")
        ckpt.markWritten(url: url, content: "v1")
        // 第二次写同一路径：写前快照不被动，postWrite 基准移动到最新
        ckpt.captureBeforeWrite(url: url, knownContent: "v1")
        ckpt.markWritten(url: url, content: "v2")

        XCTAssertEqual(ckpt.snapshots.count, 1, "同一文件只记一次写前快照")
        XCTAssertEqual(ckpt.snapshots[0].preWrite, .existed("v0"))
        XCTAssertEqual(ckpt.snapshots[0].postWriteContent, "v2")
    }

    func testCaptureCreatedFile_marksDidNotExist() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/new.md")
        ckpt.captureCreatedFile(url: url)
        ckpt.markWritten(url: url, content: "# 新建")
        XCTAssertEqual(ckpt.snapshots[0].preWrite, .didNotExist)
    }

    func testCapture_oversizedContent_notSnapshotable() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/big.md")
        let big = String(repeating: "a", count: AgentRunCheckpoint.maxSnapshotBytes + 1)
        ckpt.captureBeforeWrite(url: url, knownContent: big)
        ckpt.markWritten(url: url, content: "x")
        guard case .notSnapshotable = ckpt.snapshots[0].preWrite else {
            return XCTFail("超过 1MB 的文件不应记录内容快照")
        }
        // 仍可回滚计数（入口可见），但 planRollback 产出 skip
        let actions = ckpt.planRollback { _ in "x" }
        guard case .skip(_, .notSnapshotable) = actions.first else {
            return XCTFail("未快照的文件回滚时必须跳过并给出原因")
        }
    }

    func testPlanRollback_excludesFailedWrites() {
        // 快照后写入未成功（postWriteContent 为 nil）：文件未被改动，不产出任何动作
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/a.md")
        ckpt.captureBeforeWrite(url: url, knownContent: "原文")
        let actions = ckpt.planRollback { _ in "原文" }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(ckpt.hasWrites)
    }

    func testPlanRollback_restoreWhenContentMatchesPostWrite() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/a.md")
        ckpt.captureBeforeWrite(url: url, knownContent: "原文")
        ckpt.markWritten(url: url, content: "agent 写入")
        let actions = ckpt.planRollback { _ in "agent 写入" }
        XCTAssertEqual(actions, [.restore(url: url.standardizedFileURL, content: "原文")])
    }

    func testPlanRollback_skipsWhenUserEditedAfterRun() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/a.md")
        ckpt.captureBeforeWrite(url: url, knownContent: "原文")
        ckpt.markWritten(url: url, content: "agent 写入")
        let actions = ckpt.planRollback { _ in "用户又改了" }
        XCTAssertEqual(actions, [.skip(url: url.standardizedFileURL, reason: .editedAfterRun)],
                       "run 结束后的用户编辑绝不被覆盖")
    }

    func testPlanRollback_createdFile_deletedOnlyWhenUntouched() {
        let ckpt = AgentRunCheckpoint()
        let url = URL(fileURLWithPath: "/tmp/ckpt/new.md")
        ckpt.captureCreatedFile(url: url)
        ckpt.markWritten(url: url, content: "新建内容")
        XCTAssertEqual(ckpt.planRollback { _ in "新建内容" },
                       [.deleteCreated(url: url.standardizedFileURL)])
        XCTAssertEqual(ckpt.planRollback { _ in "用户改过" },
                       [.skip(url: url.standardizedFileURL, reason: .editedAfterRun)])
        XCTAssertEqual(ckpt.planRollback { _ in nil },
                       [.skip(url: url.standardizedFileURL, reason: .fileMissing)])
    }

    func testMarkRolledBack_isIdempotent() {
        let ckpt = AgentRunCheckpoint()
        ckpt.markRolledBack(summary: "第一次")
        ckpt.markRolledBack(summary: "第二次")
        XCTAssertTrue(ckpt.isRolledBack)
        XCTAssertEqual(ckpt.rollbackSummary, "第一次")
    }

    // MARK: - B. AgentContext 采集集成（真实临时目录）

    /// 最小 AgentDocumentAdapter stub：内存 tab + 写盘直通（复用 PatchEngine 真实语义）。
    private final class StubDocAdapter: AgentDocumentAdapter {
        var currentDocument: String?
        var currentDocumentName: String?
        var workspaceURL: URL?
        var currentTabURL: URL?
        /// standardized path → tab 内存内容（模拟打开的 tab）
        var tabContents: [String: String] = [:]

        func writeDocument(_ content: String) throws {
            guard currentDocument != nil else { throw AgentContextError.noActiveDocument }
            currentDocument = content
        }
        func patchDocument(find: String, replace: String, all: Bool) throws -> Int {
            guard let doc = currentDocument else { throw AgentContextError.noActiveDocument }
            let (updated, count) = PatchEngine.apply(to: doc, find: find, replace: replace, all: all)
            if count == 0 { throw PatchNotFoundError(find: find, nearbyContext: "") }
            currentDocument = updated
            return count
        }
        func insertIntoDocument(_ text: String) {}
        func contentForTab(at url: URL) -> String? { tabContents[url.standardizedFileURL.path] }
        func openFile(at url: URL) -> Bool { true }
        func notifyFileCreated(_ url: URL) {}
        func notifyFileWritten(_ url: URL, content: String, isNew: Bool) {}
        func notifyDirectoryCreated(_ url: URL) {}
        func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool { true }
    }

    private var tempDir: URL!
    private var repo: DefaultAgentFileRepository!
    private var adapter: StubDocAdapter!
    private var checkpoint: AgentRunCheckpoint!
    private var ctx: AgentContext!

    private func makeContext() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = DefaultAgentFileRepository({ [tempDir] in tempDir })
        adapter = StubDocAdapter()
        adapter.workspaceURL = tempDir
        checkpoint = AgentRunCheckpoint()
        ctx = AgentContext(files: repo, doc: adapter, checkpoint: checkpoint)
    }

    private func cleanupTempDir() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func writeDisk(_ content: String, _ name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testContext_writeFile_existingFile_capturesDiskOriginal() throws {
        makeContext(); defer { cleanupTempDir() }
        writeDisk("磁盘原文", "a.md")
        try ctx.writeFile(name: "a.md", content: "agent 新内容")

        XCTAssertEqual(checkpoint.snapshots.count, 1)
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .existed("磁盘原文"),
                       "覆盖写前应记录磁盘原内容")
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "agent 新内容")
    }

    func testContext_writeFile_newFile_marksDidNotExist() throws {
        makeContext(); defer { cleanupTempDir() }
        try ctx.writeFile(name: "sub/new.md", content: "全新")
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .didNotExist)
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "全新")
    }

    func testContext_writeFile_openTab_prefersTabContent() throws {
        makeContext(); defer { cleanupTempDir() }
        let url = writeDisk("磁盘原文", "a.md")
        // tab 打开且有未保存编辑：快照应记 tab 内存内容（用户视角的最新内容）
        adapter.tabContents[url.standardizedFileURL.path] = "tab 未保存内容"
        try ctx.writeFile(name: "a.md", content: "agent 写入")
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .existed("tab 未保存内容"))
    }

    func testContext_createFile_marksDidNotExist() throws {
        makeContext(); defer { cleanupTempDir() }
        _ = try ctx.createFile(name: "created.md", content: "# hi")
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .didNotExist)
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "# hi")
    }

    func testContext_patchFile_capturesOriginalAndUpdated() async throws {
        makeContext(); defer { cleanupTempDir() }
        writeDisk("hello world", "p.md")
        let count = try await ctx.patchFile(name: "p.md", find: "world", replace: "there", all: false)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .existed("hello world"))
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "hello there")
    }

    func testContext_writeDocument_capturesCurrentTab() throws {
        makeContext(); defer { cleanupTempDir() }
        let url = writeDisk("tab 原文", "doc.md")
        adapter.currentTabURL = url
        adapter.currentDocument = "tab 原文"
        try ctx.writeDocument("全量重写")
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .existed("tab 原文"))
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "全量重写")
    }

    func testContext_patchDocument_capturesCurrentTab() throws {
        makeContext(); defer { cleanupTempDir() }
        let url = writeDisk("foo bar", "doc.md")
        adapter.currentTabURL = url
        adapter.currentDocument = "foo bar"
        _ = try ctx.patchDocument(find: "bar", replace: "baz", all: false)
        XCTAssertEqual(checkpoint.snapshots[0].preWrite, .existed("foo bar"))
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "foo baz")
    }

    func testContext_writeFile_oversizedFile_notSnapshotable() throws {
        makeContext(); defer { cleanupTempDir() }
        let big = String(repeating: "a", count: AgentRunCheckpoint.maxSnapshotBytes + 1)
        writeDisk(big, "big.md")
        try ctx.writeFile(name: "big.md", content: "small")
        guard case .notSnapshotable = checkpoint.snapshots[0].preWrite else {
            return XCTFail("超过 1MB 的文件不应记录内容快照")
        }
        XCTAssertEqual(checkpoint.snapshots[0].postWriteContent, "small")
    }

    // MARK: - C. AppState 回滚执行（MockFileService 内存文件系统）

    private var mockService: MockFileService!
    private var state: AppState!

    private func makeAppState() {
        mockService = MockFileService()
        // 默认 fileExistsResult=true 会让「文件已删除」场景失真，关掉：存在性完全由 setFile 决定
        mockService.fileExistsResult = false
        state = AppState(fileService: mockService, fileWatcher: MockFileWatcher())
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/nonexistent-rollback-test/\(name)")
    }

    /// 构造「run 已把 name 从 original 改写成 written」的快照 + 磁盘状态
    private func stubWrittenCheckpoint(name: String, original: String, written: String) -> AgentRunCheckpoint {
        let url = fileURL(name)
        mockService.setFile(url, content: written)
        let ckpt = AgentRunCheckpoint()
        ckpt.captureBeforeWrite(url: url, knownContent: original)
        ckpt.markWritten(url: url, content: written)
        return ckpt
    }

    func testRollback_restoresModifiedFileOnDisk() async {
        makeAppState()
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原始内容", written: "agent 写入")
        let actions = await state.rollbackAgentRun(ckpt)

        XCTAssertEqual(mockService.fileContent(at: fileURL("a.md")), "原始内容")
        XCTAssertEqual(actions, [.restore(url: fileURL("a.md").standardizedFileURL, content: "原始内容")])
        XCTAssertTrue(ckpt.isRolledBack)
        XCTAssertNotNil(ckpt.rollbackSummary)
    }

    func testRollback_deletesCreatedFile() async {
        makeAppState()
        let url = fileURL("new.md")
        mockService.setFile(url, content: "新建内容")
        let ckpt = AgentRunCheckpoint()
        ckpt.captureCreatedFile(url: url)
        ckpt.markWritten(url: url, content: "新建内容")

        let actions = await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(actions, [.deleteCreated(url: url.standardizedFileURL)])
        XCTAssertNil(mockService.fileContent(at: url), "run 新建的文件应被删除")
    }

    func testRollback_multipleFiles_restoreAndDelete() async {
        makeAppState()
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原文A", written: "写入A")
        let createdURL = fileURL("b.md")
        mockService.setFile(createdURL, content: "新建B")
        ckpt.captureCreatedFile(url: createdURL)
        ckpt.markWritten(url: createdURL, content: "新建B")

        let actions = await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(mockService.fileContent(at: fileURL("a.md")), "原文A")
        XCTAssertNil(mockService.fileContent(at: createdURL))
    }

    func testRollback_skipsFileEditedByUserAfterRun() async {
        makeAppState()
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原始内容", written: "agent 写入")
        // run 结束后用户又手动改了该文件
        mockService.setFile(fileURL("a.md"), content: "用户后续编辑")

        let actions = await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(actions, [.skip(url: fileURL("a.md").standardizedFileURL, reason: .editedAfterRun)])
        XCTAssertEqual(mockService.fileContent(at: fileURL("a.md")), "用户后续编辑",
                       "用户编辑过的文件必须保持原样，绝不覆盖")
        XCTAssertTrue(ckpt.rollbackSummary?.contains("a.md") == true,
                      "跳过的文件必须在摘要里点名提示（断言语种无关：只查文件名，摘要是本地化的）")
    }

    func testRollback_skipsFileDeletedAfterRun() async {
        makeAppState()
        let url = fileURL("a.md")
        let ckpt = AgentRunCheckpoint()
        ckpt.captureBeforeWrite(url: url, knownContent: "原文")
        ckpt.markWritten(url: url, content: "写入")
        // 磁盘上已无此文件（用户 run 后自行删除）
        let actions = await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(actions, [.skip(url: url.standardizedFileURL, reason: .fileMissing)])
    }

    func testRollback_syncsOpenTabContent() async {
        makeAppState()
        let url = fileURL("a.md")
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原始内容", written: "agent 写入")
        // 文件正开在 tab 里（内容为 run 写入后的内容）
        let tab = EditorTab(url: url, content: "agent 写入", language: .markdown)
        state.openTabs = [tab]

        await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(tab.content, "原始内容", "打开的 tab 内容必须同步恢复")
        XCTAssertFalse(tab.isModified, "恢复后 tab 不应标为未保存")
    }

    func testRollback_createdFileOpenInTab_closesTab() async {
        makeAppState()
        let url = fileURL("new.md")
        mockService.setFile(url, content: "新建内容")
        let ckpt = AgentRunCheckpoint()
        ckpt.captureCreatedFile(url: url)
        ckpt.markWritten(url: url, content: "新建内容")
        let tab = EditorTab(url: url, content: "新建内容", language: .markdown)
        state.openTabs = [tab]

        await state.rollbackAgentRun(ckpt)
        XCTAssertNil(mockService.fileContent(at: url))
        XCTAssertTrue(state.openTabs.isEmpty, "被删除的新建文件对应的 tab 应一并关闭")
    }

    func testRollback_tabEditedByUser_skipsAndKeepsTabContent() async {
        makeAppState()
        let url = fileURL("a.md")
        // 磁盘是 run 写入内容，但 tab 里用户又改了（tab 内存优先于磁盘）
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原始内容", written: "agent 写入")
        let tab = EditorTab(url: url, content: "用户在 tab 里改了", language: .markdown)
        state.openTabs = [tab]

        let actions = await state.rollbackAgentRun(ckpt)
        XCTAssertEqual(actions, [.skip(url: url.standardizedFileURL, reason: .editedAfterRun)])
        XCTAssertEqual(tab.content, "用户在 tab 里改了")
        XCTAssertEqual(mockService.fileContent(at: url), "agent 写入")
    }

    func testRollback_isIdempotent() async {
        makeAppState()
        let ckpt = stubWrittenCheckpoint(name: "a.md", original: "原始内容", written: "agent 写入")
        _ = await state.rollbackAgentRun(ckpt)
        let second = await state.rollbackAgentRun(ckpt)
        XCTAssertTrue(second.isEmpty, "重复回滚应为 no-op")
        XCTAssertEqual(mockService.fileContent(at: fileURL("a.md")), "原始内容")
    }

    func testRollback_deleteFailure_keepsFileAndAllowsRetry() async {
        makeAppState()
        let url = fileURL("new.md")
        mockService.setFile(url, content: "新建内容")
        let ckpt = AgentRunCheckpoint()
        ckpt.captureCreatedFile(url: url)
        ckpt.markWritten(url: url, content: "新建内容")
        mockService.removeError = CocoaError(.fileWriteNoPermission)

        _ = await state.rollbackAgentRun(ckpt)

        XCTAssertEqual(mockService.fileContent(at: url), "新建内容", "删除失败不得伪报成功")
        XCTAssertFalse(ckpt.isRolledBack, "写盘失败时必须保留重试入口")

        mockService.removeError = nil
        _ = await state.rollbackAgentRun(ckpt)
        XCTAssertNil(mockService.fileContent(at: url))
        XCTAssertTrue(ckpt.isRolledBack)
    }
}
