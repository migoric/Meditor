import XCTest
@testable import MEditor

// MARK: - AgentWriteReviewTests
//
// 改前 diff 审阅（写操作默认主流程）单测：
//   - write_document / patch_document 默认先走 reviewFileWrite 审阅，审阅后的合并内容才落盘
//   - 全部拒绝 / 用户取消（review 返回 nil）→ 不落盘、不抛错，返回模型可读的取消文案
//   - run 级「全部允许」与 MCP 无头（isFileWriteAllowedForRun=true）直通，不进审阅
//   - 协议默认实现退化为 Bool 确认条语义（不破坏未接入审阅 UI 的 conformer）
//   - AppStateDocumentAdapter：默认进 DiffReviewState 审阅态；「自动应用」开关打开时退回确认条
// CI 为英文 locale：断言只依赖 [OK]/[!] 标记与写入内容，不写死中文文案。

@MainActor
final class AgentWriteReviewTests: XCTestCase {

    // MARK: - Setup

    var ctx: MockAgentContext!

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        // 段落以空行分隔（ParagraphDiffer 按空行切段），方便精确断言合并结果
        ctx.currentDocument     = "Alpha\n\nBeta\n\nGamma"
        ctx.currentDocumentName = "doc.md"
        ctx.addFile("notes.md", content: "Alpha\n\nBeta")
    }

    // MARK: - 默认主流程：写操作先进审阅，审阅后的内容才落盘

    func testWriteDocument_default_goesThroughReviewBeforeWrite() async throws {
        ctx.reviewWriteHandler = { _, proposed in proposed }   // 用户全部接受
        let result = try await WriteDocumentTool().execute(
            arguments: ["filename": .string("notes.md"),
                        "content": .string("Alpha\n\nBETA")],
            context: ctx
        )
        XCTAssertEqual(ctx.reviewedWritePreviews.count, 1, "写入前应先进入一次写审阅")
        XCTAssertTrue(ctx.confirmedWrites.isEmpty, "走审阅后不应再弹确认条")
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.writtenFiles.last?.content, "Alpha\n\nBETA", "确认后落盘")
    }

    func testWriteDocument_partialAccept_writesMergedContent() async throws {
        // 模拟用户逐块审阅后接受的合并结果（≠ 模型提议的全文）
        ctx.reviewWriteHandler = { _, _ in "Alpha\n\nBETA\n\nGamma\n\n用户保留的尾巴" }
        let result = try await WriteDocumentTool().execute(
            arguments: ["content": .string("Alpha\n\nBETA\n\nGAMMA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBETA\n\nGamma\n\n用户保留的尾巴",
                       "落盘的必须是审阅后的合并内容，不是模型原始提议")
    }

    func testPatchDocument_reviewApproved_writesMergedNotRawPatch() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            XCTAssertTrue(proposed.contains("BETA"), "审阅收到的应是 patch 预演后的完整内容")
            return proposed   // 全部接受
        }
        let result = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Beta"), "replace": .string("BETA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBETA\n\nGamma")
        XCTAssertTrue(ctx.patchCalls.isEmpty, "审阅路径应写合并结果，不再重放 patchDocument")
    }

    func testPatchDocument_fileTarget_reviewApproved_writesMergedContent() async throws {
        ctx.reviewWriteHandler = { _, proposed in proposed }
        let result = try await PatchDocumentTool().execute(
            arguments: ["filename": .string("notes.md"),
                        "find": .string("Beta"), "replace": .string("BETA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.files["notes.md"], "Alpha\n\nBETA")
        XCTAssertTrue(ctx.patchCalls.isEmpty)
    }

    // MARK: - 全部拒绝 / 取消：不落盘、不抛错

    func testWriteDocument_reviewRejected_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, _ in nil }   // 用户全部拒绝 / 关闭审阅
        let result = try await WriteDocumentTool().execute(
            arguments: ["filename": .string("notes.md"), "content": .string("x")],
            context: ctx
        )
        XCTAssertEqual(ctx.files["notes.md"], "Alpha\n\nBeta", "拒绝后原文件不应被改动")
        XCTAssertTrue(ctx.writtenFiles.isEmpty)
        XCTAssertTrue(result.contains("[!]"), "应返回模型可读的取消文案，而非静默成功")
    }

    func testPatchDocument_reviewRejected_doesNotPatch() async throws {
        ctx.reviewWriteHandler = { _, _ in nil }
        let result = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Beta"), "replace": .string("BETA")],
            context: ctx
        )
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
        XCTAssertTrue(ctx.writtenContents.isEmpty)
        XCTAssertTrue(result.contains("[!]"))
    }

    // MARK: - patch 预演：无匹配不进审阅，直接报错

    func testPatchDocument_noMatch_failsBeforeReview() async throws {
        let result = try await PatchDocumentTool().execute(
            arguments: ["find": .string("NotExist"), "replace": .string("x")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertTrue(ctx.reviewedWritePreviews.isEmpty, "find 无匹配不应进入审阅态")
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
    }

    // MARK: - tab 锁定：审阅期间切 tab → 绝不写进别的文档（对齐 SlashAI sourceTabID 模式）

    func testWriteDocument_tabSwitchedDuringReview_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            self.ctx.currentTabID = UUID()   // 模拟审阅挂起期间用户切到别的 tab
            return proposed             // 用户随后点「全部接受」
        }
        let result = try await WriteDocumentTool().execute(
            arguments: ["content": .string("重写内容")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"), "tab 已切换应返回模型可读的放弃文案")
        XCTAssertTrue(ctx.writtenContents.isEmpty, "tab 已切换时绝不写入")
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
    }

    func testPatchDocument_tabSwitchedDuringReview_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            self.ctx.currentTabID = UUID()
            return proposed
        }
        let result = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Beta"), "replace": .string("BETA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertTrue(ctx.writtenContents.isEmpty, "tab 已切换时绝不写入")
        XCTAssertTrue(ctx.patchCalls.isEmpty)
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
    }

    func testPatchDocument_tabSwitchedBeforeDirectPatch_doesNotPatch() async throws {
        // 写前内容不可得 → 退化确认条路径同样受 tab 锁定保护
        ctx.currentDocument = nil
        ctx.writeConfirmResult = true
        ctx.confirmWriteHook = { self.ctx.currentTabID = UUID() }   // 确认条挂起期间切 tab
        let result = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Beta"), "replace": .string("BETA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertTrue(ctx.patchCalls.isEmpty, "tab 已切换时精准 patch 也不得执行")
    }

    func testWriteDocument_tabUnchanged_stillWrites() async throws {
        // 回归防护：tab 未切换（currentTabID 不变）时正常落盘
        ctx.reviewWriteHandler = { _, proposed in proposed }
        let result = try await WriteDocumentTool().execute(
            arguments: ["content": .string("Alpha\n\nBETA")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBETA")
    }

    // MARK: - 取消检查：审阅批准返回时 run 已被取消（Stop）→ 不落盘

    func testWriteDocument_cancelledDuringReview_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            // 模拟：diff 审阅挂起期间用户点了 Stop（Task 已取消），随后才点「全部接受」
            withUnsafeCurrentTask { $0?.cancel() }
            return proposed
        }
        do {
            _ = try await WriteDocumentTool().execute(
                arguments: ["content": .string("重写内容")], context: ctx)
            XCTFail("已取消的 run 应抛 CancellationError 走向收尾，不应照常写入")
        } catch is CancellationError {
            // 预期：Runner 按取消收尾，不包装成 tool error
        }
        XCTAssertTrue(ctx.writtenContents.isEmpty, "已取消后审阅批准也不得落盘")
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
    }

    func testPatchDocument_cancelledDuringReview_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            withUnsafeCurrentTask { $0?.cancel() }
            return proposed
        }
        do {
            _ = try await PatchDocumentTool().execute(
                arguments: ["find": .string("Beta"), "replace": .string("BETA")], context: ctx)
            XCTFail("已取消的 run 应抛 CancellationError")
        } catch is CancellationError {
            // 预期
        }
        XCTAssertTrue(ctx.writtenContents.isEmpty)
        XCTAssertEqual(ctx.currentDocument, "Alpha\n\nBeta\n\nGamma")
    }

    // MARK: - run 级「全部允许」：直通，不进审阅

    func testAllowAllForRun_skipsReview() async throws {
        ctx.fileWriteAllowedForRun = true
        _ = try await WriteDocumentTool().execute(
            arguments: ["content": .string("new body")], context: ctx)
        _ = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Alpha"), "replace": .string("A")], context: ctx)
        XCTAssertTrue(ctx.reviewedWritePreviews.isEmpty, "全部允许后不应再进审阅")
        XCTAssertTrue(ctx.confirmedWrites.isEmpty)
        XCTAssertEqual(ctx.writtenContents.count, 1)
        XCTAssertEqual(ctx.patchCalls.count, 1, "直通路径仍走精准 patch")
    }

    // MARK: - MCP 无头：直通落盘（isFileWriteAllowedForRun 恒 true，无 UI 可挂起）

    func testMCPHeadless_writeDocument_directlyLands() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-review-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let headless = MCPHeadlessContext(workspaceRoot: dir)
        XCTAssertTrue(headless.isFileWriteAllowedForRun, "无头环境没有 UI，写确认恒放行")

        let result = try await WriteDocumentTool().execute(
            arguments: ["filename": .string("out.md"), "content": .string("# Hi")],
            context: headless
        )
        XCTAssertTrue(result.contains("[OK]"))
        let written = try String(contentsOf: dir.appendingPathComponent("out.md"), encoding: .utf8)
        XCTAssertEqual(written, "# Hi", "无头路径应直接落盘，不被默认预览卡住")
    }

    // MARK: - 协议默认实现：未接入审阅 UI 的 conformer 退化为 Bool 确认语义

    private final class MinimalShellContext: ShellContext {
        var confirmResult = true
        func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool { true }
        func confirmFileWrite(_ path: String, summary: String) async -> Bool { confirmResult }
        func isCommandApproved(_ key: String) -> Bool { false }
        func markCommandApproved(_ key: String) {}
        var allowedCommandPatterns: [String]? { nil }
        func setAllowedCommandPatterns(_ patterns: [String]?) {}
    }

    func testDefaultReviewFileWrite_forwardsToConfirm() async {
        let shell = MinimalShellContext()
        let preview = WriteDiffPreviewBuilder.make(
            path: "a.md", summary: "s", base: .newFile, newContent: "body")
        let approved = await shell.reviewFileWrite(preview, base: .newFile, newContent: "body")
        XCTAssertEqual(approved, "body", "确认通过应原样返回提议内容")
        shell.confirmResult = false
        let rejected = await shell.reviewFileWrite(preview, base: .newFile, newContent: "body")
        XCTAssertNil(rejected, "确认拒绝应返回 nil（不落盘）")
    }

    // MARK: - DiffReviewState.onCancel（审阅放弃回调）

    func testDiffReview_dismiss_firesOnCancel() {
        let dr = DiffReviewState()
        var cancelled = false
        dr.present(original: "a\n\nb", modified: "a\n\nB", onFinalize: { _ in })
        dr.onCancel = { cancelled = true }   // present 会重置闭包，必须在之后注入
        XCTAssertTrue(dr.isPresented)
        dr.dismiss()
        XCTAssertTrue(cancelled, "用户放弃审阅必须触发 onCancel（agent 工具靠它恢复挂起）")
        XCTAssertFalse(dr.isPresented)
    }

    func testDiffReview_skipAll_firesOnCancelNotFinalize() {
        let dr = DiffReviewState()
        var cancelled = false
        var finalized = false
        dr.present(original: "a\n\nb", modified: "a\n\nB", onFinalize: { _ in finalized = true })
        dr.onCancel = { cancelled = true }
        dr.skipAll()
        XCTAssertTrue(cancelled)
        XCTAssertFalse(finalized, "全部跳过不应触发写回")
    }

    // MARK: - AppStateDocumentAdapter：审阅态接线 + 自动应用开关

    private func makeAdapter(_ appState: AppState) -> AppStateDocumentAdapter {
        AppStateDocumentAdapter(appState: appState, fileRepo: DefaultAgentFileRepository({ nil }))
    }

    /// 轮询等待条件成立（审阅态出现 / 确认条挂起），避免 sleep 定长等待的脆弱性
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待条件超时", file: file, line: line)
    }

    func testAdapter_default_presentsDiffReview_acceptAllReturnsMerged() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")

        async let reviewed = adapter.reviewFileWrite(
            preview, base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")
        await waitFor { appState.diffReview.isPresented }
        XCTAssertEqual(appState.diffReview.diffs.count, 1, "大改动按块拆分展示")

        appState.diffReview.acceptAll()
        let merged = await reviewed
        XCTAssertEqual(merged, "Alpha\n\nBETA", "全部接受后应返回合并内容")
        XCTAssertFalse(appState.diffReview.isPresented)
    }

    func testAdapter_skipAll_returnsNil_nothingToWrite() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")

        async let reviewed = adapter.reviewFileWrite(
            preview, base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")
        await waitFor { appState.diffReview.isPresented }

        appState.diffReview.skipAll()   // 全部拒绝 = 用户主动取消
        let result = await reviewed
        XCTAssertNil(result, "全部拒绝应返回 nil（不落盘、不报错）")
        XCTAssertFalse(appState.diffReview.isPresented)
    }

    func testAdapter_acceptingNothing_individually_alsoCancels() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")

        async let reviewed = adapter.reviewFileWrite(
            preview, base: .existing("Alpha\n\nBeta"), newContent: "Alpha\n\nBETA")
        await waitFor { appState.diffReview.isPresented }

        // 逐块全部跳过：合并结果 == 写前内容 → 视为取消，不落盘
        for diff in appState.diffReview.diffs { appState.diffReview.skip(diff.id) }
        let result = await reviewed
        XCTAssertNil(result, "一处都未接受等同于全部拒绝")
    }

    func testAdapter_acceptingNothing_trailingNewline_alsoCancels() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        // 行尾换行会让 mergedContent() 的段落归一化结果 != original，
        // 回归防护：拒绝判定必须看 diff 状态，不能比字符串
        let base = "Alpha\n\nBeta\n"
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing(base), newContent: "Alpha\n\nBETA\n")

        async let reviewed = adapter.reviewFileWrite(
            preview, base: .existing(base), newContent: "Alpha\n\nBETA\n")
        await waitFor { appState.diffReview.isPresented }

        for diff in appState.diffReview.diffs { appState.diffReview.skip(diff.id) }
        let result = await reviewed
        XCTAssertNil(result, "带行尾换行时逐块全部拒绝也必须视为取消")
    }

    func testAdapter_acceptAll_passesThroughModelContentByteFaithfully() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        // 模型输出含连续空行/行尾空格：全部接受时必须字节保真直通，
        // 不经过 mergedContent() 的段落归一化
        let proposed = "Alpha\n\n\n\nBETA  \n"
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha\n\nBeta\n"), newContent: proposed)

        async let reviewed = adapter.reviewFileWrite(
            preview, base: .existing("Alpha\n\nBeta\n"), newContent: proposed)
        await waitFor { appState.diffReview.isPresented }

        appState.diffReview.acceptAll()
        let result = await reviewed
        XCTAssertEqual(result, proposed, "全部接受应直通模型原文，不做归一化")
    }

    func testAdapter_autoApplySetting_fallsBackToConfirmBar() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = true
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha"), newContent: "Beta")

        async let reviewed = adapter.reviewFileWrite(preview, base: .existing("Alpha"), newContent: "Beta")
        await waitFor { appState.aiConversation.pendingWrite != nil }
        XCTAssertFalse(appState.diffReview.isPresented, "自动应用开关打开时不应进入审阅态")

        appState.aiConversation.pendingWrite?.approve()
        let result = await reviewed
        XCTAssertEqual(result, "Beta", "确认条批准后原样返回提议内容")
    }

    func testAdapter_cancelPendingWriteConfirmation_resumesReviewAsCancelled() async throws {
        let settings = AppSettings.shared
        let oldValue = settings.aiAgentAutoApplyWrites
        settings.aiAgentAutoApplyWrites = false
        defer { settings.aiAgentAutoApplyWrites = oldValue }

        let appState = AppState()
        let adapter = makeAdapter(appState)
        let preview = WriteDiffPreviewBuilder.make(
            path: "doc.md", summary: "s", base: .existing("Alpha"), newContent: "Beta")

        async let reviewed = adapter.reviewFileWrite(preview, base: .existing("Alpha"), newContent: "Beta")
        await waitFor { appState.diffReview.isPresented }

        // Runner 结束/超时/用户停止：挂起的审阅必须恢复（否则工具 continuation 泄漏）
        adapter.cancelPendingWriteConfirmation()
        let result = await reviewed
        XCTAssertNil(result)
        XCTAssertFalse(appState.diffReview.isPresented)
    }

    func testAdapter_largeDocumentDuringInitialLoad_patchKeepsFullSuffix() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("large.md")
        let original = String(repeating: "a", count: 70_000) + "TARGET" + String(repeating: "z", count: 10_000)
        try original.write(to: url, atomically: true, encoding: .utf8)
        let appState = AppState()
        let tab = EditorTab(url: url, content: "", language: .markdown, awaitingInitialContent: true)
        appState.openTabs = [tab]
        appState.selectedTabID = tab.id
        let repo = DefaultAgentFileRepository { temp }
        let adapter = AppStateDocumentAdapter(appState: appState, fileRepo: repo)

        _ = try adapter.patchDocument(find: "TARGET", replace: "REPLACED", all: false)

        XCTAssertEqual(tab.content, original.replacingOccurrences(of: "TARGET", with: "REPLACED"),
                       "加载中的大文档必须用完整原文 patch，不得截断后缀")
    }

    func testWriteFile_contentChangesDuringReview_doesNotOverwriteNewEdit() async throws {
        ctx.reviewWriteHandler = { _, proposed in
            self.ctx.files["notes.md"] = "用户在确认期间的新编辑"
            return proposed
        }
        let result = try await WriteFileTool().execute(
            arguments: ["filename": .string("notes.md"), "content": .string("agent 全量版本")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertEqual(ctx.files["notes.md"], "用户在确认期间的新编辑")
        XCTAssertTrue(ctx.writtenFiles.isEmpty, "审阅期间内容已变化时必须放弃覆盖")
    }

    func testWriteFile_originalReadFails_doesNotOverwrite() async throws {
        ctx.fileContentError = CocoaError(.fileReadNoPermission)
        let result = try await WriteFileTool().execute(
            arguments: ["filename": .string("notes.md"), "content": .string("agent 全量版本")],
            context: ctx
        )
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertEqual(ctx.files["notes.md"], "Alpha\n\nBeta")
        XCTAssertTrue(ctx.writtenFiles.isEmpty)
    }

    // MARK: - 设置开关

    func testAutoApplyWritesSetting_persistsRoundtrip() {
        let s = AppSettings.shared
        let old = s.aiAgentAutoApplyWrites
        s.aiAgentAutoApplyWrites = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "MEditor.aiAgentAutoApplyWrites"))
        s.aiAgentAutoApplyWrites = old
        XCTAssertEqual(s.aiAgentAutoApplyWrites, old)
    }
}
