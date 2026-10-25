import XCTest
import WebKit
@testable import MEditor

/// 缓存命中恢复路径上的 mermaid 懒渲染。
///
/// bug：`renderMermaidDiagrams` 给每个占位挂 IntersectionObserver，只画滚进视口的图；
/// 缓存命中时 bridge 会 `contentEl.innerHTML = entry.html` 整体替换 DOM —— 上一轮挂的
/// 观察器随旧节点一起失效，没滚到的那几张从此没人管，**永久空白**。
///
/// 为什么要走 bridge 而不是直接测 `renderInto`：`renderInto` 每次重新提取 + 重挂，
/// 那条路径本来就是对的；错的只有「快照恢复」这一支，它住在 `bridge.js` 里。
///
/// 夹具里没有真 mermaid.min.js（3.3MB，不进测试），也不指望 IntersectionObserver
/// 在不可见窗口里真的回调（实测不回调）。两个都换成桩，把「哪张图滚进了视口」
/// 变成测试可以主动触发的一步 —— 这样「快照里留着一张占位」和「恢复后还能再画」
/// 都是确定性的，不靠布局和可见性。
@MainActor
final class PreviewMermaidCacheRestoreTests: XCTestCase {

    /// mermaid 桩：只负责把占位换成 `<svg>`。
    /// 真库在夹具里加载失败会把占位直接换成 `.error-block`，那样就复现不出
    /// 「快照里留着占位」这个前提。
    private let libraryStubs = """
    window.mermaid = {
      initialize: function () {},
      render: function (id) {
        return Promise.resolve({ svg: '<svg class="fake-mermaid" id="' + id + '-svg"></svg>' });
      }
    };
    // IntersectionObserver 桩：只登记，不自动触发。测试用 __flushIO(id) 决定
    // 哪张图「滚进了视口」。真实 IO 在不可见窗口里根本不回调，用它测不出时序。
    window.__io = { queue: [] };
    window.IntersectionObserver = function (cb) {
      this.observe = function (el) { window.__io.queue.push({ cb: cb, el: el }); };
      this.unobserve = function () {};
      this.disconnect = function () {};
    };
    window.__flushIO = function (onlyId) {
      var pending = window.__io.queue;
      window.__io.queue = [];
      pending.forEach(function (entry) {
        if (onlyId && entry.el.id !== onlyId) { window.__io.queue.push(entry); return; }
        entry.cb([{ isIntersecting: true, target: entry.el }], { unobserve: function () {} });
      });
      return window.__io.queue.length;
    };
    window.__ioQueueIDs = function () {
      return window.__io.queue.map(function (e) { return e.el.id; }).join(',');
    }; 1
    """

    /// 两张图：第一张由测试显式「滚进视口」画出来，第二张留在占位状态被写进快照。
    private let docWithDiagrams = """
    # 甲

    ```mermaid
    graph TD; A-->B;
    ```

    中间正文。

    ```mermaid
    graph TD; C-->D;
    ```
    """

    private let docWithoutDiagrams = "# 乙\n\n只是普通段落。\n"

    override func tearDown() async throws {
        PreviewTestPage.tearDown()
        try await super.tearDown()
    }

    func testCacheHitRestoresMermaidLazyRender() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView(includeBridge: true)
        try await PreviewTestPage.eval(libraryStubs, webView)

        let a = try PreviewTestPage.jsStringLiteral(docWithDiagrams)
        let b = try PreviewTestPage.jsStringLiteral(docWithoutDiagrams)

        try await eval("MEditor.boot(''); 1", webView)
        try await eval("MEditor.update(\(a), 1); 1", webView)

        // 两张图都挂上了懒渲染观察器。
        try await waitFor("__ioQueueIDs() === 'mermaid-0,mermaid-1'", webView, timeout: 10,
                          "首帧应该给两张图各挂一个观察器")
        // 只让第一张滚进视口。
        _ = try await eval("__flushIO('mermaid-0'); 1", webView)
        try await waitFor("document.querySelectorAll('#content .mermaid-container').length === 1",
                          webView, timeout: 10, "第一张图没画出来")
        let placeholdersBeforeSnapshot = try await count("#content .mermaid-placeholder", webView)
        XCTAssertEqual(placeholdersBeforeSnapshot, 1, "第二张还没滚到，应该仍是占位")

