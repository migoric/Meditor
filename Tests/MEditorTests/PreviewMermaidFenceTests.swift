import XCTest
import WebKit
@testable import MEditor

/// `extractMermaid` 的围栏配对（#85）：**内容被吞掉**的回归测试。
///
/// 改前用的是 `/```mermaid[^]*?```/g`——找一个 ```mermaid 再找**最近的** ```
/// 当收尾。它不认 CommonMark 的围栏规则，于是正文里只要有一行以 ```mermaid 开头
/// （教程里描述「怎么画图」的段落很常见），就会和后面任意一个 ``` 配成一对，
/// 中间内容被整段摘走交给 mermaid。实测在 CHANGELOG 上吞掉 19,370 字符，而且是
/// **消失**而不是退化成代码块——用户没有任何线索。
///
/// 这里跑真 WKWebView + 真渲染管线（marked / DOMPurify / render.js）。mermaid 库
/// 不加载（`render.js` 有 typeof 守卫），所以断言只看两件与库无关的事：
/// 占位 div 的个数、以及正文文字有没有留在页面上。
@MainActor
final class PreviewMermaidFenceTests: XCTestCase {

    override func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    // MARK: - 该出图的

    func testRealMermaidBlockBecomesOnePlaceholder() async throws {
        let doc = """
        # 流程图

        ```mermaid
        graph TD
          A --> B
        ```

        围栏后面这段文字必须还在。
        """
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 1, "一个 mermaid 围栏应当只产生一个占位元素")

