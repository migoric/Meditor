import XCTest
import WebKit
@testable import MEditor

/// 代码块在 patchDOM / 缓存恢复两条路径上的行为守卫。
///
/// 背景（2026-10-23 对拍复核发现）：
/// 1. Copy 按钮挂在 PRE 内，`nodesEqual` 比 PRE 的 textContent 会带上按钮文字
///    ⇒ 永不相等 ⇒ 含代码块的文档每次更新都整体重建所有 PRE 并被重重高亮。
/// 2. bridge 的缓存命中恢复路径不调 highlightCodeBlocks；快照是 idle 落盘的，
///    可能存下未高亮的 HTML ⇒ 恢复页永久缺高亮。
@MainActor
final class PreviewCodeBlockPatchTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    /// 在标准夹具页面上额外注入 bridge.js（缓存命中路径只在 bridge 里）。
    private func makeBridgedWebView() async throws -> WKWebView {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.eval(
            PreviewTestPage.previewScript(named: "scripts/bridge.js") + "\n;\n1;\n", webView)
        try await PreviewTestPage.waitUntil(
            webView, "window.MEditor && window.MEditor.update ? 'ok' : 'pending'", timeout: 10)
        return webView
    }

    /// 改一个无关段落时，未变化的代码块节点必须原样保留（不被替换）。
    func testPREPreservedWhenUnrelatedParagraphChanges() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let fence = "```swift\nlet a = 1\n```"
        let docA = "第一段。\n\n第二段。\n\n\(fence)\n\n结尾段。"
        let docB = "第一段改了。\n\n第二段。\n\n\(fence)\n\n结尾段。"

        _ = try await PreviewTestPage.render(docA, in: webView)
        _ = try await PreviewTestPage.eval(
            "window.__pre = document.querySelector('#content pre'); 1", webView)
        _ = try await PreviewTestPage.render(docB, in: webView)

        let identity = try await PreviewTestPage.eval(
            "document.querySelector('#content pre') === window.__pre ? 'preserved' : 'replaced'", webView)
        XCTAssertEqual(identity, "preserved",
                       "无关段落改动不应重建代码块节点（Copy 按钮污染 textContent 的旧病）")
        let button = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content pre .meditor-copy-btn').length", webView)
        XCTAssertEqual(button, "1", "保留的节点上 Copy 按钮必须还在")
    }

    /// 高亮幂等：重复跑 highlightCodeBlocks 不重复加按钮、不改代码文本。
    func testHighlightCodeBlocksIsIdempotent() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let doc = "```swift\nlet a = 1\n```\n\n正文。\n\n```python\nx = 2\n```\n\n结尾。"
        _ = try await PreviewTestPage.render(doc, in: webView)
        // 等高亮落地（首批同步 + idle 批）
        try await PreviewTestPage.waitUntil(
            webView, "document.querySelectorAll('#content pre code.hljs').length >= 2 ? 'ok' : 'pending'",
            timeout: 10)
        let before = try await PreviewTestPage.eval(
            "document.getElementById('content').innerHTML.length", webView)

        _ = try await PreviewTestPage.eval(
            "MEditorRender.highlightCodeBlocks(document.getElementById('content')); 1", webView)
        let buttons = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content .meditor-copy-btn').length", webView)
        XCTAssertEqual(buttons, "2", "幂等重跑不得重复挂 Copy 按钮")
        let after = try await PreviewTestPage.eval(
            "document.getElementById('content').innerHTML.length", webView)
        XCTAssertEqual(after, before, "已高亮的块重跑后 DOM 不应变化")
    }

    /// 缓存命中恢复必须补一遍高亮（幂等，快照完整时近零成本）。
    /// 用 spy 钉行为而不是赌 idle 时序：旧 bridge 的命中路径不调它，本条必红。
    func testCacheHitRestoreRunsHighlightPass() async throws {
        let webView = try await makeBridgedWebView()
        let code = "```swift\nlet x = 1\n```"
        let docA = (0..<8).map { "段落 \($0)。\n\n\(code)" }.joined(separator: "\n\n")
        let docB = "另一篇。\n\n正文。"
        let litA = try PreviewTestPage.jsStringLiteral(docA)
        let litB = try PreviewTestPage.jsStringLiteral(docB)

        _ = try await PreviewTestPage.eval("MEditor.boot(''); 1", webView)
        _ = try await PreviewTestPage.eval("MEditor.update(\(litA), 1); 1", webView)
        // 快照 idle 落盘（requestIdleCallback timeout 1500ms 封顶）——等它完成
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // 装好 spy 再走路由：命中分支必须调到它
        _ = try await PreviewTestPage.eval("""
        window.__spyCalls = 0;
        window.__origHighlight = MEditorRender.highlightCodeBlocks;
        MEditorRender.highlightCodeBlocks = function (el) {
          window.__spyCalls++;
          return window.__origHighlight(el);
        };
        1
        """, webView)
        _ = try await PreviewTestPage.eval("MEditor.update(\(litB), 2); 1", webView)
        _ = try await PreviewTestPage.eval("MEditor.update(\(litA), 3); 1", webView)

        let spyCalls = try await PreviewTestPage.eval("String(window.__spyCalls)", webView)
        XCTAssertNotEqual(spyCalls, "0", "缓存命中恢复必须补高亮（快照可能存于高亮完成前）")
        // 用户侧属性：恢复页所有代码块都有高亮
        let highlighted = try await PreviewTestPage.eval(
            "var all=document.querySelectorAll('#content pre code');"
            + "var hl=document.querySelectorAll('#content pre code.hljs').length;"
            + "all.length + '/' + hl", webView)
        // 等 idle 批跑完再断言
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let highlightedLater = try await PreviewTestPage.eval(
            "var all=document.querySelectorAll('#content pre code');"
            + "var hl=document.querySelectorAll('#content pre code.hljs').length;"
            + "all.length + '/' + hl", webView)
        let final = highlightedLater ?? highlighted
        XCTAssertEqual(final, "8/8", "缓存恢复后所有代码块必须有高亮（实际 \(final ?? "nil")）")
    }
}