        // 等 bridge 的 LRU 快照落盘（requestIdleCallback 有 1500ms 兜底超时）。
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 切到无双图文档：`latestDiagrams` 被清空，DOM 也换成没有占位的正文。
        try await eval("MEditor.update(\(b), 2); 1", webView)
        let afterSwitchToPlainDoc = try await diagramCount(webView)
        XCTAssertEqual(afterSwitchToPlainDoc, 0, "B 没有图，提取结果必须是 0")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 切回 A：这次走缓存命中（DOM 直接从快照恢复，不走 renderInto）。
        // 旧的观察器已随 innerHTML 一起失效，但桩不会自己清理，所以队列里还留着它。
        let queuedBeforeCacheHit = try await intEval("__io.queue.length", webView)
        XCTAssertEqual(queuedBeforeCacheHit, 1, "此时队列里只剩第二张图的占位观察器")

        try await PreviewTestPage.resetStats(webView)
        try await eval("MEditor.update(\(a), 3); 1", webView)

        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(
            stats.blockParse + stats.fullParse, 0,
            "第三次加载不是缓存命中（\(stats)）⇒ 前两次的快照没落盘，本用例的前提不成立"
        )
        let placeholdersAfterCacheHit = try await count("#content .mermaid-placeholder", webView)
        XCTAssertEqual(
            placeholdersAfterCacheHit, 1,
            "快照复原的正是那张没滚到的占位 —— 旧观察器已经随旧 DOM 一起失效了"
        )

        // 核心断言：恢复路径必须把观察器重新挂回占位。
        // 不挂的话这张图再也不会被画 —— 线上表现就是滚到那儿也是空白。
        try await waitFor("__io.queue.length === \(queuedBeforeCacheHit + 1)", webView, timeout: 10,
                          "缓存命中后没给残留占位重挂懒渲染观察器（滚到图的位置也永远不画）")
        let rearmedID = try await eval("__io.queue[__io.queue.length - 1].el.id", webView)
        XCTAssertEqual(rearmedID, "mermaid-1", "重挂的必须是那张仍在占位状态的图")

        // 用户动作：滚到第二张图。
        _ = try await eval("__flushIO(); 1", webView)
        try await waitFor("document.querySelectorAll('#content .mermaid-placeholder').length === 0",
                          webView, timeout: 10, "第二张图滚进视口后没渲染")
        let containers = try await count("#content .mermaid-container", webView)
        XCTAssertEqual(containers, 2, "两张图都该画出来")
    }

    private func diagramCount(_ webView: WKWebView) async throws -> Int {
        guard let raw = try await eval("MEditorRender.getMermaidDiagrams().length", webView) else {
            throw XCTSkip("拿不到 mermaid 提取结果")
        }
        return Int(raw) ?? -1
    }

    private func count(_ selector: String, _ webView: WKWebView) async throws -> Int {
        let literal = try PreviewTestPage.jsStringLiteral(selector)
        return try await intEval("document.querySelectorAll(\(literal)).length", webView)
    }

    private func intEval(_ js: String, _ webView: WKWebView) async throws -> Int {
        guard let raw = try await eval(js, webView), let value = Int(raw) else {
            throw XCTSkip("拿不到整数结果：\(js)")
        }
        return value
    }

    /// 轮询直到表达式为真。
    ///
    /// 不要拿 `eval(expr) == "true"` 判：JS 布尔经桥回传是 `NSNumber`，字符串化
    /// 得到的是 `"1"`/`"0"`，永远等不到 `"true"`（踩过）。统一包成 'ok'/'pending'。
    private func waitFor(_ condition: String, _ webView: WKWebView, timeout: TimeInterval, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await eval("(\(condition)) ? 'ok' : 'pending'", webView) == "ok" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail(message)
    }

    @discardableResult
    private func eval(_ js: String, _ webView: WKWebView) async throws -> String? {
        try await PreviewTestPage.eval(js, webView)
    }
}
