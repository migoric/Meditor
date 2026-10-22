import XCTest
import WebKit
@testable import MEditor

/// 恢复会话时 HTML 预览先拿空内容渲染，内容随后到达——`reloadToken` 必须真的把它
/// 重新渲染出来，而不只是「数字变大」。
///
/// 与 `PreviewRestoreSyncTests` 互补：那边锁「内容到达时会递增 token」（TabManager 侧），
/// 这边锁「token 变化确实会让 WebView 重新加载」（WebPreviewView 侧）。两段合起来才是
/// 完整的「冷启动选中 HTML 不再白屏」链路。
@MainActor
final class HTMLPreviewContentReloadTests: XCTestCase {

    private static var windows: [WKWebView: NSWindow] = [:]

    override func tearDown() {
        for (webView, window) in Self.windows {
            window.contentView = nil
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        Self.windows = [:]
        super.tearDown()
    }

    func testTokenBumpRendersContentAfterEmptyLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("doc.html")
        try "<html><body><h1>磁盘副本</h1></body></html>".write(to: fileURL, atomically: true, encoding: .utf8)

        let coordinator = WebPreviewView.Coordinator()
        let (webView, window) = Self.makeWebView()
        Self.windows[webView] = window
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        // ① 恢复会话的第一步：文件已选中但内容还没读进来，先按空内容加载。
        coordinator.applyLoad(fileURL: fileURL, reloadToken: 1, content: "")
        try await Self.waitUntil(webView, "document.body ? 'ok' : 'pending'", timeout: 20)
        let emptyLength = try await Self.text(webView)
        XCTAssertEqual(emptyLength, 0, "空内容阶段本来就该是空白（这一层不是 bug）")

        // ② 后台读完，内容回填 → token 递增 → 必须重新渲染。
        coordinator.applyLoad(fileURL: fileURL, reloadToken: 2,
                              content: "<html><body><h1 id=\"restored-title\">恢复后的正文</h1></body></html>")
        try await Self.waitUntil(webView, "document.getElementById('restored-title') ? 'ok' : 'pending'", timeout: 20)

        let restored = try await Self.eval("document.getElementById('restored-title').innerText", webView)
        XCTAssertEqual(restored, "恢复后的正文",
                       "reloadToken 递增后页面没有换成真实内容——这正是冷启动白屏的形态")
    }

    /// 同 URL 同 token 的重复调用不应重复加载（`updateNSView` 会被无关刷新触发很多次）。
    func testSameTokenDoesNotReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("doc.html")
        try "<html><body><p>x</p></body></html>".write(to: fileURL, atomically: true, encoding: .utf8)

        let coordinator = WebPreviewView.Coordinator()
        let (webView, window) = Self.makeWebView()
        Self.windows[webView] = window
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        coordinator.applyLoad(fileURL: fileURL, reloadToken: 7,
                              content: "<html><body><p id=\"first\">第一版</p></body></html>")
        try await Self.waitUntil(webView, "document.getElementById('first') ? 'ok' : 'pending'", timeout: 20)

        // 同一 token 再调一次：不得重新导航（否则每次无关刷新都会重解析一次大文档）。
        coordinator.applyLoad(fileURL: fileURL, reloadToken: 7,
                              content: "<html><body><p id=\"second\">第二版</p></body></html>")
        try await Task.sleep(nanoseconds: 800_000_000)

        let first = try await Self.eval("document.getElementById('first') ? 'yes' : 'no'", webView)
        let second = try await Self.eval("document.getElementById('second') ? 'yes' : 'no'", webView)
        XCTAssertEqual(first, "yes", "同 token 不该重新加载")
        XCTAssertEqual(second, "no", "同 token 却把新内容渲染进来了 ⇒ 去重失效")
    }

    // MARK: - 夹具

    private static func makeWebView() -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MeditorAssetSchemeHandler(), forURLScheme: MeditorAssetSchemeHandler.scheme)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let webView = WKWebView(frame: frame, configuration: config)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        return (webView, window)
    }

    /// 就绪判据用页面自己的元素，不用 `readyState`——`loadHTMLString` 下它会在解析
    /// 刚开始时就报 complete（见 HTMLPreviewAnchorScrollTests 的说明）。
    private static func waitUntil(_ webView: WKWebView, _ js: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await eval(js, webView) == "ok" { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("等待超时：\(js)")
    }

    private static func text(_ webView: WKWebView) async throws -> Int {
        let raw = try await eval("String(document.body ? document.body.innerText.trim().length : -1)", webView)
        return Int(raw ?? "-1") ?? -1
    }

    private static func eval(_ js: String, _ webView: WKWebView) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value.map { "\($0)" }) }
            }
        }
    }
}
