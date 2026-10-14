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
/// ⚠️ `<base>` 只影响**相对**引用。HTML 里写死的绝对路径 `/Users/me/a.png`
/// （无 host 的路径形式）在 https base 下仍会解析到 `https://localhost/Users/...`。
/// 这类写法本身不是有效的 URL 引用，改写它需要解析整个 HTML 文本、误伤风险高，
/// 因此不做——markdown 侧同样有该限制（`render.js` 的 `rewriteAbsoluteAssetPaths`
/// 只处理 `file://` 与有 host 的绝对路径）。
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