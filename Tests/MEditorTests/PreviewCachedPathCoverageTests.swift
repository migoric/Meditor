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

    /// 合并相邻块的成本必须是**线性**的。
    ///
    /// `mergeUnsafeBoundaries` 曾经每轮把**整组拼平再重扫**：`hasListItemLine` 内部
    /// `split('\n')`、`spanningState` 的 `indexOf`、`elemState` 的两次 `match`，
    /// 四条判据都是 O(整组)。一份 240KB 的松散列表会被切成约 8,000 块、块块都要合并
    /// ⇒ 实测 **888ms**，而同一份文档的整篇解析只要 **70ms** —— 优化比不优化慢 12 倍，
    /// 且随规模平方增长（120KB 时 250ms、240KB 时 888ms）。
    ///
    /// 现在组内用 `parts` 数组累积、最后一次性 `join`，判据改成随合并增量维护的摘要。
    ///
    /// 断言用**与整篇解析的比值**而不是绝对耗时：CI 机器快慢不定，但同机同轮的两个
    /// 数之比是稳定的。平方退化会把这个比值从 ~1 拉到 10 以上。
    func testMergeStaysLinearOnListItemHeavyDocuments() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let raw = try await PreviewTestPage.eval(#"""
        (function () {
          function build(kind, target) {
            var s = '', i = 0;
            while (s.length < target) {
              i++;
              s += kind === 'loose'
                ? '- 第 ' + i + ' 条：松散列表，项与项之间有空行，这是技术文档的常见写法。\n\n'
                : '- 一级 ' + i + '\n  - 二级\n    - 三级\n      - 四级\n\n';
            }
            return s;
          }
          function median(xs) {
            var t = xs.slice().sort(function (a, b) { return a - b; });
            return t[(t.length / 2) | 0];
          }
          function bench(fn) {
            fn(); fn();
            var t = [];
            for (var i = 0; i < 3; i++) { var t0 = performance.now(); fn(); t.push(performance.now() - t0); }
            return median(t);
          }
          var out = {};
          var kinds = ['loose', 'nested'];
          for (var k = 0; k < kinds.length; k++) {
            var src = build(kinds[k], 240 * 1024);
            out[kinds[k]] = {
              chars: src.length,
              full: bench(function () { MEditorRender.renderMarkdown(src); }),
              cached: bench(function () { MEditorRender.renderMarkdownCached(src); })
            };
          }
          return JSON.stringify(out);
        })()
        """#, webView)

        guard let raw, let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else {
            XCTFail("拿不到压测结果：\(raw ?? "nil")")
            return
        }

        for kind in ["loose", "nested"] {
            guard let entry = json[kind],
                  let chars = entry["chars"] as? Int,
                  let full = entry["full"] as? Double,
                  let cached = entry["cached"] as? Double
            else {
                XCTFail("缺少 \(kind) 的测量结果")
                continue
            }
            // 240KB 的整篇解析不会低于 10ms（本机 ~70ms），用它兜住除零与噪声
            let baseline = max(full, 10)
            XCTAssertLessThan(
                cached, baseline * 2.5,
                "\(kind) 240KB（\(chars) 字符）块路径 \(cached)ms vs 整篇 \(full)ms："
                + "合并退化成平方了（见 mergeUnsafeBoundaries 的注释）")
        }
    }

    // MARK: - 语料

    private static func sections(count: Int, filler: Int) -> [String] {
        (0..<count).map { i in
            "## 第 \(i) 节\n\n" + String(repeating: "第 \(i) 段的内容写在这里。", count: filler)
        }
    }
}