        let body = try await text(webView)
        XCTAssertFalse(body.contains("graph TD"), "图代码应被摘进占位元素，不该留在正文：\(body)")
        XCTAssertTrue(body.contains("围栏后面这段文字必须还在。"), "围栏后的正文丢了：\(body)")
    }

    func testTextAfterFenceStaysASeparateParagraph() async throws {
        // 占位 div 与后一段之间必须留着换行：否则两者并成同一个 HTML 块，
        // 段首文字被吞进 div 里（不是 <p>，样式也不对）
        let doc = "前面一段。\n\n```mermaid\ngraph TD\n```\n\n后面一段。"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let paragraphs = try await int("document.querySelectorAll('#content p').length", webView)
        XCTAssertEqual(paragraphs, 2, "围栏前后应各是一个 <p>")
    }

    func testTwoBlocksKeepOrder() async throws {
        let doc = """
        ```mermaid
        graph TD
        ```

        中间的文字。

        ```mermaid
        sequenceDiagram
        ```
        """
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 2)
        let body = try await text(webView)
        XCTAssertTrue(body.contains("中间的文字。"))
    }

    func testLongerFenceMayCloseShorterFence() async throws {
        // 开栏 3 个、关栏 4 个 ⇒ 合法关闭（CommonMark 只要求 ≥）
        let doc = "```mermaid\ngraph TD\n````\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)
        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 1)
    }

    // MARK: - 不该出图的（#85 的形态）

    func testUnclosedMermaidFenceRendersAsCodeNotDiagram() async throws {
        let doc = "```mermaid\ngraph TD\n  A --> B\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0, "没有关栏行就没有块边界，不该出图")
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"), "代码内容不该消失：\(body)")
    }

    func testFenceBoundaryStopsAtRealClosingFence() async throws {
        // 关栏行后面不能有文字。` ```swift ` 不是 ` ```mermaid ` 的关栏，
        // 旧正则把它当关栏 ⇒ 只摘到 "graph TD"，剩下的 "swift" 漏成独立正文、
        // 尾部的 ``` 又开了一个吞到文末的围栏（结尾段落被当代码）。
        let doc = """
        ```mermaid
        graph TD
        ```swift
        let x = 1
        ```

        真正的结尾段落。
        """
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 1, "整段（到真正的关栏为止）应是一块")
        let code = try await diagrams(webView).first?.code ?? ""
        XCTAssertEqual(code, "graph TD\n```swift\nlet x = 1", "摘出来的内容应止于真正的关栏行：\(code)")
        let body = try await text(webView)
        XCTAssertTrue(body.contains("真正的结尾段落。"), "结尾段落被吞掉了：\(body)")
    }

    func testInlineTripleBackticksInProseDoNotOpenFence() async throws {
        // 行中间的 ``` 不是围栏。旧正则不看行首，遇到这种行会把它和后面
        // 代码块的开栏配成一对，中间正文被整段摘走。
        let doc = """
        行内写 ``` 三个反引号，再说一句 ```mermaid 只是描述。

        后面这段必须还在。

        ```swift
        let x = 1
        ```
        """
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0)
        let body = try await text(webView)
        XCTAssertTrue(body.contains("后面这段必须还在。"), "正文被吞掉了：\(body)")
        XCTAssertTrue(body.contains("let x = 1"), "代码块被吞掉了：\(body)")
    }

    func testFourBacktickFenceKeepsInnerMermaidAsText() async throws {
        let doc = "````\n```mermaid\ngraph TD\n```\n````\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0, "外层 4 反引号围栏里的 ```mermaid 只是文本")
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"))
    }

    func testFourSpaceIndentedFenceIsCodeBlock() async throws {
        // 4 空格 = 缩进代码块，marked 不当围栏
        let doc = "    ```mermaid\n    graph TD\n    ```\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0)
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"))
    }

    func testInfoStringIsCaseSensitive() async throws {
        let doc = "```Mermaid\ngraph TD\n```\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0, "与 Swift 侧 MermaidBlocks 同口径：区分大小写")
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"))
    }

    func testTildeFenceIsNotRenderedAsDiagram() async throws {
        // 已知限制：只有反引号围栏出图（与 MermaidBlocks 一致），
        // 但 ~~~ 围栏必须被正确**跨过**，里面的 ``` 不能当开栏
        let doc = "~~~\n```mermaid\ngraph TD\n```\n~~~\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0)
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"))
    }

    func testTildeMermaidFenceWithBacktickElsewhereIsNotRendered() async throws {
        // 反向验证（AGENTS.md §6）：关栏分支若只判 info 不判开栏字符，
        // ~~~mermaid 会被摘成图——本条随即变红。文档里必须另有 ``` 放行快路径。
        let doc = "~~~mermaid\ngraph TD\n~~~\n\n正文。\n\n```swift\nlet a = 1\n```\n"
        let webView = try await PreviewTestPage.makeWebView().0
        try await PreviewTestPage.render(doc, in: webView)

        let count = try await diagrams(webView).count
        XCTAssertEqual(count, 0, "~~~mermaid 不是图（与 Swift 侧 MermaidBlocks 同口径）")
        let body = try await text(webView)
        XCTAssertTrue(body.contains("graph TD"), "波浪号围栏内容应作为普通代码块保留")
    }

    // MARK: - 工具

    private struct Diagram: Decodable { let id: String; let code: String }

    /// 最近一次渲染摘出的 mermaid 图。
    ///
    /// 不数 DOM 里的 `.mermaid-placeholder`：占位元素会被异步换掉——有 mermaid
    /// 库时变成 `.mermaid-container`，库加载失败时变成 `.error-block`
    ///（测试夹具里没有 mermaid.min.js，走的正是后一条），数出来是 0。
    private func diagrams(_ webView: WKWebView) async throws -> [Diagram] {
        guard let raw = try await PreviewTestPage.eval(
                "JSON.stringify(MEditorRender.getMermaidDiagrams())", webView),
              let data = raw.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([Diagram].self, from: data)) ?? []
    }

    private func int(_ js: String, _ webView: WKWebView) async throws -> Int {
        Int(try await PreviewTestPage.eval(js, webView) ?? "") ?? -1
    }

    private func text(_ webView: WKWebView) async throws -> String {
        try await PreviewTestPage.eval("document.getElementById('content').textContent", webView) ?? ""
    }
}
