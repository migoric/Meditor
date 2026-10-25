import SwiftUI
@preconcurrency import WebKit
@preconcurrency import AppKit

/// 从 selectionchange 消息体解析选区的视口位置（用于把操作浮动条放到选区旁边）。
func previewSelectionRect(from body: [String: Any]) -> CGRect {
    guard let t = body["top"] as? Double, let l = body["left"] as? Double,
          let b = body["bottom"] as? Double, let r = body["right"] as? Double,
          r > l || b > t else { return .zero }
    return CGRect(x: l, y: t, width: r - l, height: b - t)
}

/// Renders Markdown content inside a long-lived `WKWebView`.
///
/// Loads `template.html` once, then uses `MEditor.update(content)` JS calls
/// to replace the rendered body in place — avoiding full-page reloads and
/// preserving scroll position.
struct MarkdownWebPreview: View {
    let content: String
    let contentRevision: Int
    var theme: PreviewTheme = .github
    /// Source line to scroll the preview to (editor→preview sync). -1 = none.
    var scrollToLine: Int = -1
    /// Monotonic token so the same target line can be requested more than once.
    var scrollRequestID: Int = 0
    /// Reports the data-source-line of the topmost visible anchor when the
    /// user scrolls inside the preview (preview→editor sync).
    var onVisibleLineChange: ((Int) -> Void)? = nil
    /// Reports extracted TOC items after each render.
    var onTOCUpdate: (([TOCItem]) -> Void)? = nil
    var exporter: PreviewExporter? = nil
    /// Source file URL — used to set <base href> so relative resources
    /// (images, links) in markdown resolve against the source directory.
    var sourceURL: URL? = nil
    /// Preview font size in px (from settings).
    var fontSize: Int = 15
    var findController: PreviewFindController? = nil
    var onSelectionChange: ((String, CGRect) -> Void)? = nil
    /// 右键菜单：将选中文字新增为待办
    var onAddTodo: ((String) -> Void)? = nil

    var body: some View {
        MarkdownWebView(
            content: content,
            contentRevision: contentRevision,
            theme: theme,
            scrollToLine: scrollToLine,
            scrollRequestID: scrollRequestID,
            onVisibleLineChange: onVisibleLineChange,
            onTOCUpdate: onTOCUpdate,
            exporter: exporter,
            sourceURL: sourceURL,
            fontSize: fontSize,
            findController: findController,
            onSelectionChange: onSelectionChange,
            onAddTodo: onAddTodo
        )
    }
}

/// A single heading entry extracted from the rendered preview.
struct TOCItem: Identifiable, Equatable {
    /// 稳定 id：同一标题行在编辑过程中保持同一行号，ForEach 才能原地更新而不是
    /// 整表重建（此前用 `let id = UUID()`，每次 payload 都是新 id，滚动位置会丢）。
    var id: Int { line }
    let level: Int
    let title: String
    let line: Int
}

// MARK: - WKWebView wrapper

