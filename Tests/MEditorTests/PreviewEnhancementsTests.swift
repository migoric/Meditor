import XCTest
import WebKit

/// 渲染后增强：本地资源 URL 与编辑器滚动同步所需的源码行号。
@MainActor
final class PreviewEnhancementsTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    func testAbsoluteAssetPathsAreEncodedWithoutRewritingOtherURLs() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let source = """
        <img src="/Users/me/My Docs/pic.png">

        <img src="file:///Users/me/a b.png">

        <img src="./relative.png">

        <img src="https://example.com/remote.png">

        <img src="meditor-asset://local/already/pic.png">
        """
        _ = try await PreviewTestPage.render(source, in: webView)
        let sources = try await PreviewTestPage.eval("""
        Array.prototype.map.call(document.querySelectorAll('#content img'), function (img) {
          return img.getAttribute('src');
        }).join('|')
        """, webView)
        XCTAssertEqual(sources, "meditor-asset://local/Users/me/My%20Docs/pic.png|"
            + "meditor-asset://local/Users/me/a%20b.png|./relative.png|"
            + "https://example.com/remote.png|meditor-asset://local/already/pic.png")
    }

    func testHeadingSourceLinesIgnoreHeadingsInsideFence() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let source = "# 标题\n\n```md\n# 假标题\n```\n\n## 真小节"
        _ = try await PreviewTestPage.render(source, in: webView)
        let lines = try await PreviewTestPage.eval("""
        Array.prototype.map.call(document.querySelectorAll('#content h1, #content h2'), function (heading) {
          return heading.getAttribute('data-source-line');
        }).join('|')
        """, webView)
        XCTAssertEqual(lines, "0|6")
    }
}
