import SwiftUI
import WebKit

/// Renders an HTML file in a long-lived `WKWebView`.
///
/// Content comes from memory (`content`, 即 tab.content），不是磁盘文件：
/// 渲染用 `loadHTMLString` + 合成 https base URL（CDN 脚本可用），因此
/// AI 写回/编辑后预览立即刷新，不需要先保存。`reloadToken` 在内容或文件
/// 变化时递增，是重新加载的唯一信号（避免对大文档做字符串 diff 驱动刷新）。
struct WebPreviewView: NSViewRepresentable {
    let fileURL: URL?
    let reloadToken: Int
    /// 内存中的文档内容；为 nil 时回退到读磁盘文件（兼容旧路径）。
    var content: String? = nil
    var exporter: PreviewExporter? = nil
    var rootURL: URL? = nil
    var findController: PreviewFindController? = nil
    var onSelectionChange: ((String, CGRect) -> Void)? = nil
    var onAddTodo: ((String) -> Void)? = nil

    static let selectionHandlerName = "selectionHandler"
    static let escapeHandlerName = "escapeHandler"

    func makeCoordinator() -> Coordinator {
        Coordinator(findController: findController, onSelectionChange: onSelectionChange, onAddTodo: onAddTodo)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 本地相对资源（<img src="images/a.png">）走 meditor-asset:// ——见
        // applyLoad 的说明。scheme handler 必须在这里注册：WKWebView 只在
        // 「创建 WKWebView 实例时」认这个配置，事后给 configuration 补注册无效。
        config.setURLSchemeHandler(MeditorAssetSchemeHandler(), forURLScheme: MeditorAssetSchemeHandler.scheme)
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "copyHandler")
        userContent.add(context.coordinator, name: Self.selectionHandlerName)
        userContent.add(context.coordinator, name: Self.escapeHandlerName)
        config.userContentController = userContent
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(L("preview.empty"))
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.rootURL = rootURL
        findController?.register(webView: webView, for: .html)
        context.coordinator.applyLoad(fileURL: fileURL, reloadToken: reloadToken, content: content)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Register with exporter when HTML preview is active.
        if fileURL != nil {
            exporter?.webView = webView
        }
        context.coordinator.rootURL = rootURL
        context.coordinator.findController = findController
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onAddTodo = onAddTodo
        findController?.register(webView: webView, for: .html)
        context.coordinator.applyLoad(fileURL: fileURL, reloadToken: reloadToken, content: content)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebPreviewView.selectionHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebPreviewView.escapeHandlerName)
        coordinator.findController?.register(webView: nil, for: .html)
        coordinator.webView = nil
    }
}

extension WebPreviewView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var rootURL: URL?
        var findController: PreviewFindController?
        var onSelectionChange: ((String, CGRect) -> Void)?
        var onAddTodo: ((String) -> Void)?
        private var lastFileURL: URL?
        private var lastReloadToken: Int = -1

        init(findController: PreviewFindController? = nil, onSelectionChange: ((String, CGRect) -> Void)? = nil, onAddTodo: ((String) -> Void)? = nil) {
            self.findController = findController
            self.onSelectionChange = onSelectionChange
            self.onAddTodo = onAddTodo
        }

        /// Load the file only when something actually changed.
        /// SwiftUI calls `updateNSView` for many unrelated reasons, so dedup here.
        func applyLoad(fileURL: URL?, reloadToken: Int, content: String?) {
            let urlChanged = fileURL?.absoluteURL != lastFileURL?.absoluteURL
            let tokenChanged = reloadToken != lastReloadToken

            guard urlChanged || tokenChanged else { return }
            lastFileURL = fileURL
            lastReloadToken = reloadToken

            guard let webView = webView else { return }
            guard let fileURL = fileURL else {
                // No file: show a blank page (a single empty doc, cached forever).
                webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
                return
            }

            // 渲染优先用内存内容（AI 写回/编辑未落盘也能立即预览）。
            // baseURL 仍用 https 合成源：CDN 脚本（echarts 等）要能加载——
            // WKWebView 会拦 file:// 页面的外部网络请求，https:// 页面不拦。
            //
            // 相对**本地**资源靠注入的 `<base href="meditor-asset://…">` 解析
            // （HTMLAssetBaseInjector）：https base 下 `./pic.png` 会被解析成
            // `https://localhost/pic.png` 而加载失败。`<base>` 不影响绝对 URL，
            // 所以 CDN 与本地图片两者兼得。
            let baseURL = URL(string: "https://localhost/")
            let baseDirectory = fileURL.deletingLastPathComponent()
            if let content {
                let html = HTMLAssetBaseInjector.injectingBase(hinto: content, directory: baseDirectory)
                webView.loadHTMLString(html, baseURL: baseURL)
                return
            }
            if let htmlString = try? String(contentsOf: fileURL, encoding: .utf8) {
                let html = HTMLAssetBaseInjector.injectingBase(hinto: htmlString, directory: baseDirectory)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                // Fallback: file URL load (works for local-only resources)
                let readAccess = rootURL ?? baseDirectory
                webView.loadFileURL(fileURL, allowingReadAccessTo: readAccess)
            }
        }
    }
}