/// 供 `MarkdownWebPreview` 使用的 NSViewRepresentable。
///
/// 不是 `private`：`PreviewLinkDelegateWiringTests` 要在运行时检查它的
/// `Coordinator` 是否把 `webView:decidePolicyForNavigationAction:decisionHandler:`
/// 导出成了 @objc selector——这个检查是唯一能抓住「签名 nearly matches ⇒
/// delegate 静默失效」的手段（见 `PreviewLinkNavigator.decidePolicy` 的注释）。
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let contentRevision: Int
    let theme: PreviewTheme
    let scrollToLine: Int
    let scrollRequestID: Int
    let onVisibleLineChange: ((Int) -> Void)?
    let onTOCUpdate: (([TOCItem]) -> Void)?
    let exporter: PreviewExporter?
    let sourceURL: URL?
    let fontSize: Int
    let findController: PreviewFindController?
    var onSelectionChange: ((String, CGRect) -> Void)? = nil
    var onAddTodo: ((String) -> Void)? = nil

    static let scrollHandlerName = "scrollHandler"
    static let copyHandlerName = "copyHandler"
    static let tocHandlerName = "tocHandler"
    static let perfHandlerName = "perfHandler"
    static let selectionHandlerName = "selectionHandler"
    static let escapeHandlerName = "escapeHandler"

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onVisibleLineChange: onVisibleLineChange,
            onTOCUpdate: onTOCUpdate,
            exporter: exporter,
            findController: findController,
            onSelectionChange: onSelectionChange,
            onAddTodo: onAddTodo
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        // Try to reuse pre-warmed webview (same cache dir, template already loaded).
        if let pooled = WebViewPool.shared.dequeue() {
            let uc = pooled.configuration.userContentController
            uc.removeAllScriptMessageHandlers()
            uc.add(context.coordinator, name: Self.scrollHandlerName)
            uc.add(context.coordinator, name: Self.copyHandlerName)
            uc.add(context.coordinator, name: Self.tocHandlerName)
            uc.add(context.coordinator, name: Self.perfHandlerName)
            uc.add(context.coordinator, name: Self.selectionHandlerName)
            uc.add(context.coordinator, name: Self.escapeHandlerName)
            pooled.navigationDelegate = context.coordinator
            pooled.uiDelegate = context.coordinator
            pooled.setAccessibilityLabel(L("preview.empty"))
            context.coordinator.webView = pooled
            context.coordinator.lastContentRevision = contentRevision
            context.coordinator.lastTheme = theme
            context.coordinator.isReady = true
            exporter?.webView = pooled
            findController?.register(webView: pooled, for: .markdown)

            // Apply theme + push content (webview is already loaded and ready)
            pooled.evaluateJavaScript(JSBridge.call("setTheme", args: [theme.rawValue]), completionHandler: nil)
            if let sourceDir = sourceURL?.deletingLastPathComponent() {
                let baseURL = MeditorAssetSchemeHandler.baseURLString(forDirectory: sourceDir)
                pooled.evaluateJavaScript(JSBridge.call("setBaseURL", args: [baseURL]), completionHandler: nil)
            }
            // Pooled WebView skips didFinish, so inject the selection listener here.
            // The JS is idempotent (guarded by _meditorSelListenerInstalled).
            pooled.evaluateJavaScript(Coordinator.selectionListenerJS, completionHandler: nil)
            context.coordinator.scheduleContentUpdate(content, revision: contentRevision, immediately: true)
            return pooled
        }

        // Cold path: create fresh webview.
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MeditorAssetSchemeHandler(), forURLScheme: MeditorAssetSchemeHandler.scheme)
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: Self.scrollHandlerName)
        userContent.add(context.coordinator, name: Self.copyHandlerName)
        userContent.add(context.coordinator, name: Self.tocHandlerName)
        userContent.add(context.coordinator, name: Self.perfHandlerName)
        userContent.add(context.coordinator, name: Self.selectionHandlerName)
        userContent.add(context.coordinator, name: Self.escapeHandlerName)
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(L("preview.empty"))
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastContentRevision = contentRevision
        context.coordinator.lastTheme = theme
        exporter?.webView = webView
        findController?.register(webView: webView, for: .markdown)

        loadTemplate(into: webView, initialContent: content, theme: theme, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVisibleLineChange = onVisibleLineChange
        coordinator.onTOCUpdate = onTOCUpdate
        coordinator.findController = findController
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onAddTodo = onAddTodo
        findController?.register(webView: webView, for: .markdown)

        // Theme changed: swap stylesheet via JS; re-render handled by bridge.
        if theme != coordinator.lastTheme {
            coordinator.lastTheme = theme
            coordinator.evaluateWhenReady(JSBridge.call("setTheme", args: [theme.rawValue]))
        }

        // Source URL changed: update <base href> so relative resources resolve.
        let sourceChanged = sourceURL != coordinator.lastSourceURL
        if sourceChanged {
            coordinator.lastSourceURL = sourceURL
            let baseURL = sourceURL.map { MeditorAssetSchemeHandler.baseURLString(forDirectory: $0.deletingLastPathComponent()) } ?? ""
            coordinator.evaluateWhenReady(JSBridge.call("setBaseURL", args: [baseURL]))
        }

        // Font size changed: update CSS variable.
        if fontSize != coordinator.lastFontSize {
            coordinator.lastFontSize = fontSize
            coordinator.evaluateWhenReady("document.documentElement.style.setProperty('--preview-font-size','\(fontSize)px');")
        }

        // Content changed: incremental update via JS.
        if contentRevision != coordinator.lastContentRevision {
            coordinator.lastContentRevision = contentRevision
            coordinator.scheduleContentUpdate(
                content,
                revision: contentRevision,
                immediately: sourceChanged || content.isEmpty
            )
        }

        // Scroll sync editor → preview using source line.
        if scrollToLine >= 0, scrollRequestID != coordinator.lastAppliedRequestID {
            coordinator.lastAppliedTargetLine = scrollToLine
            coordinator.lastAppliedRequestID = scrollRequestID
            coordinator.isProgrammaticScroll = true
            coordinator.evaluateWhenReady(
                JSBridge.call("scrollToLine", intArg: scrollToLine)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                coordinator.isProgrammaticScroll = false
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop loading any in-flight requests, drop delegates, and detach
        // message handlers so the WKWebView can be deallocated.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: scrollHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: copyHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: tocHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: perfHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: selectionHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: escapeHandlerName)
        if coordinator.exporter?.webView === webView {
            coordinator.exporter?.webView = nil
        }
        coordinator.cancelPendingContentUpdate()
        coordinator.findController?.register(webView: nil, for: .markdown)
        coordinator.webView = nil
    }

    // MARK: - Template loading

    /// Render `template.html` with substituted values and load it into the webview.
    ///
    /// The file management (template read, cache-dir setup, asset mirroring,
    /// preview.html write) is delegated to `PreviewAssetMirror` and runs off
    /// the main thread. Until preparation completes, the webview simply hasn't
    /// loaded anything yet (drawsBackground = false, so no white flash); JS
    /// updates arriving in the meantime are queued by `evaluateWhenReady`
    /// because `isReady` stays false until `didFinish`.
    private func loadTemplate(into webView: WKWebView,
                              initialContent: String,
                              theme: PreviewTheme,
                              coordinator: Coordinator) {
        let sid = PerformanceTracer.begin("LoadPreviewTemplate", log: PerformanceTracer.preview)
        let cacheDir = coordinator.previewDir
        coordinator.isReady = false
        PreviewAssetMirror.prepareHTMLAsync(initialContent: initialContent,
                                            theme: theme,
                                            cacheDir: cacheDir) { [weak webView, weak coordinator] fileURL in
            PerformanceTracer.end("LoadPreviewTemplate", log: PerformanceTracer.preview, id: sid)
            // Dismantled (or webview swapped) while preparing — drop the result.
            guard let webView, let coordinator, coordinator.webView === webView else { return }
            guard let fileURL else {
                // Fallback: blank page with an error message.
                webView.loadHTMLString(
                    "<html><body><pre>MEditor: preview template not found.</pre></body></html>",
                    baseURL: nil
                )
                return
            }
            webView.loadFileURL(fileURL, allowingReadAccessTo: cacheDir)
        }
    }
}

// MARK: - Coordinator

extension MarkdownWebView {
    @MainActor
    final class Coordinator: NSObject, PreviewExportRestorable {
        weak var webView: WKWebView?
        var onVisibleLineChange: ((Int) -> Void)?
        var onTOCUpdate: (([TOCItem]) -> Void)?
        weak var exporter: PreviewExporter?
        var findController: PreviewFindController?
        var onSelectionChange: ((String, CGRect) -> Void)?
        var onAddTodo: ((String) -> Void)?
        /// 最近一次实际推送给页面的 markdown 内容，供导出后恢复重推。
        private var lastContent: String?

        /// JS snippet that installs a `selectionchange` listener and forwards
        /// selected text to the native `selectionHandler` message handler.
        /// Idempotent: guard flag `_meditorSelListenerInstalled` prevents
        /// double-registration when injected into a reused (pooled) WebView.
        static let selectionListenerJS = """
        (function() {
            if (window._meditorSelListenerInstalled) return;
            window._meditorSelListenerInstalled = true;
            var _lastSel = '';
            document.addEventListener('selectionchange', function() {
                var sel = window.getSelection();
                var text = sel ? sel.toString().trim() : '';
                if (text === _lastSel) return;
                _lastSel = text;
                var rect = { top: 0, left: 0, bottom: 0, right: 0 };
                if (sel && sel.rangeCount > 0) {
                    var r = sel.getRangeAt(0).getBoundingClientRect();
                    rect = { top: r.top, left: r.left, bottom: r.bottom, right: r.right };
                }
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionHandler) {
                    window.webkit.messageHandlers.selectionHandler.postMessage({
                        text: text, top: rect.top, left: rect.left, bottom: rect.bottom, right: rect.right
                    });
                }
            });
        })();
        """

        var lastContentRevision: Int = 0
        var lastTheme: PreviewTheme = .github
        var lastSourceURL: URL?
        var lastFontSize: Int = 15
        var lastAppliedTargetLine: Int = -1
        var lastAppliedRequestID: Int = -1
        var lastReportedLine: Int = -1
        var isProgrammaticScroll = false
        var isReady = false
        private var pendingContentScript: String?
        private var pendingContentUpdate: DispatchWorkItem?

        let previewDir: URL = {
            let cachesDir = FileManager.default.firstURL(for: .cachesDirectory)
            return cachesDir.appendingPathComponent("com.meditor.preview", isDirectory: true)
        }()

        private static func contentUpdateDebounce(for content: String) -> TimeInterval {
            let bytes = content.utf8.count
            switch bytes {
            case 0..<16 * 1024:
                return 0.016
            case 16 * 1024..<64 * 1024:
                return 0.028
            case 64 * 1024..<256 * 1024:
                return 0.05
            default:
                return 0.08
            }
        }

        // Pending JS to run once the page finishes loading.
        private var pendingScripts: [String] = []

        init(onVisibleLineChange: ((Int) -> Void)? = nil,
             onTOCUpdate: (([TOCItem]) -> Void)? = nil,
             exporter: PreviewExporter? = nil,
             findController: PreviewFindController? = nil,
             onSelectionChange: ((String, CGRect) -> Void)? = nil,
             onAddTodo: ((String) -> Void)? = nil) {
            self.onVisibleLineChange = onVisibleLineChange
            self.onTOCUpdate = onTOCUpdate
            self.exporter = exporter
            self.findController = findController
            self.onSelectionChange = onSelectionChange
            self.onAddTodo = onAddTodo
        }

        deinit {
            // The user content controller's script handlers retain coordinator;
            // dismantleNSView already removes them. 不再在此调用 cancelPendingContentUpdate()：
            // deinit 是 nonisolated，不能访问 @MainActor 状态（Swift 6）。
        }

        /// Run a JS string immediately if the page is ready, otherwise queue it.
        func evaluateWhenReady(_ js: String) {
            if isReady, let webView {
                webView.evaluateJavaScript(js) { _, error in
                    if let error { Self.logJSError(js: js, error: error) }
                }
            } else {
                pendingScripts.append(js)
            }
        }

        func flushPendingScripts() {
            guard let webView else { return }
            let scripts = pendingScripts
            pendingScripts.removeAll()
            for js in scripts {
                webView.evaluateJavaScript(js) { _, error in
                    if let error { Self.logJSError(js: js, error: error) }
                }
            }
            if let pendingContentScript {
                self.pendingContentScript = nil
                let evalSID = PerformanceTracer.begin("PreviewEvaluateJavaScript", log: PerformanceTracer.preview)
                webView.evaluateJavaScript(pendingContentScript) { _, error in
                    PerformanceTracer.end("PreviewEvaluateJavaScript", log: PerformanceTracer.preview, id: evalSID)
                    if let error { Self.logJSError(js: pendingContentScript, error: error) }
                }
            }
        }

        /// Coalesce bursty editor updates so large markdown documents don't
        /// cross the Swift↔WebKit bridge on every single keystroke.
        func scheduleContentUpdate(_ content: String, revision: Int, immediately: Bool = false) {
            pendingContentUpdate?.cancel()
            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self] in
                guard workItem.isCancelled == false else { return }
                self?.dispatchContentUpdate(content, revision: revision)
            }
            pendingContentUpdate = workItem

            if immediately {
                workItem.perform()
            } else {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.contentUpdateDebounce(for: content),
                    execute: workItem
                )
            }
        }

        func cancelPendingContentUpdate() {
            pendingContentUpdate?.cancel()
            pendingContentUpdate = nil
            pendingContentScript = nil
        }

        /// 导出（PDF/图片）结束后由 PreviewExporter 调用：导出的整页重载把
        /// 页面重置回 preview.html 的 initial content（可能是预热时的空文档），
        /// 而 Swift 侧 lastContentRevision 未变、updateNSView 不会重推——
        /// 这里强制重推当前内容。isReady 置 false 让更新进入 pendingContentScript，
        /// 等恢复导航的 didFinish 里 flush，避免在导航途中 evaluate 打到旧页面。
        func restorePreviewAfterExport() {
            guard let content = lastContent else { return }
            isReady = false
            scheduleContentUpdate(content, revision: lastContentRevision, immediately: true)
        }

        private func dispatchContentUpdate(_ content: String, revision: Int) {
            pendingContentUpdate = nil
            lastContent = content
            // Lazily provision mermaid.min.js only when content contains a mermaid block.
            if content.contains("```mermaid") {
                PreviewAssetMirror.ensureMermaidProvisioned(at: previewDir)
            }
            let sid = PerformanceTracer.begin("PreviewContentUpdate", log: PerformanceTracer.preview)
            let escaped = Self.jsonEncode(string: content) ?? "\"\""
            let js = "window.MEditor && window.MEditor.update(\(escaped), \(revision));"
            lastContentRevision = revision
            if isReady, let webView {
                let evalSID = PerformanceTracer.begin("PreviewEvaluateJavaScript", log: PerformanceTracer.preview)
                webView.evaluateJavaScript(js) { _, error in
                    PerformanceTracer.end("PreviewEvaluateJavaScript", log: PerformanceTracer.preview, id: evalSID)
                    if let error { Self.logJSError(js: js, error: error) }
                }
            } else {
                PerformanceTracer.event("PreviewEvaluateQueuedUntilReady", log: PerformanceTracer.preview)
                pendingContentScript = js
            }
            PerformanceTracer.end("PreviewContentUpdate", log: PerformanceTracer.preview, id: sid)
        }

        private static func jsonEncode(string: String) -> String? {
            guard let data = try? JSONEncoder().encode(string) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func logJSError(js: String, error: Error) {
            #if DEBUG
            let preview = js.count > 80 ? String(js.prefix(80)) + "…" : js
            print("MEditor JS error: \(error.localizedDescription) — \(preview)")
            #endif
        }
    }
}

