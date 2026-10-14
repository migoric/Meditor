import Foundation

/// 把 HTML 里的本地资源引用改写成 `meditor-asset://` URL，让 WKWebView 能读到
/// 磁盘上任意位置的文件。
///
/// ## 为什么需要它
///
/// HTML 预览走 `loadHTMLString(_:baseURL:)`，baseURL 必须是一个「正常」URL。
/// 现有实现用 `https://localhost/`——因为 WKWebView 会拦截 `file://` 页面的外部
/// 网络请求，而 AI 生成的报告 HTML 常内嵌 CDN 脚本（echarts 等），用 https 冒充
/// 才能让它们加载（见 `WebPreviewView.Coordinator.applyLoad`）。
///
/// 代价是**相对本地资源全部解析失败**：`<img src="images/a.png">` 会被解析成
/// `https://localhost/images/a.png` → 加载不出来。注释里原先写的「相对本地资源
/// 这种方式解析不了」就是这个 bug，不是取舍。
///
/// ## 解法：注入 `<base href>` 而不是改写每个 src
///
/// 在 `<head>` 最前面插一个 `<base href="meditor-asset://local/<文档目录>/">`：
/// - 相对路径（`./a.png`、`../assets/b.png`）→ 按 meditor-asset 解析 → handler 读盘
/// - 绝对 URL（`https://cdn.../echarts.js`）→ base 不影响绝对 URL → 照常加载
///
/// 这正是 markdown 预览已在用的机制（`bridge.js` 的 `setBaseURL`），复用同一套
/// scheme handler 与同一套敏感目录拦截，行为一致。
///
/// ## 覆盖范围（实测结论，勿凭直觉改）
///
/// 注入 `meditor-asset://local/<dir>/` 这个 base 后，三类引用的解析结果：
///
/// | HTML 里的写法 | 解析为 | 可用 |
/// |---|---|---|
/// | `images/a.png`（相对） | `meditor-asset://local/<dir>/images/a.png` | ✅ |
/// | `../assets/b.png`（相对跳出） | `meditor-asset://local/<上 级>/assets/b.png` | ✅ |
/// | `/Users/me/a.png`（无 host 绝对路径） | `meditor-asset://local/Users/me/a.png` | ✅ |
/// | `https://cdn.x/e.js`（带 scheme） | 原样 | ✅（CDN 照常） |
/// | `data:image/png;base64,…` | 原样 | ✅ |
/// | `file:///Users/me/c.png` | 原样 `file://` | ❌ 见下 |
///
/// 关键点是**绝对路径也一起被修好了**：以 `/` 开头是 RFC 3986 的
/// absolute-path reference，只继承 base 的 scheme + authority，路径部分原样保留
/// —— 我们的 base 恰好就是 `meditor-asset://local/`，于是它自动被同化成合法请求。
/// 改之前的 `https://localhost/` base 才是把它毁掉的原因（→ `https://localhost/Users/…`）。
///
/// ⚠️ 唯一仍不通的是 `file:///…` 形态：它是带 scheme 的绝对 URL，`<base>` 按规范
/// 管不到它，会原样交给 WebKit，而 `loadHTMLString` 的页面不允许 file:// 子资源。
/// markdown 侧由 `render.js` 的 `rewriteAbsoluteAssetPaths` 显式改写这种形态；
/// HTML 侧不做（要解析整个 HTML 文本、误伤风险高，且 `file://` 本身不是合法
/// 网页引用写法）。
enum HTMLAssetBaseInjector {

    /// 把 `<base href="…">` 注入 HTML 的 `<head>` 首位（已存在则替换）。
    ///
    /// - Parameters:
    ///   - html: 原始 HTML 文本。
    ///   - directory: 相对路径的解析基准，通常是文档所在目录。
    /// - Returns: 注入/替换后的 HTML；`directory` 为 nil 时原样返回。
    static func injectingBase(hinto html: String, directory: URL?) -> String {
        guard let directory else { return html }
        let baseTag = "<base href=\"\(MeditorAssetSchemeHandler.baseURLString(forDirectory: directory))\">"

        // 已有 <base>：替换掉（HTML 规范只认第一个，但留下重复的会让
        // 后续解析行为依赖实现细节，不如收敛成一个）。
        if let existing = firstMatchRange(of: #"<base\b[^>]*>"#, in: html) {
            var result = html
            result.replaceSubrange(existing, with: baseTag)
            return result
        }

        // 有 <head …>：插到它后面第一位——base 必须早于所有相对引用出现。
        if let headOpen = firstMatchRange(of: #"<head\b[^>]*>"#, in: html) {
            var result = html
            result.insert(contentsOf: baseTag, at: headOpen.upperBound)
            return result
        }

        // 有 <html …> 但无 <head>：浏览器会隐式生成 head，插在 <html> 之后即可。
        if let htmlOpen = firstMatchRange(of: #"<html\b[^>]*>"#, in: html) {
            var result = html
            result.insert(contentsOf: "<head>\(baseTag)</head>", at: htmlOpen.upperBound)
            return result
        }

        // 片段（无 html/head 标签）：包一层。loadHTMLString 对片段也会隐式
        // 生成 head，base 因此生效。
        return "<head>\(baseTag)</head>\(html)"
    }

    /// 找第一个匹配范围；找不到返回 nil。用 NSRegularExpression 而非 Swift
    /// Regex——需要的是「任意位置第一个命中」，不需要提取结构化信息。
    private static func firstMatchRange(of pattern: String, in string: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: full),
              let range = Range(match.range, in: string) else { return nil }
        return range
    }
}