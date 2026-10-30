import UIKit
import WebKit

/// 一次性离线 HTML 渲染器：复用 macOS 预览管线（template.html + marked +
/// themes.css + render.js + render/ 模块 + bridge.js + mermaid.min.js），把 Markdown 渲染成
/// 与 macOS 发布页一致的自包含 HTML（内联 CSS + 主题 class + Mermaid SVG）。
///
/// 资源在 bundle 里是平铺的，这里在临时目录重建 css/scripts 结构后加载；
/// 用完即弃（发布是低频操作，不做常驻引擎）。
@MainActor
final class PreviewHTMLRenderer: NSObject {

    enum RenderError: LocalizedError {
        case missingResource(String)
        case loadFailed(String)
        case jsFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): return "渲染资源缺失：\(name)"
            case .loadFailed(let msg):       return "页面加载失败：\(msg)"
            case .jsFailed(let msg):         return "渲染失败：\(msg)"
            case .timedOut:                  return "渲染超时"
            }
        }
    }

    /// 渲染入口：markdown → 自包含 HTML。theme 对应 themes.css 的 theme-X class。
    static func render(markdown: String, title: String, theme: String = "github") async throws -> String {
        let stage = try stageDirectory(markdown: markdown, theme: theme)
        let renderer = PreviewHTMLRenderer()
        return try await renderer.loadAndRender(stage: stage, title: title)
    }

    // MARK: - 舞台目录（临时目录重建预览资源结构）

    private static func stageDirectory(markdown: String, theme: String) throws -> URL {
        func resource(_ name: String, _ ext: String) throws -> URL {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw RenderError.missingResource("\(name).\(ext)")
            }
            return url
        }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("meditor-share-preview", isDirectory: true)
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage.appendingPathComponent("css"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("scripts/render"), withIntermediateDirectories: true)

        let copies: [(URL, String)] = [
            (try resource("themes", "css"), "css/themes.css"),
            (try resource("base", "css"), "css/base.css"),
            (try resource("state", "js"), "scripts/render/state.js"),
            (try resource("markdown", "js"), "scripts/render/markdown.js"),
            (try resource("math", "js"), "scripts/render/math.js"),
            (try resource("mermaid", "js"), "scripts/render/mermaid.js"),
            (try resource("blocks", "js"), "scripts/render/blocks.js"),
            (try resource("dom-patch", "js"), "scripts/render/dom-patch.js"),
            (try resource("enhancements", "js"), "scripts/render/enhancements.js"),
            (try resource("render", "js"), "scripts/render.js"),
            (try resource("bridge", "js"), "scripts/bridge.js"),
            (try resource("boot", "js"), "scripts/boot.js"),
            (try resource("marked.min", "js"), "marked.min.js"),
            (try resource("purify.min", "js"), "purify.min.js"),
            (try resource("highlight.min", "js"), "highlight.min.js"),
            (try resource("mermaid.min", "js"), "mermaid.min.js"),
        ]
        for (src, rel) in copies {
            try fm.copyItem(at: src, to: stage.appendingPathComponent(rel))
        }

        var template = try String(contentsOf: resource("template", "html"), encoding: .utf8)
        // 初始内容以 JSON 数据块传递（模板 CSP 禁内联脚本）；"<" 转成
        // Unicode 转义（'\\u003c'），防止内容里的 "</script>" 提前闭合数据块。
        let contentJSON = (String(data: try JSONEncoder().encode(markdown), encoding: .utf8) ?? "\"\"")
            .replacingOccurrences(of: "<", with: "\\u003c")
        template = template
            .replacingOccurrences(of: "{{INITIAL_THEME}}", with: theme)
            .replacingOccurrences(of: "{{INITIAL_CONTENT_JSON}}", with: contentJSON)
        let page = stage.appendingPathComponent("preview.html")
        try template.write(to: page, atomically: true, encoding: .utf8)
        return stage
    }

    // MARK: - 加载与 JS 调用

    private var webView: WKWebView?
    private var navContinuation: CheckedContinuation<Result<Void, Error>, Never>?

    private func loadAndRender(stage: URL, title: String) async throws -> String {
        defer {
            webView?.navigationDelegate = nil
            webView = nil
        }
        let page = stage.appendingPathComponent("preview.html")
        return try await withTimeout {
            try await self.load(page: page)
            // 等 boot 渲染完，再把懒渲染的 Mermaid 占位全部渲染
            _ = try? await self.webView?.callAsyncJavaScript(
                "return await window.MEditor.renderAllDiagrams();",
                arguments: [:], in: nil, contentWorld: .page
            )
            let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "'", with: "\\'")
            let result = try await self.webView?.evaluateJavaScript(
                "window.MEditor && window.MEditor.getRenderedHTML('\(escaped)')")
            guard let html = result as? String, !html.isEmpty else {
                throw RenderError.jsFailed("empty result")
            }
            return html
        }
    }

    /// 总超时 30s：到点抛 timedOut（body 任务合作式取消，webview 由 defer 回收）。
    private func withTimeout(_ body: @escaping @MainActor () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask { @MainActor in
                do { return .success(try await body()) }
                catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return .failure(RenderError.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return try first.get()
        }
    }

    private func load(page: URL) async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        webView.navigationDelegate = self
        self.webView = webView
        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            navContinuation = cont
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        try result.get()
    }
}

extension PreviewHTMLRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeNav(.success(()))
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeNav(.failure(RenderError.loadFailed(error.localizedDescription)))
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeNav(.failure(RenderError.loadFailed(error.localizedDescription)))
    }

    /// WKNavigationDelegate 回调在主线程；仅恢复一次（didFail 与 didFinish 都可能来）。
    private nonisolated func resumeNav(_ result: Result<Void, Error>) {
        MainActor.assumeIsolated {
            guard let cont = navContinuation else { return }
            navContinuation = nil
            cont.resume(returning: result)
        }
    }
}