// MARK: - WKNavigationDelegate

extension MarkdownWebView.Coordinator: WKNavigationDelegate {
    /// 链接点击不替换预览内容：锚点放行，外部链接交给系统浏览器打开。
    ///
    /// ⚠️⚠️ 闭包上的 `@MainActor @Sendable` 一个字都不能少：与 WebKit 的 requirement
    /// 不一致时只会得到 "nearly matches optional requirement" 警告，方法却**不会**
    /// 被导出成 delegate selector，WebKit 于是按默认策略放行——链接在预览内导航。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        PreviewLinkNavigator.decidePolicy(for: navigationAction, webView: webView, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PerformanceTracer.event("PreviewTemplateReady", log: PerformanceTracer.preview)
        isReady = true
        // Apply configured font size on initial load.
        let fs = lastFontSize
        if fs != 15 {
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--preview-font-size','\(fs)px');", completionHandler: nil)
        }
        flushPendingScripts()
        // Inject selection listener so the native side gets notified when the
        // user selects text in the preview (used by PreviewInlineEditBar).
        webView.evaluateJavaScript(MarkdownWebView.Coordinator.selectionListenerJS, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Non-fatal: leave isReady as false so we don't try to evaluateJS.
        #if DEBUG
        print("MEditor preview navigation failed: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - WKScriptMessageHandler

extension MarkdownWebView.Coordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case MarkdownWebView.scrollHandlerName:
            handleScrollMessage(message)
        case MarkdownWebView.copyHandlerName:
            handleCopyMessage(message)
        case MarkdownWebView.tocHandlerName:
            handleTOCMessage(message)
        case MarkdownWebView.perfHandlerName:
            handlePerfMessage(message)
        case MarkdownWebView.selectionHandlerName:
            handleSelectionMessage(message)
        case MarkdownWebView.escapeHandlerName:
            NotificationCenter.default.post(name: .previewWebViewDidPressEscape, object: nil)
        default:
            break
        }
    }

