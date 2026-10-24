import XCTest
import WebKit
@testable import MEditor

/// markdown 预览的页内锚点（`[跳到某节](#某节)`）。
///
/// 回归背景：markdown 预览和 HTML 预览有同一个 `<base href="meditor-asset://…">` 陷阱，
/// 但守卫只装在了 HTML 预览（`WebPreviewView`）——markdown 里点锚点既不滚动也不报错
/// （实测 `decidePolicyFor` 都不回调）。修法两半，缺一不可：
///   1. 标题得有 id：marked v12 起不再产出 header id，`render.js` 现在按 GitHub 规则补；
///   2. 点击得有人接管：`PreviewAssetMirror` 把 `HTMLAnchorGuard.script(...)` 写成
///      `scripts/anchor-guard.js`，模板用 `<script src>` 引（CSP 禁内联）。
@MainActor
final class MarkdownPreviewAnchorTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    // MARK: - 标题 id

    func testHeadingIDsAreGitHubStyle() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.render(
            "# 标题 A\n\n## 目标小节\n\n### Hello, World!\n\n## 重复\n\n## 重复\n",
            in: webView
        )
        let ids = try await PreviewTestPage.eval(
            "Array.prototype.map.call(document.querySelectorAll('#content h1,#content h2,#content h3'),"
            + "function(h){return h.id}).join('|')",
            webView
        )
        XCTAssertEqual(ids, "标题-a|目标小节|hello-world|重复|重复-1",
                       "标题 id 应当是小写 + 去标点 + 空白转 `-`，重名按出现顺序加 -1")
    }

    func testHeadingIDsFollowTextChanges() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.render("# 甲\n\n## 目标小节\n", in: webView)
        let first = try await ids(webView)
        XCTAssertEqual(first, "甲|目标小节")

        _ = try await PreviewTestPage.render("# 甲\n\n## 改名之后\n", in: webView)
        let second = try await ids(webView)
        XCTAssertEqual(second, "甲|改名之后",
                       "标题文字改了，id 必须跟着改（否则旧锚点还能命中残留节点）")
    }

    /// 作者显式写的 id 优先：老文档里手工锚点（`<h2 id="install">`）不能被自动 slug 覆盖。
    func testExplicitHeadingIDIsPreserved() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.render(
            "<h2 id=\"install\">安装</h2>\n\n## 别的\n",
            in: webView
        )
        let got = try await ids(webView)
        XCTAssertEqual(got, "install|别的")
    }

    private func ids(_ webView: WKWebView) async throws -> String? {
        try await PreviewTestPage.eval(
            "Array.prototype.map.call(document.querySelectorAll('#content h1,#content h2,#content h3'),"
            + "function(h){return h.id}).join('|')",
            webView
        )
    }

    // MARK: - 点击接管

    /// 纯 fragment 链接：守卫必须 preventDefault 并改 `location.hash`，页面自己滚。
    func testPureFragmentClickIsTakenOverAndScrolls() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (webView, _) = try await PreviewTestPage.makeWebView()
        try await installGuardAndBase(webView, directory: dir)

        _ = try await PreviewTestPage.render(Self.longDocument(linkHref: "#目标小节"), in: webView)

        let beforeY = try await number("window.scrollY", webView)
        XCTAssertEqual(beforeY, 0, "初始应停在顶部")

        _ = try await PreviewTestPage.eval(
            "document.querySelector('#content a').click(); 1", webView)
        try await Task.sleep(nanoseconds: 900_000_000)

        let afterY = try await number("window.scrollY", webView)
        XCTAssertGreaterThan(afterY, 400, "点页内锚点后预览没有滚动（scrollY=\(afterY)）")
        let hash = try await PreviewTestPage.eval(
            "decodeURIComponent(location.hash)", webView)
        XCTAssertEqual(hash, "#目标小节", "fragment 应写回地址栏，:target 样式才有依据")
    }

    /// 跨文档链接 `other.md#小节`：即使 fragment 和当前文档的标题同名，守卫也不能接管
    /// ——它该交给 `PreviewLinkNavigator` 去打开那份文档。
    ///
    /// 判据用 `event.defaultPrevented`（`dispatchEvent` 返回 `!defaultPrevented`）：
    /// 这样不必等导航结果，也不会被「导航把页面换掉」污染断言。
    func testCrossFileFragmentClickIsNotTakenOver() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (webView, _) = try await PreviewTestPage.makeWebView()
        try await installGuardAndBase(webView, directory: dir)

        _ = try await PreviewTestPage.render(Self.longDocument(linkHref: "other.md#目标小节"), in: webView)

        let outcome = try await PreviewTestPage.eval(
            "(function(){var a=document.querySelector('#content a');"
            + "var ev=new MouseEvent('click',{bubbles:true,cancelable:true});"
            + "return a.dispatchEvent(ev) ? 'not-prevented' : 'prevented';})()",
            webView
        )
        XCTAssertEqual(outcome, "not-prevented",
                       "跨文档带 fragment 的链接不能被页内守卫吞掉（该由 navigator 打开文件）")
    }

    // MARK: - 装配

    /// 守卫脚本来自资源生成链路：`prepareHTML` 必须把它写进 `scripts/anchor-guard.js`，
    /// 且真实模板必须用 `<script src>` 引它（内联会被 CSP 拦掉）。
    func testPrepareHTMLProvidesAnchorGuardScript() throws {
        let resources = PreviewTestPage.repoRoot
            .appendingPathComponent("Sources/MEditor/Resources/Preview")
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fileURL = try XCTUnwrap(
            PreviewAssetMirror.prepareHTML(
                initialContent: "",
                theme: .github,
                cacheDir: cacheDir,
                resourcesRoot: resources,
                templateURL: resources.appendingPathComponent("template.html")
            ),
            "prepareHTML 应当写出 preview.html"
        )

        let guardURL = cacheDir.appendingPathComponent("scripts/anchor-guard.js")
        let guardJS = try String(contentsOf: guardURL, encoding: .utf8)
        XCTAssertTrue(guardJS.contains("__meditorAnchorGuard"), "守卫脚本没写进缓存目录")
        XCTAssertTrue(guardJS.contains("interceptsFileNameLinks = false"),
                      "markdown 预览要用 strict 口径：只接管纯 fragment")

        let html = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("scripts/anchor-guard.js"),
                      "真实模板必须用 <script src> 引守卫（CSP 是 script-src 'self' file:，内联会被拦）")
    }

    // MARK: - 夹具

    /// 60 段正文把页面撑长，目标小节落在首屏之外。
    private static func longDocument(linkHref: String) -> String {
        var filler = ""
        for i in 1...60 { filler += "正文第 \(i) 段，用来把页面撑长。\n\n" }
        return "[跳转](\(linkHref))\n\n\(filler)## 目标小节\n\n这里是目标位置。\n"
    }

    /// 装守卫（strict）+ 把 `<base>` 指向文档目录——复现真实 markdown 预览的两个前提。
    private func installGuardAndBase(_ webView: WKWebView, directory: URL) async throws {
        _ = try await PreviewTestPage.eval(
            HTMLAnchorGuard.script(interceptsFileNameLinks: false), webView)
        let base = MeditorAssetSchemeHandler.baseURLString(forDirectory: directory)
        _ = try await PreviewTestPage.eval(
            "(function(){var b=document.createElement('base');b.href=\(try PreviewTestPage.jsStringLiteral(base));"
            + "document.head.insertBefore(b,document.head.firstChild);return 1;})()",
            webView
        )
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func number(_ js: String, _ webView: WKWebView) async throws -> Double {
        Double(try await PreviewTestPage.eval("String(Math.round(\(js)))", webView) ?? "0") ?? 0
    }
}
