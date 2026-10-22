import XCTest
import WebKit
@testable import MEditor

/// 块级缓存**实际覆盖面**的守卫。
///
/// 出口等价性测试（`PreviewRenderEquivalenceTests`）只保证「分块不改变产物」，
/// 对「缓存根本没命中」同样是绿的——把缓存整个删掉、每次整篇解析 + 整篇消毒，
/// 产物依然逐字节正确。所以「改一段只重算一段」这个性能主张必须用**计数**钉住，
/// 而不是靠目录里存在一个 `paragraphCache`。
///
/// 两条曾经的漏洞都在这里：
/// - `PARAGRAPH_CACHE_MAX_BLOCK = 2048`：真实文档的段落（尤其表格、带列表的小节）
///   普遍 2–5KB，等于对目标用户不生效，「改一段」实测与冷启等同；
/// - 未闭合围栏（打字刚敲下 ```）让 `splitBlocks` 返回 null ⇒ 整篇解析 + 整篇消毒。
@MainActor
final class PreviewCachedPathCoverageTests: XCTestCase {

    override func tearDown() async throws {
        PreviewTestPage.tearDown()
        try await super.tearDown()
    }

    // MARK: - 缓存覆盖面

    /// 改一段只该重算一段：文档里其余 11 段必须命中缓存。
    func testEditingOneParagraphReparsesOneBlock() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        var sections = Self.sections(count: 12, filler: 250)

        _ = try await PreviewTestPage.render(sections.joined(separator: "\n\n"), in: webView)
        try await PreviewTestPage.resetStats(webView)

        sections[5] += "改动。"
        _ = try await PreviewTestPage.render(sections.joined(separator: "\n\n"), in: webView)
        let stats = try await PreviewTestPage.stats(webView)

        XCTAssertEqual(stats.fullParse, 0, "改一段走成了整篇解析（缓存完全没命中）：\(stats)")
        XCTAssertLessThanOrEqual(stats.blockParse, 2, "改一段重算了太多块：\(stats)")
        XCTAssertGreaterThanOrEqual(stats.blockHit, 10, "未变化的段落没有命中缓存：\(stats)")
    }

    /// 打字刚敲下 ``` 的那一帧：不能整篇重解析。
    ///
    /// 这是流式写入与手动输入代码块时**每一帧**都会命中的路径，此前 `splitBlocks`
    /// 遇到未闭合围栏直接返回 null，等于每敲一个键付一次整篇 marked + 整篇消毒。
    func testTypingInsideOpenFenceDoesNotFullParse() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let body = Self.sections(count: 8, filler: 250).joined(separator: "\n\n")

        _ = try await PreviewTestPage.render(body + "\n\n```swift\nlet a = 1\n```", in: webView)
        try await PreviewTestPage.resetStats(webView)

        // 敲下一个新围栏的开栏行（未闭合）
        _ = try await PreviewTestPage.render(body + "\n\n```swift\nlet a = 1", in: webView)
        let stats = try await PreviewTestPage.stats(webView)

        XCTAssertEqual(stats.fullParse, 0, "未闭合围栏回落到了整篇解析：\(stats)")
        XCTAssertLessThanOrEqual(stats.blockParse, 1, "未闭合围栏重算了太多块：\(stats)")
    }

    /// 消毒次数不该超过重解析块数——缓存里存的是**已消毒**的 HTML，
    /// 命中缓存还再消毒一次等于把 DOMPurify 的 123ms/178KB 白省。
    func testSanitizeRunsOnlyForReparsedBlocks() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        var sections = Self.sections(count: 10, filler: 250)

        _ = try await PreviewTestPage.render(sections.joined(separator: "\n\n"), in: webView)
        try await PreviewTestPage.resetStats(webView)

        sections[3] += "改动。"
        _ = try await PreviewTestPage.render(sections.joined(separator: "\n\n"), in: webView)
        let stats = try await PreviewTestPage.stats(webView)

        XCTAssertEqual(
            stats.sanitize, stats.blockParse,
            "消毒次数与重解析块数不一致（缓存命中后又消毒了一遍）：\(stats)")
    }

    // MARK: - 语料

    private static func sections(count: Int, filler: Int) -> [String] {
        (0..<count).map { i in
            "## 第 \(i) 节\n\n" + String(repeating: "第 \(i) 段的内容写在这里。", count: filler)
        }
    }
}
