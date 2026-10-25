import XCTest
@testable import MEditor

/// 结构工具的行为测试（走 MockAgentContext，不碰磁盘）。
///
/// 这里钉住的是**写入纪律**，不是文本处理（那部分在 MarkdownStructureTests /
/// HTMLStructureTests 里）：每个写类工具都必须进写前审阅、都必须带 tab 锁定、
/// 遇到歧义必须放弃而不是猜。
@MainActor
final class DocumentStructureToolTests: XCTestCase {

    var ctx: MockAgentContext!

    private let markdown = """
    # 一、背景

    背景正文。

    ## 小结

    甲的结论。

    # 二、实现

    ## 小结

    乙的结论。
    """

    private let html = """
    <html><head><style>body { color: #333; }</style></head>
    <body><main>
    <section id="intro"><h2>引言</h2><p>甲的正文</p></section>
    <section id="data"><h2>数据</h2><p>乙的正文</p></section>
    </main></body></html>
    """

    override func setUp() {
        super.setUp()
        ctx = MockAgentContext()
        ctx.currentDocument = markdown
        ctx.currentDocumentName = "doc.md"
        ctx.addFile("notes.md", content: "# 甲\n\n旧\n\n# 乙\n\n旧乙")
        ctx.reviewWriteHandler = { _, proposed in proposed }
    }

    // MARK: - 只读工具

    func test_outlineDocument_listsSections() async throws {
        let result = try await OutlineDocumentTool().execute(arguments: [:], context: ctx)
        XCTAssertTrue(result.contains("4 节"), result)
        XCTAssertTrue(result.contains("#1 ·"), result)
        XCTAssertTrue(result.contains("小结"), result)
        XCTAssertTrue(result.contains("read_section"), "大纲末尾要告诉模型下一句怎么读")
    }

    func test_readSection_readsOnlyThatSection() async throws {
        let result = try await ReadSectionTool().execute(
            arguments: ["section": .string("#4")], context: ctx)
        XCTAssertTrue(result.contains("乙的结论"), result)
        XCTAssertFalse(result.contains("甲的结论"), "读一节不该把别的节也带回来")
        XCTAssertFalse(result.contains("# 一、背景"))
    }

    func test_readSection_duplicateTitle_reportsAmbiguity() async throws {
        let result = try await ReadSectionTool().execute(
            arguments: ["section": .string("小结")], context: ctx)
        XCTAssertTrue(result.contains("匹配到 2 节"), result)
        XCTAssertTrue(result.contains("一、背景 > 小结"), "要把候选的完整路径列出来：\(result)")
        XCTAssertTrue(result.contains("二、实现 > 小结"), result)
    }

    // MARK: - rewrite_section：走审阅、保标题、不越界

    func test_rewriteSection_writesThroughReviewAndKeepsHeading() async throws {
        var reviewed: [String] = []
        ctx.reviewWriteHandler = { _, proposed in reviewed.append(proposed); return proposed }

        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#2"), "content": .string("甲的新结论。")],
            context: ctx)

