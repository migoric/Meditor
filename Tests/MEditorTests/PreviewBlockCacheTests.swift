import XCTest
import WebKit
@testable import MEditor

/// 预览块级缓存的覆盖面：**含围栏代码块的文档也必须命中缓存**。
///
/// 技术文档几乎必然有代码块，而旧实现的判据是「文档任意位置出现围栏 ⇒ 整篇
/// 重解析」，等于缓存对目标用户基本失效（757KB 实测 `marked.parse` 98.7ms，
/// 每轮防抖更新重付一次）。
///
/// 这里跑真实渲染管线（marked + DOMPurify + render.js，真 WKWebView），
/// 通过包裹 `marked.parse` 数出「这一轮解析了几块、解析的是哪些源码」——
/// 这是唯一能直接观测「缓存是否命中」的口径，只看输出 HTML 看不出来
/// （整篇解析和逐块解析的产物本来就该一致）。
@MainActor
final class PreviewBlockCacheTests: XCTestCase {

    private static var windows: [WKWebView: NSWindow] = [:]

    override func tearDown() {
        for (webView, window) in Self.windows {
            window.contentView = nil
            webView.stopLoading()
        }
        Self.windows = [:]
        super.tearDown()
    }

    // MARK: - 语料

    /// 6 块，其中代码块内含空行（旧实现就是在这一步整篇放弃缓存）。
    private let doc = """
    # 标题

    第一段文字。

    ```swift
    let a = 1

    let b = 2
    ```

    第二段文字。

    - 列表项一
    - 列表项二

    第三段文字。
    """

    // MARK: - 用例

    func testFencedCodeBlockDoesNotDisableBlockCache() async throws {
        let (webView, _) = try await makePage()
        _ = try await render(doc, in: webView)

        let parsed: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(parsed.count, 6, "6 个块应各自解析一次；整篇只解析一次说明块缓存没有生效")
        XCTAssertTrue(
            parsed.allSatisfy { $0.count < doc.count / 2 },
            "有解析调用拿到了接近全文的源码 ⇒ 退回了整篇解析：\(parsed.map(\.count))"
        )
        XCTAssertTrue(
            parsed.contains { $0.contains("let a = 1") && $0.contains("let b = 2") },
            "代码块（含内部空行）应被当成**一整块**送出解析"
        )

        // 渲染结果侧：一个 pre、代码两行都在、没有漏出来的围栏标记
        let preCount = try await eval("document.querySelectorAll('#content pre').length", webView)
        XCTAssertEqual(preCount, "1")

        let codeText = try await eval("document.querySelector('#content pre code').textContent.trim()", webView)
        XCTAssertEqual(codeText, "let a = 1\n\nlet b = 2")

        let leakedFence = try await eval("document.getElementById('content').textContent.indexOf('```')", webView)
        XCTAssertEqual(leakedFence, "-1", "围栏被切碎后会把 ``` 漏成正文")
    }

    func testEditingOneParagraphReparsesOnlyThatBlock() async throws {
        let (webView, _) = try await makePage()
        _ = try await render(doc, in: webView)

        let edited = doc.replacingOccurrences(of: "第二段文字。", with: "第二段文字改。")
        _ = try await eval("window.__reset(); 1", webView)
        _ = try await render(edited, in: webView)

        let parsed: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(parsed, ["第二段文字改。"], "只改一段却重解析了：\(parsed)")

        let codeText = try await eval("document.querySelector('#content pre code').textContent.trim()", webView)
        XCTAssertEqual(codeText, "let a = 1\n\nlet b = 2", "增量 patch 不该丢掉代码块")
    }