    private func handleScrollMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if isProgrammaticScroll { return }
        if let line = body["line"] as? Int, line >= 0, line != lastReportedLine {
            lastReportedLine = line
            onVisibleLineChange?(line)
        }
    }

    private func handleCopyMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let text = body["text"] as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func handleTOCMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let items = body["items"] as? [[String: Any]] else { return }
        let tocItems = items.compactMap { dict -> TOCItem? in
            guard let level = dict["level"] as? Int,
                  let title = dict["title"] as? String,
                  let line = dict["line"] as? Int else { return nil }
            return TOCItem(level: level, title: title, line: line)
        }
        onTOCUpdate?(tocItems)
    }

    private func handleSelectionMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let text = (body["text"] as? String) ?? ""
        let rect = previewSelectionRect(from: body)
        DispatchQueue.main.async {
            self.onSelectionChange?(text, rect)
        }
    }

    private func handlePerfMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let stage = body["stage"] as? String else { return }
        switch stage {
        case "PreviewJSUpdateReceived":
            PerformanceTracer.event("PreviewJSUpdateReceived", log: PerformanceTracer.preview)
        case "PreviewJSCacheHitPaint":
            PerformanceTracer.event("PreviewJSCacheHitPaint", log: PerformanceTracer.preview)
        case "PreviewJSRenderStart":
            PerformanceTracer.event("PreviewJSRenderStart", log: PerformanceTracer.preview)
        case "PreviewJSRenderDOMCommitted":
            PerformanceTracer.event("PreviewJSRenderDOMCommitted", log: PerformanceTracer.preview)
        case "PreviewJSHighlightScheduled":
            PerformanceTracer.event("PreviewJSHighlightScheduled", log: PerformanceTracer.preview)
        case "PreviewJSMermaidScheduled":
            PerformanceTracer.event("PreviewJSMermaidScheduled", log: PerformanceTracer.preview)
        case "PreviewJSDocumentCachesRefreshed":
            PerformanceTracer.event("PreviewJSDocumentCachesRefreshed", log: PerformanceTracer.preview)
        case "PreviewJSTOCSent":
            PerformanceTracer.event("PreviewJSTOCSent", log: PerformanceTracer.preview)
        default:
            break
        }
    }
}

