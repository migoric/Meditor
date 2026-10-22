import XCTest
import WebKit
@testable import MEditor

/// 预览渲染的**分相压测**（parse / sanitize / DOM 插入 / 端到端各花多少）。
///
/// 这是压测不是断言：只在 `MEDITOR_PREVIEW_BENCH=1` 时跑，结果 print 出来人工读，
/// 不进 CI（wall time 在 runner 上不稳定；回归门禁走 `renderStats` 计数那套）。
/// node 侧的纯 JS 基准见 `tools/bench_render.js`——那边量不到 DOMPurify 与 DOM，
/// 这边的分工就是补上这两相。
@MainActor
final class PreviewRenderBenchTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEDITOR_PREVIEW_BENCH"] == "1",
            "压测用例：MEDITOR_PREVIEW_BENCH=1 时才跑"
        )
    }

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    /// 页面内注入一次的分相计时函数：对同一份文本分别量
    /// marked.parse / DOMPurify.sanitize / renderMarkdown 全链 / innerHTML+布局 /
    /// renderInto 端到端，多轮取中位数，返回 `|` 分隔的一行。
    private func installBench(_ webView: WKWebView) async throws {
        _ = try await PreviewTestPage.eval("""
        window.__benchPhase = function (text, rounds) {
          function med(a) { a = a.slice().sort(function (x, y) { return x - y; }); return a[a.length >> 1]; }
          function time(fn) { fn(); var s = []; for (var i = 0; i < rounds; i++) { var t0 = performance.now(); fn(); s.push(performance.now() - t0); } return med(s); }
          var c = document.getElementById('content');
          var parse = time(function () { marked.parse(text, { gfm: true, breaks: false }); });
          var html = marked.parse(text, { gfm: true, breaks: false });
          var sanitize = time(function () { DOMPurify.sanitize(html); });
          var full = time(function () { MEditorRender.renderMarkdown(text); });
          var dom = time(function () { c.innerHTML = html; void c.offsetHeight; });
          var into = time(function () { MEditorRender.renderInto(c, text); });
          return [parse, sanitize, full, dom, into].map(function (x) { return x.toFixed(2); }).join('|');
        };
        1
        """, webView)
    }

    private func bench(_ name: String, _ text: String, _ webView: WKWebView) async throws {
        let literal = try PreviewTestPage.jsStringLiteral(text)
        guard let row = try await PreviewTestPage.eval("window.__benchPhase(\(literal), 5)", webView) else {
            XCTFail("bench 返回空：\(name)")
            return
        }
        let kb = Double(text.utf8.count) / 1024.0
        print("BENCH|\(name)|\(String(format: "%.1f", kb))|\(row)")
    }

    func testPhaseDistribution() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        try await installBench(webView)

        // 真实语料
        for url in try PreviewTestPage.repoMarkdownFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try await bench("real:\(url.lastPathComponent)", text, webView)
        }

        // 合成病态语料（与 tools/bench_render.js 同形，便于两侧对照）
        let para = String(repeating: "这是一段普通的正文，包含**加粗**、`行内代码` 与 [链接](https://example.com)。", count: 3)
        let bigParas = (0..<3000).map { _ in para }.joined(separator: "\n\n")
        try await bench("synth:段落×3000", bigParas, webView)

        let looseList = (0..<2000).map { "- 第 \($0) 项：**加粗** 与 `code`" }.joined(separator: "\n\n")
        try await bench("synth:松散列表×2000", looseList, webView)

        let code = "```swift\n" + String(repeating: "let x = compute(array.map { $0 * 2 }) // 注释\n", count: 12) + "```"
        let mixed = (0..<150).map { _ in [para, code, "| a | b |\n| - | - |\n| 1 | 2 |", "> 引用"].joined(separator: "\n\n") }
            .joined(separator: "\n\n")
        try await bench("synth:混合大餐", mixed, webView)
    }
}
