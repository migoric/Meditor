import XCTest
import WebKit

/// 预览渲染测试共用的夹具：真 WKWebView + 真渲染管线（marked / DOMPurify / render.js）。
///
/// 三条容易踩的坑都收在这里：
/// 1. **就绪判据不能用 `readyState === 'complete'`**（`loadHTMLString` 下过早 complete），
///    改等页面自己的 `#content` 元素。
/// 2. 注入 UMD 库时**脚本尾要补 `"\n;\n1;\n"`**：库的 completion value 是对象/函数，
///    WebKit 桥不回来，报 `WKErrorDomain 5`；也不能用函数包起来（顶层 `var` 就不挂
///    window 了）。
/// 3. `evaluateJavaScript` 的 `value == nil` 同时覆盖「JS 抛异常」与 undefined，
///    所以走 `withCheckedThrowingContinuation` 区分。
@MainActor
enum PreviewTestPage {

    private static var windows: [WKWebView: NSWindow] = [:]

    /// 关掉并释放所有保活的 WKWebView 宿主窗口。
    static func tearDown() {
        for (webView, window) in windows {
            window.contentView = nil
            webView.stopLoading()
        }
        windows = [:]
    }

    /// 建一个已注入完整渲染管线、并等到可用的页面。
    static func makeWebView() async throws -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let webView = WKWebView(frame: frame, configuration: config)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        windows[webView] = window

        webView.loadHTMLString(
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>"
            + "<body><div id=\"content\"></div></body></html>",
            baseURL: nil
        )
        try await waitUntil(webView, "document.getElementById('content') ? 'ok' : 'pending'", timeout: 20)

        // mermaid / katex 不注入：语料里没有对应语法，render.js 对缺失库有 typeof 守卫。
        for name in ["marked.min.js", "purify.min.js", "highlight.min.js", "scripts/render.js"] {
            try await eval(previewScript(named: name) + "\n;\n1;\n", webView)
        }
        try await waitUntil(webView, "typeof MEditorRender === 'object' ? 'ok' : 'pending'", timeout: 20)
        return (webView, window)
    }

    /// 走完整渲染入口（含 patchDOM）。
    @discardableResult
    static func render(_ markdown: String, in webView: WKWebView) async throws -> String? {
        try await eval(
            "MEditorRender.renderInto(document.getElementById('content'), \(try jsStringLiteral(markdown))); 1",
            webView
        )
    }

    /// JSON 字符串字面量即合法 JS 字面量（转义规则一致），避免手拼引号把脚本破掉。
    static func jsStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode([value])
        guard let array = String(data: data, encoding: .utf8) else {
            throw XCTSkip("字符串编码失败")
        }
        return String(array.dropFirst().dropLast())
    }

    /// 渲染计数快照（`render.js` 的 `getRenderStats`）。
    ///
    /// 用来把「缓存真的命中」这类**性能主张**钉住：产物正确性测试无法区分
    /// 「命中缓存」与「整篇重解析」，两者输出一致。
    struct RenderStats: CustomStringConvertible {
        var fullParse = 0
        var blockParse = 0
        var blockHit = 0
        var sanitize = 0
        var cacheEntries = 0
        var cacheBytes = 0

        var description: String {
            "fullParse=\(fullParse) blockParse=\(blockParse) blockHit=\(blockHit) "
            + "sanitize=\(sanitize) entries=\(cacheEntries) bytes=\(cacheBytes)"
        }
    }

    static func resetStats(_ webView: WKWebView) async throws {
        try await eval("MEditorRender.resetRenderStats(); 1", webView)
    }

    static func stats(_ webView: WKWebView) async throws -> RenderStats {
        guard let raw = try await eval("JSON.stringify(MEditorRender.getRenderStats())", webView),
              let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw XCTSkip("拿不到渲染计数：render.js 里没有 getRenderStats")
        }
        var stats = RenderStats()
        stats.fullParse = json["fullParse"] as? Int ?? 0
        stats.blockParse = json["blockParse"] as? Int ?? 0
        stats.blockHit = json["blockHit"] as? Int ?? 0
        stats.sanitize = json["sanitize"] as? Int ?? 0
        stats.cacheEntries = json["cacheEntries"] as? Int ?? 0
        stats.cacheBytes = json["cacheBytes"] as? Int ?? 0
        return stats
    }

    /// 读取仓库内的预览资源源码（marked / render.js …）。
    /// 走 `#filePath` 而不是 Bundle：`swift test` 下 `Bundle.main` 是 xctest 启动器，
    /// `PreviewResourceLocator` 解析为 nil，拿不到 Resources。
    static func previewScript(named relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // …/Tests/MEditorTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // 仓库根
            .appendingPathComponent("Sources/MEditor/Resources/Preview")
        let url = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("预览资源缺失：\(url.path)")
        }
        return text
    }

    /// 仓库根目录（测试用 `#filePath` 反推，不依赖 cwd）。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 挑选若干真实 .md 作为等价性语料（总量控制在 200KB 内，别把测试拖成分钟级）。
    static func repoMarkdownFiles() throws -> [URL] {
        let root = repoRoot
        let preferred = [
            "CHANGELOG.md", "README.md", "CONTRIBUTING.md",
            "docs/architecture.md", "docs/design.md",
        ]
        var urls: [URL] = []
        for name in preferred {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }
        if let docs = try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("docs"), includingPropertiesForKeys: nil
        ) {
            urls.append(contentsOf: docs.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }.prefix(3))
        }
        return urls
    }

    static func waitUntil(_ webView: WKWebView, _ js: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await eval(js, webView) == "ok" { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("等待超时：\(js)")
    }

    static func eval(_ js: String, _ webView: WKWebView) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value.map { "\($0)" }) }
            }
        }
    }
}