// MARK: - WKUIDelegate (右键菜单：新增为待办)

extension MarkdownWebView.Coordinator: WKUIDelegate {
    /// target="_blank" / window.open 的链接同样交给系统浏览器打开。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            PreviewLinkNavigator.openExternally(url)
        }
        return nil
    }

    /// macOS 右键菜单拦截：在默认菜单中注入"新增为待办"条目。
    func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
        // 读取当前选中文本；evaluateJavaScript 是异步的，
        // 但此时 JS selection 通常已经被 selectionchange 事件同步过来了。
        // 我们从已缓存的 JS 同步获取更可靠。
        webView.evaluateJavaScript("window.getSelection().toString().trim()") { [weak self, weak menu] result, _ in
            guard let self = self,
                  let menu = menu,
                  let selectedText = result as? String,
                  !selectedText.isEmpty else { return }
            DispatchQueue.main.async {
                menu.addItem(.separator())
                let addItem = NSMenuItem(
                    title: L("todo.addFromSelection"),
                    action: #selector(MarkdownWebView.Coordinator.handleAddTodo(_:)),
                    keyEquivalent: ""
                )
                addItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: L("todo.addFromSelection"))
                addItem.target = self
                addItem.representedObject = selectedText
                menu.addItem(addItem)
            }
        }
    }

    @objc func handleAddTodo(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        DispatchQueue.main.async {
            self.onAddTodo?(text)
        }
    }
}
