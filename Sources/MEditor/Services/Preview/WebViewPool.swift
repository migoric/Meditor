import WebKit

/// Pre-warms a WKWebView with the full preview template + assets loaded,
/// so the first file open gets instant rendering (~200ms saved).
///
/// The key insight: warmUp uses the SAME cache directory and resource
/// copying logic as the real preview, so the pooled webview can be
/// directly reused with all CSS/JS already parsed and ready.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()

    private(set) var warmedView: WKWebView?
    private(set) var isReady = false
    /// 镜像/写盘正在进行（避免 `bootSequence` 与 `dequeue` 的重填重复触发）。
    private var isPreparing = false

    let cacheDir: URL = {
        let cachesDir = FileManager.default.firstURL(for: .cachesDirectory)
        return cachesDir.appendingPathComponent("com.meditor.preview", isDirectory: true)
    }()

    private init() {}

    /// Pre-create WKWebView + load template with all assets. Call at app launch.
    ///
    /// 资源镜像与 `preview.html` 的生成一律交给 `PreviewAssetMirror.prepareHTML`。
    /// 这里曾经自己抄了一份「缺了才 `copyItem`」的逻辑，与
    /// `PreviewAssetMirror.mirrorAssets`（hard-link + 按源/目标 mtime 判刷新）
    /// 是两套实现：后果是**预热缓存永不刷新**——升级后残留的旧 CSS/JS 会一直
    /// 喂给第一个预览（`fileExists` 就跳过，`shouldRefresh` 无从生效），
    /// 而且那 856KB 的拷贝发生在主线程（`bootSequence` 的第一步）。
    ///
    /// 现在镜像与写盘挪到后台，主线程只负责建 WebView 和发起导航。
    func warmUp() {
        guard warmedView == nil, !isPreparing else { return }
        isPreparing = true
        let cacheDir = self.cacheDir
        Task.detached(priority: .utility) {
            let fileURL = PreviewAssetMirror.prepareHTML(
                initialContent: "",
                theme: .github,
                cacheDir: cacheDir
            )
            await MainActor.run { self.beginLoading(fileURL: fileURL) }
        }
    }

    /// 主线程收尾：建 WKWebView 并加载刚写好的 `preview.html`。
    private func beginLoading(fileURL: URL?) {
        isPreparing = false
        guard warmedView == nil else { return }
        // 资源定位失败（打包缺文件）时不置位，下次还能重试。
        guard let fileURL else { return }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MeditorAssetSchemeHandler(), forURLScheme: MeditorAssetSchemeHandler.scheme)
        config.userContentController = WKUserContentController()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(fileURL, allowingReadAccessTo: cacheDir)

        warmedView = webView
        isReady = false

        // Mark ready after navigation finishes (template + JS parsed)
        webView.navigationDelegate = ReadyDetector.shared
    }

    /// Dequeue a fully-ready webview. Returns nil if not ready or empty.
    func dequeue() -> WKWebView? {
        guard isReady, let view = warmedView else { return nil }
        warmedView = nil
        isReady = false
        view.navigationDelegate = nil
        // Refill pool for next use
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.warmUp()
        }
        return view
    }

    func markReady() {
        isReady = true
        // Pre-warm JS engines in the pooled webview:
        // 1. Load hljs so code highlighting is instant
        // 2. Run a dummy marked.parse to JIT-compile marked's regex patterns
        warmedView?.evaluateJavaScript("""
            (function() {
                if (typeof hljs === 'undefined') {
                    var s = document.createElement('script');
                    s.src = 'highlight.min.js';
                    document.head.appendChild(s);
                }
                if (typeof marked !== 'undefined') {
                    marked.parse('# warm\\n\\ntext **bold** `code`\\n\\n```js\\nvar x=1;\\n```\\n');
                }
            })();
        """, completionHandler: nil)
    }
}

/// Detects when the pooled webview finishes loading.
private class ReadyDetector: NSObject, WKNavigationDelegate {
    static let shared = ReadyDetector()
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            WebViewPool.shared.markReady()
        }
    }
}
