import XCTest
import WebKit
@testable import MEditor

/// HTML 预览的页内锚点跳转（`<a href="#小节">`）。
///
/// 回归背景：注入的 `<base href="meditor-asset://…">` 会把纯 fragment 链接也
/// 按 base 解析，点击后 WebKit 既不加载也不滚动（连 `decidePolicyFor` 都不调）。
/// `HTMLAnchorGuard` 在页面内接管这类点击。下面同时锁住「base 确实改写了
/// fragment」与「守卫生效后确实滚动了」两件事。
@MainActor
final class HTMLPreviewAnchorScrollTests: XCTestCase {

    // MARK: - 纯 URL 判据（不依赖 WebKit）

    func testIsRewrittenAnchor_matchesBaseHijackedFragment() {
        let url = URL(string: "meditor-asset://local/Users/me/docs/#target")!
        XCTAssertTrue(PreviewLinkNavigator.isRewrittenAnchor(url))
    }

    func testIsRewrittenAnchor_ignoresAssetWithoutFragment() {
        let url = URL(string: "meditor-asset://local/Users/me/docs/pic.png")!
        XCTAssertFalse(PreviewLinkNavigator.isRewrittenAnchor(url))
    }

    func testIsRewrittenAnchor_ignoresOrdinaryAnchor() {
        XCTAssertFalse(PreviewLinkNavigator.isRewrittenAnchor(URL(string: "https://example.com/#a")!))
        XCTAssertFalse(PreviewLinkNavigator.isRewrittenAnchor(URL(string: "https://localhost/#a")!))
    }

    // MARK: - 装配守卫

    func test_previewUserContent_installsAnchorGuard() {
        let controller = WebPreviewView.makeUserContentController(coordinator: WebPreviewView.Coordinator())
        let sources = controller.userScripts.map(\.source)
        guard let guardSource = sources.first(where: { $0.contains("__meditorAnchorGuard") }) else {
            return XCTFail("HTML 预览的 userContentController 必须装上锚点守卫")
        }
        XCTAssertTrue(guardSource.contains("window.location.hash"),
                      "守卫应当用 location.hash 做页内跳转（replaceState 会按 <base> 解析而被拒绝）")
    }

    // MARK: - 真实 WKWebView

    func test_injectedBase_rewritesFragmentHrefToAssetScheme() async throws {
        let html = Self.sampleHTML
        let directory = try Self.makeDocumentDirectory(html: html)
        defer { try? FileManager.default.removeItem(at: directory) }

        let injected = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: directory)
        let webView = try await Self.load(injected, installAnchorGuard: false)
        defer { Self.tearDown(webView) }

        let href = await Self.eval("document.getElementById('tocLink').href", webView)
        let scheme = URL(string: href ?? "")?.scheme
        XCTAssertEqual(scheme, MeditorAssetSchemeHandler.scheme,
                       "注入 <base> 后 #target 应当被改写成 asset URL（这正是点击失效的来源）")
    }

    func test_anchorGuard_scrollsToTargetAfterClick() async throws {
        let html = Self.sampleHTML
        let directory = try Self.makeDocumentDirectory(html: html)
        defer { try? FileManager.default.removeItem(at: directory) }

        let injected = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: directory)
        let webView = try await Self.load(injected, installAnchorGuard: true)
        defer { Self.tearDown(webView) }

        let beforeY = await Self.number("window.scrollY", webView)
        XCTAssertEqual(beforeY, 0, "初始应当停在顶部")

        _ = await Self.eval("document.getElementById('tocLink').click(); 'x'", webView)
        try await Task.sleep(nanoseconds: 900_000_000)

        let afterY = await Self.number("window.scrollY", webView)
        XCTAssertGreaterThan(afterY, 400, "点目录锚点后预览没有滚动（scrollY=\(afterY)）")

        let hash = await Self.eval("location.hash", webView)
        XCTAssertEqual(hash, "#target", "fragment 应写回地址栏，:target 样式才有依据")
    }

    /// 目录链接写成「带文件名」的自引用（`report.html#小节`）同样被 `<base>`
    /// 改写成 asset URL，守卫要靠「目标在本文档里存在」把它认成页内跳转。
    func test_anchorGuard_handlesSelfFileNameLink() async throws {
        let html = Self.sampleHTML.replacingOccurrences(
            of: "href=\"#target\"",
            with: "href=\"doc.html#target\""
        )
        let directory = try Self.makeDocumentDirectory(html: html)
        defer { try? FileManager.default.removeItem(at: directory) }

        let injected = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: directory)
        let webView = try await Self.load(injected, installAnchorGuard: true)
        defer { Self.tearDown(webView) }

        let href = await Self.eval("document.getElementById('tocLink').href", webView)
        XCTAssertTrue(href?.contains("meditor-asset://") == true,
                      "带文件名的相对链接也应被 <base> 改写（\(href ?? "nil")）")

        _ = await Self.eval("document.getElementById('tocLink').click(); 'x'", webView)
        try await Task.sleep(nanoseconds: 900_000_000)

        let afterY = await Self.number("window.scrollY", webView)
        XCTAssertGreaterThan(afterY, 400, "report.html#小节 这种写法没能跳转（scrollY=\(afterY)）")
    }

    // MARK: - 夹具

    /// 60 段正文把页面撑长，保证目标小节在首屏之外。
    private static let sampleHTML: String = {
        var filler = ""
        for i in 1...60 {
            filler += "<p>正文第 \(i) 段，用来把页面撑长。</p>\n"
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>锚点测试</title></head>
        <body>
        <nav><a id="tocLink" href="#target">跳到目标小节</a></nav>
        \(filler)
        <h2 id="target">目标小节</h2>
        <p>这里是目标位置。</p>
        </body></html>
        """
    }()

    private static func makeDocumentDirectory(html: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try html.write(to: directory.appendingPathComponent("doc.html"), atomically: true, encoding: .utf8)
        return directory
    }

    /// 按 `WebPreviewView.Coordinator.applyLoad` 的方式渲染：注入 base + 合成 https baseURL。
    private static func load(_ html: String, installAnchorGuard: Bool) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MeditorAssetSchemeHandler(), forURLScheme: MeditorAssetSchemeHandler.scheme)
        let userContent = WKUserContentController()
        if installAnchorGuard {
            userContent.addUserScript(HTMLAnchorGuard.userScript())
        }
        config.userContentController = userContent

        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let webView = WKWebView(frame: frame, configuration: config)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        // 持住 window：离屏 WebView 没有宿主视图时，滚动相关的布局量不成立。
        windows[webView] = window

        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            let readyState = await eval("document.readyState", webView)
            if readyState == "complete" { return webView }
        }
        throw NSError(domain: "HTMLPreviewAnchorScrollTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "HTML 没加载完"])
    }

    private static var windows: [WKWebView: NSWindow] = [:]

    private static func tearDown(_ webView: WKWebView) {
        windows[webView]?.contentView = nil
        windows[webView] = nil
    }

    private static func eval(_ js: String, _ webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, _ in
                continuation.resume(returning: value.map { "\($0)" })
            }
        }
    }

    private static func number(_ js: String, _ webView: WKWebView) async -> Double {
        let raw = await eval("String(Math.round(\(js)))", webView) ?? "0"
        return Double(raw) ?? 0
    }
}
