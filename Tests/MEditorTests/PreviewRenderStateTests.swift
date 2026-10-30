import XCTest
import WebKit

/// 共享渲染状态的独立边界：单块上限、总预算和 FIFO 淘汰。
@MainActor
final class PreviewRenderStateTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    func testCacheRejectsOversizedBlocksAndEvictsOldestWithinBudget() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let result = try await PreviewTestPage.eval("""
        (function () {
          var core = MEditorRenderCore;
          core.cachePut('oldest', '<p>old</p>');
          var initiallyReadable = core.cacheGet('oldest') === '<p>old</p>';
          var oversized = new Array(256 * 1024 + 2).join('x');
          core.cachePut(oversized, '<p>too large</p>');
          var rejected = core.cacheGet(oversized) === null;
          var lastKey = '';
          for (var i = 0; i < 30; i++) {
            lastKey = i + ':' + new Array(200 * 1024).join('x');
            core.cachePut(lastKey, '<p>' + i + '</p>');
          }
          var stats = core.cacheStats();
          return initiallyReadable + '/' + rejected + '/' + (core.cacheGet('oldest') === null)
            + '/' + (core.cacheGet(lastKey) !== null) + '/' + (stats.bytes <= 4 * 1024 * 1024)
            + '/' + (stats.entries > 0);
        })()
        """, webView)
        XCTAssertEqual(result, "true/true/true/true/true/true")
    }
}
