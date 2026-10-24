import WebKit
import AppKit

/// 预览页（Markdown / HTML）内的链接点击策略。
///
/// 问题背景：WKWebView 默认允许页内导航，用户在预览里点击链接后，
/// 渲染模板/原文档会被目标页面替换，且没有"返回"入口，预览就此坏掉。
///
/// 策略：
///  - 页内锚点跳转（`#heading`）：放行，在预览内滚动。
///  - `<base>` 改写过的小节锚点（`meditor-asset://…/#heading`）：取消，
///    既不放行也不外开 —— 见 `isRewrittenAnchor`。
///  - 带 fragment 的跨文档链接（`other.md#小节`，同样被 `<base>` 改写）：
///    落到真实文件上就外开（回到本应用=开 tab），否则取消。
///  - 其余链接（http/https/mailto/本地文件等）：交给系统默认应用打开，
///    取消 WebView 内导航，预览内容保持不变。
enum PreviewLinkNavigator {
    /// 一次点击该做什么。抽成纯值是为了可测：`WKNavigationAction` 造不出来
    /// （`linkActivated` 只有真实用户点击才会出现，JS `click()` 是 `.other`），
    /// 策略本身只能靠这个函数锁住。
    enum LinkAction: Equatable {
        /// 放行 WebView 内导航（页内锚点）。
        case allow
        /// 取消，什么都不做。
        case cancel
        /// 取消页内导航，交给系统按 `URL` 打开。
        case open(URL)
    }

    /// 供 `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` 调用。
    static func decidePolicy(
        for navigationAction: WKNavigationAction,
        webView: WKWebView,
        decisionHandler: (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch action(for: url, currentURL: webView.url) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .open(let target):
            openExternally(target)
            decisionHandler(.cancel)
        }
    }

    /// 纯决策：这条链接在「当前文档是 `currentURL`」的预览里该怎么处理。
    static func action(for url: URL, currentURL: URL?) -> LinkAction {
        // 同页锚点：放行，让 WebView 自己滚。
        if isSamePageAnchor(url, current: currentURL) { return .allow }

        // HTML 预览注入了 `<base href="meditor-asset://…">`，markdown 预览也有
        // （`bridge.js` 的 setBaseURL），纯 fragment 链接会被解析成
        // `meditor-asset://…/#小节`。这种 URL 去掉 fragment 就是文档目录，
        // 外开只会在 Finder 里弹一个文件夹，所以取消——真正的滚动由页面内的
        // `HTMLAnchorGuard` 完成。
        //
        // 但**带 fragment 的 asset URL 不一定都是页内锚点**：`[看这里](other.md#小节)`
        // 被 `<base>` 改写成 `meditor-asset://…/other.md#小节`，一律取消等于把跨文档
        // 链接吞成死链（点了什么也不发生）。判据是「去掉 fragment 之后落不落在真实
        // 文件上」：落在文件上就是真链接，外开；落在目录/不存在才是页内锚点的残渣。
        if isRewrittenAnchor(url) {
            guard let fileURL = assetFileURL(from: url), isRegularFile(fileURL) else { return .cancel }
            return .open(fileURL)
        }

        return .open(url)
    }

    /// asset scheme URL → 真实文件路径（fragment / query 不参与）。
    /// 非 asset scheme 返回 nil。
    static func assetFileURL(from url: URL) -> URL? {
        guard url.scheme == MeditorAssetSchemeHandler.scheme else { return nil }
        let path = (url.path.removingPercentEncoding ?? url.path) as NSString
        return URL(fileURLWithPath: path.standardizingPath)
    }

    /// 路径上是不是一个真实文件（目录不算：文档目录没有可打开的东西）。
    static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// 用系统默认应用打开链接（浏览器/Finder 关联应用等）。
    static func openExternally(_ url: URL) {
        // meditor-asset:// 是预览内部用于加载本地资源的自定义 scheme，
        // 系统无法识别，先还原为真实文件路径。
        NSWorkspace.shared.open(assetFileURL(from: url) ?? url)
    }

    /// 仅 fragment 不同（同页锚点）的跳转。
    private static func isSamePageAnchor(_ url: URL, current: URL?) -> Bool {
        guard url.fragment != nil, let current else { return false }
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var base = URLComponents(url: current, resolvingAgainstBaseURL: false)
        target?.fragment = nil
        base?.fragment = nil
        return target?.string == base?.string
    }

    /// `<base>` 把页内锚点改写成了 `meditor-asset://…/#小节` 的那一类 URL。
    ///
    /// 判据：带 fragment + 走 meditor-asset scheme。真实的本地资源链接
    /// （图片、附件）不会带 fragment，因此不会误伤。
    static func isRewrittenAnchor(_ url: URL) -> Bool {
        url.fragment != nil && url.scheme == MeditorAssetSchemeHandler.scheme
    }
}