    func testUnterminatedFenceParsesTailAsOneBlock() async throws {
        // AI 流式写入 / 编辑中途会出现未闭合围栏。此前这里回退**整篇**解析——
        // 那是「刚敲下 ``` 」那一帧的代价（66KB 文档整篇 marked + 整篇消毒 36ms）。
        // 现在把「开栏行到文末」整体算一块：CommonMark 里未闭合围栏本来就吞到文末，
        // 单独解析这一段与整篇解析该段的结果相同，前面的块还能照常命中缓存。
        let streaming = """
        # 标题

        第一段文字。

        第二段文字。

        ```swift
        let x = 1
        """
        let (webView, _) = try await makePage()
        _ = try await render(streaming, in: webView)

        let parsed: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(parsed.count, 4, "应是「3 个普通块 + 未闭合围栏一块」，实际 \(parsed.count) 块：\(parsed)")
        XCTAssertEqual(parsed.last?.hasPrefix("```swift"), true, "未闭合围栏没有整体成块：\(parsed.last ?? "nil")")
        XCTAssertEqual(parsed.last?.contains("let x = 1"), true, "围栏内容被切出去了：\(parsed.last ?? "nil")")

        let codeText = try await eval("document.querySelector('#content pre code').textContent.trim()", webView)
        XCTAssertEqual(codeText, "let x = 1")
    }

    func testIndentedFenceFallsBackToFullParse() async throws {
        // 4 空格缩进的围栏通常在列表项里，单独切出来会丢掉列表上下文；
        // 这类文档退回整篇解析（与支持围栏前一致）。
        let listWithCode = """
        第一段文字。

        - 步骤一

        - 步骤二

            ```bash
            echo a

            echo b
            ```

        第二段文字。
        """
        let (webView, _) = try await makePage()
        _ = try await render(listWithCode, in: webView)

        let parsed: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(parsed.count, 1, "带缩进围栏的文档应整篇解析，实际解析了 \(parsed.count) 块")
    }

    func testBlankLineSeparatedBlocksStillCachedWithoutFences() async throws {
        // 回归对照：不含围栏的普通文档行为不变（逐块解析 + 只重解析改动块）。
        let plain = "# 标题\n\n第一段。\n\n第二段。\n\n第三段。\n"
        let (webView, _) = try await makePage()
        _ = try await render(plain, in: webView)

        let first: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(first.count, 4)

        _ = try await eval("window.__reset(); 1", webView)
        _ = try await render(plain.replacingOccurrences(of: "第二段。", with: "第二段改。"), in: webView)
        let second: [String] = try await strings("window.__srcs", webView)
        XCTAssertEqual(second, ["第二段改。"])
    }

    // MARK: - 夹具

    private func render(_ markdown: String, in webView: WKWebView) async throws -> String? {
        let literal = try Self.jsStringLiteral(markdown)
        return try await eval(
            "MEditorRender.renderInto(document.getElementById('content'), \(literal)); 1",
            webView
        )
    }

    private func strings(_ js: String, _ webView: WKWebView) async throws -> [String] {
        guard let raw = try await eval("JSON.stringify(\(js))", webView),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// JSON 字符串字面量即合法 JS 字面量（转义规则一致）。
    private static func jsStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode([value])
        guard let array = String(data: data, encoding: .utf8) else {
            throw XCTSkip("字符串编码失败")
        }
        return String(array.dropFirst().dropLast())
    }

    /// 复用生产模板的有序模块清单，再包裹 marked.parse 观测实际分块。
    private func makePage() async throws -> (WKWebView, NSWindow) {
        let (webView, window) = try await PreviewTestPage.makeWebView()
        Self.windows[webView] = window

        // 观测点：数出每轮 marked.parse 的入参源码
        try await eval("""
        window.__srcs = [];
        window.__reset = function () { window.__srcs = []; };
        window.__realParse = marked.parse;
        marked.parse = function (src, opts) {
          window.__srcs.push(String(src));
          return window.__realParse.call(marked, src, opts);
        };
        1
        """, webView)
        return (webView, window)
    }

    private func eval(_ js: String, _ webView: WKWebView) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value.map { "\($0)" }) }
            }
        }
    }
}