        XCTAssertTrue(result.contains("[OK]"), result)
        XCTAssertEqual(ctx.reviewedWritePreviews.count, 1, "写类结构工具必须进写前审阅")
        let written = try XCTUnwrap(ctx.writtenContents.last)
        XCTAssertTrue(written.contains("## 小结\n\n甲的新结论。"), "标题行默认保留：\(written)")
        XCTAssertTrue(written.contains("乙的结论"), "别的节一字不动")
        XCTAssertEqual(reviewed.first, written, "审阅看到的就是将要落盘的内容")
    }

    func test_rewriteSection_reviewRejected_doesNotWrite() async throws {
        ctx.reviewWriteHandler = { _, _ in nil }
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#1"), "content": .string("新内容")], context: ctx)
        XCTAssertTrue(result.contains("[!]"), result)
        XCTAssertTrue(ctx.writtenContents.isEmpty)
    }

    func test_rewriteSection_emptyContent_isRefused() async throws {
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#1"), "content": .string("   \n  ")], context: ctx)
        XCTAssertTrue(result.contains("[!]"), result)
        XCTAssertTrue(ctx.writtenContents.isEmpty, "空内容不落盘——避免静默删节")
        XCTAssertTrue(ctx.reviewedWritePreviews.isEmpty)
    }

    func test_rewriteSection_ambiguousTitle_writesNothing() async throws {
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("小结"), "content": .string("x")], context: ctx)
        XCTAssertTrue(result.contains("匹配到 2 节"), result)
        XCTAssertTrue(ctx.reviewedWritePreviews.isEmpty, "歧义时连审阅都不该开")
        XCTAssertTrue(ctx.writtenContents.isEmpty)
    }

    func test_rewriteSection_filenameTarget_writesThatFile() async throws {
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#2"),
                        "content": .string("新乙"),
                        "filename": .string("notes.md")],
            context: ctx)
        XCTAssertTrue(result.contains("[OK]"), result)
        XCTAssertEqual(ctx.writtenFiles.last?.content, "# 甲\n\n旧\n\n# 乙\n\n新乙")
        XCTAssertTrue(ctx.writtenContents.isEmpty, "带 filename 时不该动当前文档")
    }

    func test_rewriteSection_tabSwitchedDuringReview_abortsWrite() async throws {
        ctx.reviewWriteHandler = { [weak ctx] _, proposed in
            ctx?.currentTabID = UUID()   // 审阅挂起期间用户切了 tab
            return proposed
        }
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#1"), "content": .string("新内容")], context: ctx)
        XCTAssertTrue(result.contains("已放弃写入"), result)
        XCTAssertTrue(ctx.writtenContents.isEmpty, "切 tab 后落盘就是写错文档")
    }

    func test_rewriteSection_sameContent_isNoOp() async throws {
        let result = try await RewriteSectionTool().execute(
            arguments: ["section": .string("#4"), "content": .string("乙的结论。")], context: ctx)
        XCTAssertTrue(result.contains("完全相同"), result)
        XCTAssertTrue(ctx.reviewedWritePreviews.isEmpty)
    }

    // MARK: - HTML 工具

    func test_htmlOutline_foldsCSS() async throws {
        ctx.currentDocument = html
        ctx.currentDocumentName = "report.html"
        let result = try await HTMLOutlineTool().execute(arguments: [:], context: ctx)
        XCTAssertTrue(result.contains("section#intro"), result)
        XCTAssertTrue(result.contains("已折叠"), result)
        XCTAssertFalse(result.contains("color: #333"), "大纲里一个字 CSS 都不该有")
    }

    func test_readNode_returnsOuterHTML() async throws {
        ctx.currentDocument = html
        let result = try await ReadNodeTool().execute(
            arguments: ["selector": .string("#data")], context: ctx)
        XCTAssertTrue(result.contains("<section id=\"data\">"), result)
        XCTAssertTrue(result.contains("乙的正文"))
        XCTAssertFalse(result.contains("甲的正文"))
    }

    func test_readNode_missingSelector_listsCandidates() async throws {
        ctx.currentDocument = html
        let result = try await ReadNodeTool().execute(
            arguments: ["selector": .string("#nope")], context: ctx)
        XCTAssertTrue(result.contains("没有元素匹配"), result)
        XCTAssertTrue(result.contains("section#intro"), "要把可用选择器列出来：\(result)")
    }

    func test_readStyle_returnsCSS() async throws {
        ctx.currentDocument = html
        let result = try await ReadStyleTool().execute(arguments: [:], context: ctx)
        XCTAssertTrue(result.contains("color: #333"), result)
        XCTAssertTrue(result.contains("token"), "要提醒这次调用有多贵")
    }

    func test_patchStyle_appendsRuleInsideStyleBlock() async throws {
        ctx.currentDocument = html
        let result = try await PatchStyleTool().execute(
            arguments: ["css": .string("h2 { color: #0f766e; }")], context: ctx)
        XCTAssertTrue(result.contains("[OK]"), result)
        let written = try XCTUnwrap(ctx.writtenContents.last)
        XCTAssertTrue(written.contains("body { color: #333; }"), "原有规则不能被替换掉（级联追加）")
        let styleEnd = try XCTUnwrap(written.range(of: "</style>"))
        let rule = try XCTUnwrap(written.range(of: "h2 { color: #0f766e; }"))
        XCTAssertTrue(rule.lowerBound < styleEnd.lowerBound, "新规则要在 <style> 内部：\(written)")
    }

    func test_setNodeClass_requiresSingleMatch() async throws {
        ctx.currentDocument = html
        let refused = try await SetNodeClassTool().execute(
            arguments: ["selector": .string("section"), "class": .string("card")], context: ctx)
        XCTAssertTrue(refused.contains("匹配到 2 个元素"), refused)
        XCTAssertTrue(ctx.writtenContents.isEmpty)

        let ok = try await SetNodeClassTool().execute(
            arguments: ["selector": .string("#intro"), "class": .string("card lead")], context: ctx)
        XCTAssertTrue(ok.contains("[OK]"), ok)
        let updated = try XCTUnwrap(ctx.writtenContents.last)
        XCTAssertTrue(updated.contains("class=\"card lead\""), "class 要写回元素：\(updated)")
        XCTAssertTrue(updated.contains("id=\"intro\""), "id 不能被 class 替换掉")
    }

    func test_writeHTMLWithTemplate_assemblesAndWrites() async throws {
        ctx.currentDocument = "<p>旧</p>"
        ctx.currentDocumentName = "new.html"
        let body = "<section id=\"a\"><h2>第一章</h2><p>正文</p></section>"
        let result = try await WriteHTMLWithTemplateTool().execute(
            arguments: ["template": .string("doc"), "body": .string(body), "title": .string("测试")],
            context: ctx)
        XCTAssertTrue(result.contains("[OK]"), result)
        let written = try XCTUnwrap(ctx.writtenContents.last)
        XCTAssertTrue(written.contains("<section id=\"a\">"))
        XCTAssertTrue(written.contains("<title>测试</title>") || written.contains("<title>Document</title>"),
                      "测试环境拿不到 Bundle 里的模板时会退回最小骨架，这里只要求标题被设置或保留：\(written)")
        XCTAssertFalse(written.contains("<p>旧</p>"), "旧正文必须被替换")
    }

    func test_writeHTMLWithTemplate_rejectsStyleInBody() async throws {
        let result = try await WriteHTMLWithTemplateTool().execute(
            arguments: ["template": .string("doc"),
                        "body": .string("<style>p{color:red}</style>")],
            context: ctx)
        XCTAssertTrue(result.contains("patch_style"), result)
        XCTAssertTrue(ctx.writtenContents.isEmpty)
    }

    func test_writeHTMLWithTemplate_unknownTemplate_listsAvailable() async throws {
        let result = try await WriteHTMLWithTemplateTool().execute(
            arguments: ["template": .string("nope"), "body": .string("<p>x</p>")], context: ctx)
        XCTAssertTrue(result.contains("没有这个模板"), result)
        XCTAssertTrue(result.contains("doc"), "错误文案要列可用模板：\(result)")
    }
}
