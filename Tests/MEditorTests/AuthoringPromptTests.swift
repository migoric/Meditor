import XCTest
@testable import MEditor

/// 档案分派、上下文构建、system prompt 分段。
///
/// 最重要的用例是 `test_plainContext_isByteIdenticalToLegacyImplementation`：
/// 它把**改造前的那段代码**原样抄进测试当参照，逐字节比对。分档这件事的风险全在
/// 「plain 悄悄变了」——老用户什么都没做，拿到的 prompt 却变了，这类回归没有报错、
/// 只有行为漂移，靠人眼看 diff 是看不出来的。
final class AuthoringPromptTests: XCTestCase {

    // MARK: - 档案分派

    func test_resolve_byExtension() {
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: "md").kind, .markdown)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: "MARKDOWN").kind, .markdown)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: "html").kind, .html)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: "htm").kind, .html)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: "txt").kind, .plain)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileExtension: nil).kind, .plain)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileName: "docs/a.md").kind, .markdown)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileName: "Untitled").kind, .plain)
        XCTAssertEqual(DocumentAuthoringProfile.resolve(fileName: nil).kind, .plain)
    }

    func test_profiles_carryGuidanceExceptPlain() {
        XCTAssertTrue(DocumentAuthoringProfile.plain.guidance.isEmpty, "plain 不带任何额外指令 ⇒ prompt 与旧版一致")
        XCTAssertTrue(DocumentAuthoringProfile.markdown.guidance.contains("read_section"))
        XCTAssertTrue(DocumentAuthoringProfile.html.guidance.contains("write_html_with_template"))
    }

    // MARK: - plain：与旧实现逐字节一致

    func test_plainContext_isByteIdenticalToLegacyImplementation() {
        let cases: [(name: String, content: String, selection: String, para: String?, cursor: Int?, full: Bool)] = [
            ("a.md", "正文内容\n\n第二段", "", nil, nil, true),
            ("a.md", "正文内容\n\n第二段", "", nil, nil, false),
            ("a.md", "正文内容", "选中几个字", nil, 1, true),
            ("a.md", "正文内容", "选中几个字", "选中几个字所在的整段", 1, true),
            ("a.md", String(repeating: "长", count: 5000), "", nil, 1, true),
            ("a.md", "x", String(repeating: "选", count: 4200), nil, nil, false),
        ]
        for item in cases {
            let input = AuthoringContextBuilder.Input(
                name: item.name, content: item.content, selection: item.selection,
                selectionParagraph: item.para, cursorLine: item.cursor)
            let built = AuthoringContextBuilder.context(
                for: .plain, input: input, includeFullDocument: item.full)
            let legacy = Self.legacyPlainContext(
                name: item.name, content: item.content, selection: item.selection,
                para: item.para, cursorLine: item.cursor, includeFullDocument: item.full)
            XCTAssertEqual(built, legacy, "plain 档案的上下文必须与改造前逐字节相同")
        }
    }

    /// 改造前 `AIChatCoordinator.systemContext` 里的那段逻辑，原样保留作参照实现。
    private static func legacyPlainContext(
        name: String, content: String, selection: String,
        para: String?, cursorLine: Int?, includeFullDocument: Bool
    ) -> String {
        var ctx = ""
        if !selection.isEmpty {
            let sel = selection.count > 4000 ? String(selection.prefix(4000)) + "…" : selection
            ctx += "\n\nThe user selected this text in \"\(name)\":\n\n\(sel)"
            if let para, para.count > selection.count, para.count <= 4000 {
                ctx += "\n\nThe selection is part of this paragraph in \"\(name)\":\n\n\(para)"
            }
        } else if includeFullDocument {
            let body = DocumentContextExcerpt.excerpt(content: content, cursorLine: cursorLine)
            ctx += "\n\nThe current document is \"\(name)\":\n\n\(body)"
        } else {
            ctx += "\n\nThe user is editing a document named \"\(name)\"."
        }
        return ctx
    }

    // MARK: - markdown：大纲而不是全文

    func test_markdownContext_longDocument_givesOutlineNotFullText() {
        // 必须超过 fullTextThresholdTokens：短文档是**故意**给全文的（见下一条用例）
        let filler = Array(repeating: "这是一段用来把文档撑长的正文，重复出现以便超过短文档门槛。", count: 40)
            .joined(separator: "\n\n")
        let content = "# 一\n\n独特句子甲\n\n" + filler + "\n\n## 1.1\n\n独特句子乙"
        let input = AuthoringContextBuilder.Input(name: "d.md", content: content)
        let ctx = AuthoringContextBuilder.context(for: .markdown, input: input, includeFullDocument: true)
        XCTAssertTrue(ctx.contains("#1 ·"), ctx)
        XCTAssertTrue(ctx.contains("outline"), ctx)
        XCTAssertFalse(ctx.contains("独特句子甲"), "长文档首轮注入大纲而不是全文：正文不该出现在上下文里")
    }

    func test_markdownContext_shortDocument_givesFullText() {
        // 一篇 200 字的笔记，「大纲 + read_section」是一条往返换 200 token——往返更贵
        let content = "# 一\n\n短小的一段正文。"
        let ctx = AuthoringContextBuilder.context(
            for: .markdown,
            input: .init(name: "d.md", content: content),
            includeFullDocument: true)
        XCTAssertTrue(ctx.contains("短小的一段正文"), "短文档直接给全文，省掉一次工具往返：\(ctx)")
    }

    func test_markdownContext_subsequentTurn_pointsToTool() {
        let input = AuthoringContextBuilder.Input(name: "d.md", content: "# 一\n\n甲")
        let ctx = AuthoringContextBuilder.context(for: .markdown, input: input, includeFullDocument: false)
        XCTAssertTrue(ctx.contains("outline_document"), ctx)
        XCTAssertTrue(ctx.contains("1 节"), ctx)
    }

    func test_markdownContext_selectionReportsContainingSection() {
        let content = "# 一\n\n甲句\n\n# 二\n\n独特句子丙"
        let input = AuthoringContextBuilder.Input(
            name: "d.md", content: content, selection: "独特句子丙")
        let ctx = AuthoringContextBuilder.context(for: .markdown, input: input, includeFullDocument: true)
        XCTAssertTrue(ctx.contains("独特句子丙"), ctx)
        XCTAssertTrue(ctx.contains("section #2"), "选区要标注它在哪一节：\(ctx)")
    }

    func test_markdownContext_emptyDocument() {
        let ctx = AuthoringContextBuilder.context(
            for: .markdown,
            input: .init(name: "d.md", content: "  "),
            includeFullDocument: true)
        XCTAssertTrue(ctx.contains("empty"), ctx)
    }

    // MARK: - html：CSS 折叠

    func test_htmlContext_foldsCSSAndShowsStructure() {
        let content = """
        <html><head><style>body { color: #123456; }</style></head>
        <body><main><section id="intro"><h2>引言</h2><p>正文</p></section></main></body></html>
        """
        let input = AuthoringContextBuilder.Input(name: "r.html", content: content)
        let ctx = AuthoringContextBuilder.context(for: .html, input: input, includeFullDocument: true)
        XCTAssertTrue(ctx.contains("section#intro"), ctx)
        XCTAssertTrue(ctx.contains("已折叠"), ctx)
        XCTAssertFalse(ctx.contains("#123456"), "CSS 内容一个字都不进上下文：\(ctx)")
    }

    func test_htmlContext_emptyDocument_pointsAtTemplateTool() {
        let ctx = AuthoringContextBuilder.context(
            for: .html, input: .init(name: "r.html", content: ""), includeFullDocument: true)
        XCTAssertTrue(ctx.contains("write_html_with_template"), ctx)
    }

    // MARK: - 分段标记

    func test_segments_joinSplitAndStrip() {
        let joined = SystemPromptSegments.join(stable: "稳定", volatile: "易变")
        XCTAssertEqual(SystemPromptSegments.split(joined)?.stable, "稳定")
        XCTAssertEqual(SystemPromptSegments.split(joined)?.volatile, "易变")
        XCTAssertEqual(SystemPromptSegments.strippingDelimiter(joined), "稳定易变")
        XCTAssertNil(SystemPromptSegments.split("没有标记"), "没有易变段时不该分块")
        XCTAssertEqual(SystemPromptSegments.join(stable: "只有稳定", volatile: ""), "只有稳定")
    }

    // MARK: - wire：Anthropic 拿到两块 system，OpenAI 拿到剥掉标记的一段

    func test_anthropicWire_emitsStableBlockWithCacheControl() async throws {
        let session = MockURLSession()
        session.stubbedData = Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8)
        let backend = RestAgentBackend(
            config: Self.anthropicConfig(), wire: .anthropic, session: session)
        let system = SystemPromptSegments.join(stable: "规则段", volatile: "选区段")
        _ = try await backend.complete(
            messages: [AgentMessage(role: .system, content: system),
                       AgentMessage(role: .user, content: "hi")],
            tools: [])

        let body = try Self.jsonBody(from: session)
        let blocks = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2, "稳定段与易变段要拆成两个 block")
        XCTAssertEqual(blocks[0]["text"] as? String, "规则段")
        XCTAssertNotNil(blocks[0]["cache_control"], "断点必须落在稳定段末尾，否则易变内容会把缓存全冲掉")
        XCTAssertEqual(blocks[1]["text"] as? String, "选区段")
        XCTAssertNil(blocks[1]["cache_control"])
    }

    func test_anthropicWire_withoutSegments_keepsSingleBlock() async throws {
        let session = MockURLSession()
        session.stubbedData = Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8)
        let backend = RestAgentBackend(
            config: Self.anthropicConfig(), wire: .anthropic, session: session)
        _ = try await backend.complete(
            messages: [AgentMessage(role: .system, content: "只有一段"),
                       AgentMessage(role: .user, content: "hi")],
            tools: [])
        let body = try Self.jsonBody(from: session)
        let blocks = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["text"] as? String, "只有一段")
    }

    func test_openAIWire_stripsSegmentDelimiter() async throws {
        let session = MockURLSession()
        session.stubbedData = Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        let backend = RestAgentBackend(
            config: Self.openAIConfig(), wire: .openAI, session: session)
        let system = SystemPromptSegments.join(stable: "规则段", volatile: "选区段")
        _ = try await backend.complete(
            messages: [AgentMessage(role: .system, content: system),
                       AgentMessage(role: .user, content: "hi")],
            tools: [])

        let body = try Self.jsonBody(from: session)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertEqual(content, "规则段选区段")
        XCTAssertFalse(content.contains("\u{0}"), "分隔标记绝不能出现在线上请求里")
    }

    // MARK: - Helpers

    private static func jsonBody(from session: MockURLSession) throws -> [String: Any] {
        let request = try XCTUnwrap(session.capturedRequests.last)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func anthropicConfig() -> AIConfig {
        AIConfig(kind: .anthropic, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5",
                 cliPath: "", cliModel: "", apiKey: "test-key", requestTimeoutSeconds: 30)
    }

    private static func openAIConfig() -> AIConfig {
        AIConfig(kind: .openai, baseURL: "https://api.openai.com/v1", model: "gpt-4o",
                 cliPath: "", cliModel: "", apiKey: "test-key", requestTimeoutSeconds: 30)
    }
}
