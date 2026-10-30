import XCTest
import WebKit

/// 主预览的数学管线：提取边界、真实 KaTeX 渲染，以及 DOM diff 中的占位归一化。
@MainActor
final class PreviewMathTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    private func makeKatexPage() async throws -> WKWebView {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.eval(
            PreviewTestPage.previewScript(named: "katex.min.js") + "\n;\n1;\n", webView)
        return webView
    }

    func testMathExtractionAndRealKatexRendering() async throws {
        let webView = try await makeKatexPage()
        let source = #"""
        行内 $x^2$。

        $$\frac{a}{b}$$

        `$notMath$`

        ```tex
        $alsoNotMath$
        ```

        价格 $5 到 $10。
        """#
        _ = try await PreviewTestPage.render(source, in: webView)

        let rendered = try await PreviewTestPage.eval("""
        document.querySelectorAll('#content .meditor-math-inline .katex').length + '/'
          + document.querySelectorAll('#content .meditor-math-block .katex').length
        """, webView)
        XCTAssertEqual(rendered, "1/1", "行内与块级公式都应交给真实 KaTeX 渲染")
        let text = try await PreviewTestPage.eval("document.getElementById('content').textContent", webView)
        XCTAssertTrue(text?.contains("$notMath$") == true, "行内代码不得识别成公式")
        XCTAssertTrue(text?.contains("$alsoNotMath$") == true, "围栏代码不得识别成公式")
        XCTAssertTrue(text?.contains("$5 到 $10") == true, "价格写法不得识别成公式")
    }

    func testFullTreeDiffPreservesRenderedMathWhenEditingElsewhere() async throws {
        let webView = try await makeKatexPage()
        // 引用定义强制走整篇解析，确保本条覆盖 normalizedMathHTML 所在的全树 diff，
        // 而不是只靠块对齐的前后缀保留来“假通过”。
        let source = "[ref]: /url\n\n开头。\n\n行内 $x^2$。\n\n结尾 v1。"
        _ = try await PreviewTestPage.render(source, in: webView)
        _ = try await PreviewTestPage.eval("""
        window.__math = document.querySelector('#content .meditor-math-inline');
        window.__mathHTML = window.__math.innerHTML;
        1
        """, webView)
        try await PreviewTestPage.resetStats(webView)

        _ = try await PreviewTestPage.render(source.replacingOccurrences(of: "v1", with: "v2"), in: webView)
        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(stats.fullParse, 1, "测试前提必须是整篇解析：\(stats)")
        let preserved = try await PreviewTestPage.eval("""
        String(document.querySelector('#content .meditor-math-inline') === window.__math
          && document.querySelector('#content .meditor-math-inline').innerHTML === window.__mathHTML)
        """, webView)
        XCTAssertEqual(preserved, "true", "无关编辑不得清空并重渲染已有 KaTeX 节点")
        let tail = try await PreviewTestPage.eval(
            "document.getElementById('content').lastElementChild.textContent", webView)
        XCTAssertEqual(tail, "结尾 v2。")
    }
}