extension WebPreviewView.Coordinator {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "copyHandler":
            guard let body = message.body as? [String: Any],
                  let text = body["text"] as? String else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case "selectionHandler":
            guard let body = message.body as? [String: Any] else { return }
            let text = (body["text"] as? String) ?? ""
            let rect = previewSelectionRect(from: body)
            DispatchQueue.main.async {
                self.onSelectionChange?(text, rect)
            }
        case "escapeHandler":
            NotificationCenter.default.post(name: .previewWebViewDidPressEscape, object: nil)
        default:
            break
        }
    }
}

extension WebPreviewView.Coordinator {
    /// 链接点击不替换预览内容：锚点放行，外部链接交给系统浏览器打开。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        PreviewLinkNavigator.decidePolicy(for: navigationAction, webView: webView, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject copy buttons into <pre><code> blocks, mirroring render.js behaviour.
        let js = """
        (function() {
            if (document.querySelector('.meditor-copy-btn')) return;
            var style = document.createElement('style');
            style.textContent = '.meditor-codeblock{position:relative}.meditor-copy-btn{position:absolute;top:8px;right:8px;padding:3px 9px;font-size:11px;font-family:-apple-system,sans-serif;font-weight:500;background:rgba(255,255,255,.15);color:inherit;border:1px solid rgba(128,128,128,.3);border-radius:4px;cursor:pointer;opacity:0;transition:opacity .15s}.meditor-codeblock:hover .meditor-copy-btn{opacity:.9}.meditor-copy-btn:hover{opacity:1!important}.meditor-copy-btn--copied{opacity:1!important;color:#0969da}';
            document.head.appendChild(style);
            document.querySelectorAll('pre code, pre').forEach(function(el) {
                var pre = el.tagName === 'PRE' ? el : el.parentElement;
                if (!pre || pre.tagName !== 'PRE') return;
                if (pre.querySelector('.meditor-copy-btn')) return;
                pre.style.position = 'relative';
                pre.classList.add('meditor-codeblock');
                var btn = document.createElement('button');
                btn.className = 'meditor-copy-btn';
                btn.textContent = 'Copy';
                btn.addEventListener('click', function(e) {
                    e.stopPropagation();
                    var text = (pre.querySelector('code') || pre).innerText || '';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyHandler) {
                        window.webkit.messageHandlers.copyHandler.postMessage({text: text});
                    } else if (navigator.clipboard) {
                        navigator.clipboard.writeText(text);
                    }
                    btn.textContent = 'Copied';
                    btn.classList.add('meditor-copy-btn--copied');
                    setTimeout(function() { btn.textContent = 'Copy'; btn.classList.remove('meditor-copy-btn--copied'); }, 1200);
                });
                pre.appendChild(btn);
            });
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        let selectionJS = """
        (function() {
            if (document.querySelector('[data-meditor-sel]')) return;
            var marker = document.createElement('meta');
            marker.setAttribute('data-meditor-sel', '1');
            document.head.appendChild(marker);
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
        webView.evaluateJavaScript(selectionJS, completionHandler: nil)

        // ESC 退出专注模式：WKWebView 把键盘事件转发给独立的 WebContent 进程处理，
        // AppKit 侧的 keyDown 覆写/本地事件监视器都拦不到——只能在页面自身注册
        // JS 监听器，再通过 message handler 桥接回 Swift 层。
        let escapeJS = """
        (function() {
            if (document.querySelector('[data-meditor-esc]')) return;
            var marker = document.createElement('meta');
            marker.setAttribute('data-meditor-esc', '1');
            document.head.appendChild(marker);
            document.addEventListener('keydown', function(e) {
                if (e.key === 'Escape' || e.keyCode === 27) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.escapeHandler) {
                        window.webkit.messageHandlers.escapeHandler.postMessage({});
                    }
                }
            });
        })();
        """
        webView.evaluateJavaScript(escapeJS, completionHandler: nil)
    }
}

// MARK: - WKUIDelegate (右键菜单：新增为待办)

extension WebPreviewView.Coordinator: WKUIDelegate {
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

    func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
        webView.evaluateJavaScript("window.getSelection().toString().trim()") { [weak self, weak menu] result, _ in
            guard let self = self,
                  let menu = menu,
                  let selectedText = result as? String,
                  !selectedText.isEmpty else { return }
            DispatchQueue.main.async {
                menu.addItem(.separator())
                let addItem = NSMenuItem(
                    title: L("todo.addFromSelection"),
                    action: #selector(WebPreviewView.Coordinator.handleAddTodo(_:)),
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
