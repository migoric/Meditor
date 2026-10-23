import XCTest
import WebKit
@testable import MEditor

/// 跨文档失效探针（2026-10-23 review #101 发现）。
///
/// `renderInto` 的 no-op 短路拿 `lastRenderedHTML` 与本次 join 产物比字符串。这个
/// 变量是 **整个 WebView 的 JS 上下文级状态**，而 preview 的 WKWebView 由
/// `WebViewPool` 发给 `MarkdownWebView`、**跨文档复用**（切 tab 只改 `content`，
/// 不重建 NSView）。与此同时 bridge 的缓存命中路径会**直接写 `contentEl.innerHTML`
/// 而不更新 `lastRenderedHTML`**。两者叠加：
///
/// 1. 渲染大文档 A（> `RENDER_CACHE_SOURCE_LIMIT` 120KB ⇒ 永不进缓存）→ last = H_A
/// 2. 切到小文档 B → 缓存未命中，渲染 B → last = H_B，B 被 idle 快照进缓存
/// 3. 切回 A → 缓存未命中，渲染 A → last = H_A
/// 4. 再切到 B → **缓存命中**，DOM 直接换成 B，last 仍停在 H_A
/// 5. 再切回 A → `html === lastRenderedHTML` ⇒ **短路 return，什么都不画** ⇒
///    预览停在上一个文件 B 上，而 tab 已经是 A
///
/// 第 5 步应该渲染 A。这是内容错误，不是性能问题。
@MainActor
final class PreviewStalePreviewTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    private func makeBridgedWebView() async throws -> WKWebView {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.eval(
            PreviewTestPage.previewScript(named: "scripts/bridge.js") + "\n;\n1;\n", webView)
        try await PreviewTestPage.waitUntil(
            webView, "window.MEditor && window.MEditor.update ? 'ok' : 'pending'", timeout: 10)
        return webView
    }

    /// 超 120KB 源码的文档永远不进 renderCache（`shouldCacheContent`）。
    private func largeDoc() -> String {
        var text = "# BIGDOC-MARK\n\n"
        var i = 0
        while text.utf8.count < 130_000 {
            text += "第 \(i) 段：用于把文档推过缓存阈值的填充正文。\n\n"
            i += 1
        }
        return text
    }

    private let smallDoc = "# SMALLDOC-MARK\n\n小文档正文。\n"

    /// 让 idle 快照落地（requestIdleCallback 或 500ms setTimeout 兜底）。
    private func waitForSnapshot() async throws {
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func report(_ webView: WKWebView) async throws -> String {
        try await PreviewTestPage.eval(
            "document.getElementById('content').textContent.slice(0, 40)", webView) ?? ""
    }

    /// 对照组：中间没有缓存命中时，切回 A 必须重画（证明 A 的 H 确实等于 last）。
    func testSwitchingBackWithoutCacheHitRepaints() async throws {
        let webView = try await makeBridgedWebView()
        let a = largeDoc()

        _ = try await PreviewTestPage.eval(
            "window.MEditor.boot(\(try PreviewTestPage.jsStringLiteral(a))); 1", webView)
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(smallDoc)), 2); 1", webView)
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(a)), 3); 1", webView)

        let text = try await report(webView)
        XCTAssertTrue(text.contains("BIGDOC-MARK"), "切回大文档后应渲染 A，实际：\(text)")
    }

    /// 主断言：中间夹一次缓存命中后，再切回 A 必须重画。
    func testSwitchingBackAfterCacheHitRepaints() async throws {
        let webView = try await makeBridgedWebView()
        let a = largeDoc()

        // 1. 渲染 A
        _ = try await PreviewTestPage.eval(
            "window.MEditor.boot(\(try PreviewTestPage.jsStringLiteral(a))); 1", webView)
        // 2. 切到 B（缓存未命中 → 渲染 → 排快照）
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(smallDoc)), 2); 1", webView)
        try await waitForSnapshot()
        // 3. 切回 A（缓存未命中 → 渲染，last 回到 H_A）
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(a)), 3); 1", webView)
        // 4. 再切到 B —— 这一步会走缓存命中，直接写 innerHTML
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(smallDoc)), 4); 1", webView)
        let afterHit = try await report(webView)
        XCTAssertTrue(afterHit.contains("SMALLDOC-MARK"), "缓存命中后应显示 B，实际：\(afterHit)")

        // 5. 再切回 A —— 这里必须重画
        _ = try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.eval(
            "window.MEditor.update(\(try PreviewTestPage.jsStringLiteral(a)), 5); 1", webView)
        let stats = try await PreviewTestPage.stats(webView)
        let text = try await report(webView)
        XCTAssertTrue(
            text.contains("BIGDOC-MARK"),
            "切回大文档后预览仍停在 B（noopSkip=\(stats.noopSkip)）—— lastRenderedHTML 跨文档失效")
        XCTAssertEqual(stats.noopSkip, 0, "跨文档切换不该触发 no-op 短路")
    }
}
