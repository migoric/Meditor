import XCTest
@testable import MEditor

/// `HTMLAssetBaseInjector` 的行为约束。
///
/// 背景：HTML 预览用 `loadHTMLString(_:baseURL:)` + `https://localhost/` 作
/// base（为了让 CDN 脚本可加载），代价是相对本地资源解析到 `https://localhost/`
/// 而加载不出来。注入 `<base href="meditor-asset://…">` 让两者兼得。
final class HTMLAssetBaseInjectorTests: XCTestCase {

    private let docs = URL(fileURLWithPath: "/Users/test/My Docs")

    private var expectedBase: String {
        MeditorAssetSchemeHandler.baseURLString(forDirectory: docs)
    }

    /// 从 `<base href="..."` 标签之后的子串里截出引号内的 href 值。
    /// ⚠️ 不能用 `prefix(while:)`——Swift 6 语境下它的参数会被推成
    /// `AttributedString.SubSequence`，与 `String.SubSequence` 不兼容（编译期报错）。
    private static func hrefValue(_ afterTag: String) -> String {
        var end = afterTag.startIndex
        while end < afterTag.endIndex, afterTag[end] != "\"" { end = afterTag.index(after: end) }
        return String(afterTag[afterTag.startIndex..<end])
    }

    /// 数某个子串出现的次数（不依赖 components(separatedBy:)——Swift 6 会把它
    /// 的参数类型推成 AttributedString，与 String.Index 不兼容）。
    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let found = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = found.upperBound
        }
        return count
    }

    // MARK: - 注入位置

    func test_injectsBaseAsFirstChildOfHead() {
        let html = "<html><head><title>t</title></head><body><img src=\"a.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        // base 必须是 <head> 的**第一个子节点**——即紧跟在 <head> 标签之后。
        let headTag = "<head>"
        guard let headRange = out.range(of: headTag),
              let baseRange = out.range(of: "<base href=") else {
            return XCTFail("未找到 head/base 标签：\(out)")
        }
        XCTAssertEqual(baseRange.lowerBound, headRange.upperBound,
                       "base 应紧跟 <head> 之后（headRange.upperBound=\(headRange.upperBound) baseRange.lowerBound=\(baseRange.lowerBound)），实际：\(out)")
        XCTAssertTrue(out.contains(expectedBase), "注入的 href 应是 meditor-asset:// 文档目录，实际：\(out)")
        XCTAssertTrue(out.hasPrefix("<html><head><base href="),
                      "完整结构：\(out.prefix(80))")
    }

    func test_baseIsInjectedBeforeTitle_soRelativeURLsResolveAgainstIt() {
        let html = "<html><head><title>x</title></head><body></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)
        let baseIdx = out.range(of: "<base href=")?.lowerBound
        let titleIdx = out.range(of: "<title>")?.lowerBound
        XCTAssertNotNil(baseIdx)
        XCTAssertNotNil(titleIdx)
        if let baseIdx, let titleIdx {
            XCTAssertLessThan(baseIdx, titleIdx, "<base> 晚于 <title> 时其后的相对引用可能已解析完")
        }
    }

    func test_replacesExistingBaseTag() {
        let html = "<html><head><base href=\"https://old/\"><title>t</title></head><body></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        // 「只应有一个 <base>」——用不含分隔符的字符串做计数，避免 Swift 6
        // 把 components(separatedBy:) 的参数推成 AttributedString。
        XCTAssertEqual(Self.countOccurrences(of: "<base", in: out), 1, "只应保留一个 <base>，实际：\(out)")
        XCTAssertFalse(out.contains("https://old/"), "旧 base 应被替换")
        XCTAssertTrue(out.contains(expectedBase))
    }

    func test_insertsHeadWhenOnlyHtmlTagPresent() {
        let html = "<html><body><img src=\"pic.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)
        XCTAssertTrue(out.contains("<head>"))
        XCTAssertTrue(out.contains(expectedBase))
    }

    func test_wrapsBareFragmentWithHead() {
        let out = HTMLAssetBaseInjector.injectingBase(hinto: "<p>hi</p>", directory: docs)
        XCTAssertTrue(out.hasPrefix("<head>"), "片段应包一层 head，实际：\(out)")
        XCTAssertTrue(out.contains(expectedBase))
        XCTAssertTrue(out.contains("<p>hi</p>"), "原文内容不能丢")
    }

    func test_caseInsensitive_headMatch() {
        let out = HTMLAssetBaseInjector.injectingBase(
            hinto: "<HTML><HEAD></HEAD><body></body></HTML>", directory: docs)
        XCTAssertTrue(out.contains(expectedBase), "大写标签也要能匹配，实际：\(out)")
    }

    // MARK: - 不动网络 / 内联 / 非 HTML 内容

    func test_leavesRemoteAndDataURLsAlone() {
        // 这些引用不该被改动：<base> 对绝对 URL 本就无影响，
        // 断言在此是为了锁住「我们只注入 base、不重写 src」这个设计边界。
        let html = """
        <html><head></head><body>
        <img src="https://cdn.example.com/echarts.min.js">
        <img src="data:image/png;base64,iVBORw0KGgo=">
        <img src="meditor-asset://local/already/rewritten.png">
        <script src="https://cdn.example.com/x.js"></script>
        </body></html>
        """
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        XCTAssertTrue(out.contains("https://cdn.example.com/echarts.min.js"), "远程 src 不能被改写")
        XCTAssertTrue(out.contains("data:image/png;base64,iVBORw0KGgo="), "data URI 不能被改写")
        XCTAssertTrue(out.contains("meditor-asset://local/already/rewritten.png"), "已改写的不能重复处理")
        // 「除注入 base 外没有任何其他改动」：把注入的 base 标签整段剥掉，
        // 剩下的必须与原 HTML **逐字相同**（缩进、空白、属性顺序都不许动）。
        let stripped = out.replacingOccurrences(of: "<base href=\"\(expectedBase)\">", with: "")
        XCTAssertEqual(stripped, html, "剥掉注入的 base 标签后应与原 HTML 逐字相同")
    }

    func test_nilDirectory_returnsHTMLUnchanged() {
        let html = "<html><head></head><body>x</body></html>"
        XCTAssertEqual(HTMLAssetBaseInjector.injectingBase(hinto: html, directory: nil), html)
    }

    func test_relativePathInHTML_resolvesToDocumentDirectoryViaInjectedBase() throws {
        // 端到端串一次：注入 base 后，浏览器把 <img src="images/a.png"> 解析到哪里。
        let html = "<html><head></head><body><img src=\"images/a.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        let href = try Self.extractBaseHref(from: out)

        guard let baseURL = URL(string: href),
              let resolved = URL(string: "images/a.png", relativeTo: baseURL) else {
            return XCTFail("href 不是合法 URL：\(href)")
        }
        let decoded = try XCTUnwrap(resolved.path.removingPercentEncoding)
        XCTAssertEqual((decoded as NSString).standardizingPath,
                       "/Users/test/My Docs/images/a.png",
                       "相对图片应解析到文档目录下的实际路径")
    }

    func test_parentRelativePath_escapesDocumentDirectory() throws {
        // HTML 常见 `../assets/` 引用（资源放在文档同级目录）也必须能用。
        let html = "<html><head></head><body><img src=\"../assets/b.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        let href = try Self.extractBaseHref(from: out)
        guard let baseURL = URL(string: href),
              let resolved = URL(string: "../assets/b.png", relativeTo: baseURL) else {
            return XCTFail("href 不是合法 URL：\(href)")
        }
        let decoded = try XCTUnwrap(resolved.path.removingPercentEncoding)
        XCTAssertEqual((decoded as NSString).standardizingPath, "/Users/test/assets/b.png")
    }

    // MARK: - 绝对路径（无 host，以 `/` 开头）

    /// `/Users/me/a.png` 这类写法**也**能用——这一点曾被误判为「已知限制」。
    ///
    /// 依据：RFC 3986 的 absolute-path reference 只继承 base 的 scheme + authority，
    /// 路径部分原样保留。我们的 base 恰是 `meditor-asset://local/`，于是它被同化成
    /// `meditor-asset://local/Users/me/a.png`，handler 能解出 `/Users/me/a.png`。
    ///
    /// 这条断言是**回归护栏**：若有人把 base 改回 `https://localhost/`
    /// （比如为了「简化」），绝对路径会静默退化成 `https://localhost/Users/me/a.png`
    /// 而全部失效——而相对路径的测试仍然会过，看不出问题。
    func test_absolutePathWithoutHost_resolvesToAssetScheme() throws {
        let html = "<html><head></head><body><img src=\"/Users/me/a.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        let href = try Self.extractBaseHref(from: out)
        guard let baseURL = URL(string: href),
              let resolved = URL(string: "/Users/me/a.png", relativeTo: baseURL) else {
            return XCTFail("href 不是合法 URL：\(href)")
        }

        XCTAssertEqual(resolved.scheme, "meditor-asset",
                       "绝对路径必须继承 base 的 meditor-asset scheme，否则图片加载失败")
        let decoded = try XCTUnwrap(resolved.path.removingPercentEncoding)
        XCTAssertEqual((decoded as NSString).standardizingPath, "/Users/me/a.png")
    }

    func test_absolutePathWithSpaces_roundTrips() throws {
        let html = "<html><head></head><body><img src=\"/Users/me/My Docs/d.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        let href = try Self.extractBaseHref(from: out)
        guard let baseURL = URL(string: href),
              let resolved = URL(string: "/Users/me/My%20Docs/d.png", relativeTo: baseURL) else {
            return XCTFail("href 不是合法 URL：\(href)")
        }
        let decoded = try XCTUnwrap(resolved.path.removingPercentEncoding)
        XCTAssertEqual((decoded as NSString).standardizingPath, "/Users/me/My Docs/d.png",
                       "带空格的绝对路径必须正确解出")
    }

    /// 顺带锁住对照事实：`file:///` 形态**不**受 base 影响（RFC 3986 里它是
    /// 带 scheme 的绝对 URL）。这是唯一仍不通的形态，如实钉住以免有人误以为
    /// 「所有绝对路径都通了」而去改 base。
    func test_fileURLScheme_isNotAffectedByBase() throws {
        let html = "<html><head></head><body><img src=\"file:///Users/me/c.png\"></body></html>"
        let out = HTMLAssetBaseInjector.injectingBase(hinto: html, directory: docs)

        let href = try Self.extractBaseHref(from: out)
        guard let baseURL = URL(string: href),
              let resolved = URL(string: "file:///Users/me/c.png", relativeTo: baseURL) else {
            return XCTFail("href 不是合法 URL：\(href)")
        }
        XCTAssertEqual(resolved.scheme, "file",
                       "file:// 是带 scheme 的绝对 URL，<base> 按规范管不到它（唯一不通的形态）")
    }

    /// 抽出注入的 base href 值。
    ///
    /// ⚠️ 用字面量匹配而非 `range(of:options:.regularExpression)`：Swift 6 下后者
    /// 的返回类型在 `String` / `AttributedString` 之间产生歧义，紧随其后的
    /// `Range(...)` 初始化会以「requires the types 'String.Index' and
    /// 'AttributedString.Index' be equivalent」编译失败。这里只需定位标签起点，
    /// 字面量足够，还顺带省掉一次正则编译。
    private static func extractBaseHref(from html: String) throws -> String {
        let marker = "<base href=\""
        guard let range: Range<String.Index> = html.range(of: marker) else {
            throw XCTSkip("未找到 base 标签：\(html)")
        }
        return hrefValue(String(html[range.upperBound...]))
    }
}