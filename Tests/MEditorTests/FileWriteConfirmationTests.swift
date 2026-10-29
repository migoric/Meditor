import XCTest
@testable import MEditor

// MARK: - FileWriteConfirmationTests
//
// 文件写入确认（agent 运行中的写操作需用户确认）单测：
//   - 协议默认实现**拒绝**（fail-closed：忘了覆写的 conformer 宁可写不了，也不能静默落盘）
//   - 拒绝时工具不执行，且返回模型可读的错误文案
//   - run 级「全部允许」后，同 run 后续写不再挂起确认
// mock 模式参照 AgentToolTests.swift（MockAgentContext spy + 结果注入）。

@MainActor
final class FileWriteConfirmationTests: XCTestCase {

    // MARK: - Setup

    var ctx: MockAgentContext!

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        ctx.currentDocument     = "Hello world\nSecond line\nThird line"
        ctx.currentDocumentName = "doc.md"
        ctx.addFile("notes.md", content: "# Notes\n\nSome notes here.\nMore content.")
    }

    // MARK: - 协议默认实现（ShellContext extension）

    /// 最小 ShellContext 实现：不实现任何写入确认方法，全部走协议扩展默认值。
    private final class MinimalShellContext: ShellContext {
        func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool { true }
        func isCommandApproved(_ key: String) -> Bool { false }
        func markCommandApproved(_ key: String) {}
        var allowedCommandPatterns: [String]? { nil }
        func setAllowedCommandPatterns(_ patterns: [String]?) {}
    }

    func testDefaultConfirmFileWrite_denies() async {
        let shell = MinimalShellContext()
        let allowed = await shell.confirmFileWrite("docs/a.md", summary: "写入 docs/a.md（约 3 行）")
        XCTAssertFalse(
            allowed,
            "协议扩展的默认实现必须拒绝：默认放行会让「忘了覆写」的 conformer 静默改用户文档（iOS 曾因此中招）"
        )
        XCTAssertFalse(shell.isFileWriteAllowedForRun, "默认无「全部允许」状态")
        shell.cancelPendingWriteConfirmation()   // 默认 no-op，不应崩溃
    }

    /// 反向验证上面那条不是「纸面断言」：默认值确实曾经是 `true`，
    /// 若哪天有人改回去，这个用例会立刻变红。
    func testDefaultConfirmFileWrite_doesNotSilentlyAllow() async {
        let shell = MinimalShellContext()
        let preview = FileWritePreview(path: "docs/b.md", summary: "写入 docs/b.md", diff: .hunks([]))
        let reviewed = await shell.reviewFileWrite(
            preview,
            base: .newFile,
            newContent: "new"
        )
        XCTAssertNil(reviewed, "默认 reviewFileWrite 必须退化为「拒绝」，不能返回内容")
    }

    // MARK: - 用户确认流程（每个写工具都会挂起确认）

    func testWriteDocument_asksConfirmationWithSummary() async throws {
        let tool = WriteDocumentTool()
        let result = try await tool.execute(
            arguments: ["filename": .string("new.md"), "content": .string("a\nb\nc")],
            context: ctx
        )
        XCTAssertEqual(ctx.confirmedWrites.count, 1, "写入前应挂起一次确认")
        XCTAssertEqual(ctx.confirmedWrites[0].path, "new.md")
        XCTAssertTrue(ctx.confirmedWrites[0].summary.contains("约 3 行"), "summary 应包含行数信息")
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.writtenFiles.count, 1, "允许后应真正写入")
    }

    func testPatchDocument_asksConfirmation() async throws {
        let tool = PatchDocumentTool()
        _ = try await tool.execute(
            arguments: ["find": .string("Hello world"), "replace": .string("Hi there")],
            context: ctx
        )
        XCTAssertEqual(ctx.confirmedWrites.count, 1, "patch 前应挂起一次确认")
        XCTAssertEqual(ctx.confirmedWrites[0].path, "doc.md", "当前文档 patch 的 path 应为文档名")
        // 确认（审阅）通过后写合并后的完整内容，不重放 patchDocument
        XCTAssertEqual(ctx.writtenContents.count, 1)
        XCTAssertEqual(ctx.writtenContents[0], "Hi there\nSecond line\nThird line")
    }

    func testCreateFile_asksConfirmation() async throws {
        let tool = CreateFileTool()
        _ = try await tool.execute(
            arguments: ["filename": .string("created.md"), "content": .string("# New")],
            context: ctx
        )
        XCTAssertEqual(ctx.confirmedWrites.count, 1)
        XCTAssertEqual(ctx.createdFiles.count, 1)
    }

    func testWriteFile_asksConfirmation() async throws {
        let tool = WriteFileTool()
        _ = try await tool.execute(
            arguments: ["filename": .string("out.md"), "content": .string("body")],
            context: ctx
        )
        XCTAssertEqual(ctx.confirmedWrites.count, 1)
        XCTAssertEqual(ctx.writtenFiles.count, 1)
    }

    /// insert_at_cursor 曾经是唯一没有闸门的写工具：模型按工具描述（"Prefer this over
    /// write_document …"）优先选它，于是「往文档里加一段」这个最常见的请求绕过了审批。
    func testInsertAtCursor_asksConfirmation() async throws {
        let tool = InsertAtCursorTool()
        let result = try await tool.execute(
            arguments: ["text": .string("补充说明\n第二行")],
            context: ctx
        )
        XCTAssertEqual(ctx.confirmedWrites.count, 1, "插入前应挂起一次确认")
        XCTAssertEqual(ctx.confirmedWrites[0].path, "doc.md")
        XCTAssertTrue(ctx.confirmedWrites[0].summary.contains("插入"),
                      "summary 应写明这是一次插入")
        XCTAssertTrue(ctx.confirmedWrites[0].summary.contains("补充说明"),
                      "summary 应带上插入内容的一句话预览")
        XCTAssertEqual(ctx.insertedTexts.count, 1, "允许后应真正插入")
        XCTAssertTrue(result.contains("[OK]"))
    }

    func testInsertAtCursor_rejected_doesNotInsert() async throws {
        ctx.writeConfirmResult = false
        let tool = InsertAtCursorTool()
        let result = try await tool.execute(
            arguments: ["text": .string("不该落进文档的内容")],
            context: ctx
        )
        XCTAssertTrue(ctx.insertedTexts.isEmpty, "拒绝后不应插入")
        XCTAssertTrue(result.contains("[!]") && result.contains("拒绝"),
                      "拒绝时应返回模型可读的文案，而非静默成功")
    }

    /// 本 run 已「全部允许」时，插入与其他写工具一样不再逐次确认。
    func testInsertAtCursor_allowAllForRun_skipsConfirmation() async throws {
        ctx.fileWriteAllowedForRun = true
        let tool = InsertAtCursorTool()
        _ = try await tool.execute(arguments: ["text": .string("批量写入")], context: ctx)
        XCTAssertTrue(ctx.confirmedWrites.isEmpty, "「本次运行全部允许」后不应再挂确认")
        XCTAssertEqual(ctx.insertedTexts.count, 1)
    }

    /// 确认条摘要压成单行并截断，避免长文本把面板里的确认条撑爆。
    func testInsertAtCursor_autoApproved_skipsConfirmation() async throws {
        ctx.preApprovedWritePaths = ["doc.md"]
        _ = try await InsertAtCursorTool().execute(arguments: ["text": .string("定时任务插入")], context: ctx)
        XCTAssertTrue(ctx.confirmedWrites.isEmpty, "autoApprove 命中时不得挂起确认")
        XCTAssertEqual(ctx.insertedTexts.count, 1)
    }

    func testInsertAtCursor_tabChangesDuringConfirmation_doesNotInsert() async throws {
        ctx.confirmWriteHook = { self.ctx.currentTabID = UUID() }
        let result = try await InsertAtCursorTool().execute(arguments: ["text": .string("错位内容")], context: ctx)
        XCTAssertTrue(result.contains("[!]"))
        XCTAssertTrue(ctx.insertedTexts.isEmpty, "确认期间切 Tab 后不得插入新文档")
    }

    func testInsertAtCursor_snippetIsSingleLineAndTruncated() {
        XCTAssertEqual(InsertAtCursorTool.snippet("a\nb\nc"), "a b c")
        let long = String(repeating: "长", count: 100)
        let snippet = InsertAtCursorTool.snippet(long)
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertEqual(snippet.count, 61, "60 字符 + 省略号")
    }

    // MARK: - 拒绝：工具不执行，返回模型可读错误

    func testWriteDocument_rejected_doesNotWrite() async throws {
        ctx.writeConfirmResult = false
        let tool = WriteDocumentTool()
        let result = try await tool.execute(
            arguments: ["content": .string("overwritten")],
            context: ctx
        )
        XCTAssertTrue(ctx.writtenContents.isEmpty, "拒绝后不应写入当前文档")
        XCTAssertTrue(result.contains("[!]") && result.contains("拒绝"),
                      "拒绝时应返回模型可读的错误文案，而非静默成功")
    }

    func testPatchDocument_rejected_doesNotPatch() async throws {
        ctx.writeConfirmResult = false
        let tool = PatchDocumentTool()
        let result = try await tool.execute(
            arguments: ["filename": .string("notes.md"),
                        "find": .string("Some notes"), "replace": .string("x")],
            context: ctx
        )
        XCTAssertTrue(ctx.patchCalls.isEmpty, "拒绝后不应执行 patch")
        XCTAssertTrue(result.contains("[!]") && result.contains("拒绝"))
    }

    func testCreateFile_rejected_doesNotCreate() async throws {
        ctx.writeConfirmResult = false
        let tool = CreateFileTool()
        let result = try await tool.execute(
            arguments: ["filename": .string("created.md")],
            context: ctx
        )
        XCTAssertTrue(ctx.createdFiles.isEmpty, "拒绝后不应创建文件")
        XCTAssertTrue(result.contains("[!]") && result.contains("拒绝"))
    }

    func testWriteFile_rejected_doesNotWrite() async throws {
        ctx.writeConfirmResult = false
        let tool = WriteFileTool()
        let result = try await tool.execute(
            arguments: ["filename": .string("out.md"), "content": .string("body")],
            context: ctx
        )
        XCTAssertTrue(ctx.writtenFiles.isEmpty, "拒绝后不应写文件")
        XCTAssertTrue(result.contains("[!]") && result.contains("拒绝"))
    }

    // MARK: - run 级「全部允许」：后续写不再挂起

    func testAllowAllForRun_skipsConfirmationForSubsequentWrites() async throws {
        ctx.fileWriteAllowedForRun = true   // 模拟用户已点「本次运行全部允许」
        let write = WriteFileTool()
        let r1 = try await write.execute(
            arguments: ["filename": .string("a.md"), "content": .string("1")], context: ctx)
        let r2 = try await write.execute(
            arguments: ["filename": .string("b.md"), "content": .string("2")], context: ctx)
        XCTAssertTrue(ctx.confirmedWrites.isEmpty, "全部允许后不应再挂起确认")
        XCTAssertEqual(ctx.writtenFiles.count, 2, "写操作应直接放行执行")
        XCTAssertTrue(r1.contains("[OK]") && r2.contains("[OK]"))
    }

    func testAllowAllForRun_alsoSkipsDocumentAndPatch() async throws {
        ctx.fileWriteAllowedForRun = true
        _ = try await WriteDocumentTool().execute(
            arguments: ["content": .string("new body")], context: ctx)
        _ = try await PatchDocumentTool().execute(
            arguments: ["find": .string("Hello"), "replace": .string("Hi")], context: ctx)
        XCTAssertTrue(ctx.confirmedWrites.isEmpty)
        XCTAssertEqual(ctx.writtenContents.count, 1)
        XCTAssertEqual(ctx.patchCalls.count, 1)
    }

    // MARK: - create_directory 不拦确认

    func testCreateDirectory_doesNotAskConfirmation() async throws {
        let tool = CreateDirectoryTool()
        let result = try await tool.execute(
            arguments: ["path": .string("docs/sub")], context: ctx)
        XCTAssertTrue(ctx.confirmedWrites.isEmpty, "创建空目录不应触发写入确认")
        XCTAssertTrue(result.contains("[OK]"))
        XCTAssertEqual(ctx.createdDirectories, ["docs/sub"])
    }

    // MARK: - PendingWrite 模型（幂等 / approveAll 语义）

    func testPendingWrite_rejectIsIdempotent() {
        var responses: [Bool] = []
        var allowAllCalled = false
        let pending = PendingWrite(
            path: "a.md", summary: "写入 a.md",
            allowAllForRun: { allowAllCalled = true },
            respond: { responses.append($0) }
        )
        pending.reject()
        pending.reject()      // 第二次应为 no-op（与 Runner/cancelStreaming 双兜底对齐）
        pending.approve()
        XCTAssertEqual(responses, [false], "reject 应幂等，先到先生效")
        XCTAssertFalse(allowAllCalled)
    }

    func testPendingWrite_approveAllSetsFlagThenApproves() {
        var responses: [Bool] = []
        var allowAllCalled = false
        let pending = PendingWrite(
            path: "a.md", summary: "写入 a.md",
            allowAllForRun: { allowAllCalled = true },
            respond: { responses.append($0) }
        )
        pending.approveAll()
        XCTAssertTrue(allowAllCalled, "approveAll 应先置位 run 级开关")
        XCTAssertEqual(responses, [true], "approveAll 同时放行当前写")
    }
}
