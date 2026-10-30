import XCTest
import WebKit

/// 主预览自身的消毒边界；不能只靠审阅面或 CSP 的测试间接覆盖。
@MainActor
final class PreviewMarkdownSecurityTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    func testRenderedHTMLRemovesActiveContentButKeepsLocalAssetScheme() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let source = """
        <script>window.__xss = true</script>

        <img src="x" onerror="window.__xss = true">

        <a href="javascript:window.__xss = true">危险链接</a>

        <img src="meditor-asset://local/already/pic.png">
        """
        _ = try await PreviewTestPage.render(source, in: webView)
        let result = try await PreviewTestPage.eval("""
        document.querySelectorAll('#content script').length + '/'
          + document.querySelectorAll('#content [onerror]').length + '/'
          + document.querySelectorAll('#content a[href^="javascript:"]').length + '/'
          + document.querySelector('#content img[src^="meditor-asset:"]').getAttribute('src') + '/'
          + String(window.__xss === undefined)
        """, webView)
        XCTAssertEqual(result, "0/0/0/meditor-asset://local/already/pic.png/true")
    }
}
