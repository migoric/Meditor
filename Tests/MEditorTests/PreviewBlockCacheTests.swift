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

    func testUnterminatedFenceFallsBackToFullParse() async throws {
        // AI 流式写入 / 编辑中途会出现未闭合围栏：切块会把后续内容误当正文，
        // 必须退回整篇解析（marked 会把余下内容当代码）。
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
        XCTAssertEqual(parsed.count, 1, "未闭合围栏必须整篇解析，实际解析了 \(parsed.count) 块")

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

    /// 载入 marked + DOMPurify + render.js（真渲染管线，与 template.html 同源）。
    /// mermaid / katex 不加载：语料里没有对应语法，render.js 对缺失库有 typeof 守卫。
    private func makePage() async throws -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let webView = WKWebView(frame: frame, configuration: config)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        Self.windows[webView] = window

        webView.loadHTMLString(
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>"
            + "<body><div id=\"content\"></div></body></html>",
            baseURL: nil
        )
        // 就绪判据用页面自己的元素，不用 readyState（loadHTMLString 下它过早 complete）
        try await waitUntil(webView, "document.getElementById('content') ? 'ok' : 'pending'", timeout: 20)

        for name in ["marked.min.js", "purify.min.js", "highlight.min.js", "scripts/render.js"] {
            // 末尾补 `1`：UMD 库的 completion value 是对象/函数，WebKit 桥不回来
            // （WKErrorDomain 5「返回结果的类型不受支持」），而脚本顶层的 `var`
            // 不能被函数包起来（包了就不是 window 上的全局了）。
            try await eval(try Self.previewScript(named: name) + "\n;\n1;\n", webView)
        }
        try await waitUntil(webView, "typeof MEditorRender === 'object' ? 'ok' : 'pending'", timeout: 20)

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

    private static func previewScript(named relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)          // …/Tests/MEditorTests/<this>.swift
            .deletingLastPathComponent()                    // …/Tests/MEditorTests
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("Sources/MEditor/Resources/Preview")
        let url = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("预览资源缺失：\(url.path)")
        }
        return text
    }

    private func waitUntil(_ webView: WKWebView, _ js: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await eval(js, webView) == "ok" { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("等待超时：\(js)")
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
