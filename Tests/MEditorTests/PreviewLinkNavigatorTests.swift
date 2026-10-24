import XCTest
@testable import MEditor

/// `PreviewLinkNavigator` 里「带 fragment 的 asset URL 到底算页内锚点还是真链接」的判据。
///
/// 回归背景：#101 之后预览里 `[看这里](other.md#小节)` 被 `<base>` 改写成
/// `meditor-asset://…/other.md#小节`，旧代码把所有「带 fragment 的 asset URL」
/// 一律 `.cancel` ⇒ 跨文档链接变成死链（点了什么也不发生）。
///
/// ⚠️ 为什么只测纯函数、不做真实点击：`decidePolicy` 的入口条件之一是
/// `navigationAction.navigationType == .linkActivated`，而 JS 里 `element.click()`
/// 产生的是 `.other`（实测：会绕过整段策略直接把 webview 导航走），造不出这个条件。
final class PreviewLinkNavigatorTests: XCTestCase {

    func testAssetFileURLStripsFragmentAndQuery() throws {
        let url = try XCTUnwrap(URL(string: "meditor-asset://local/Users/me/docs/other.md#%E5%B0%8F%E8%8A%82?a=1"))
        let fileURL = try XCTUnwrap(PreviewLinkNavigator.assetFileURL(from: url))
        XCTAssertEqual(fileURL.path, "/Users/me/docs/other.md")
        XCTAssertNil(fileURL.fragment)
        XCTAssertNil(fileURL.query)
    }

    func testAssetFileURLDecodesPercentEscapes() throws {
        let url = try XCTUnwrap(URL(string: "meditor-asset://local/Users/me/My%20Docs/%E8%AF%B4%E6%98%8E.md"))
        let fileURL = try XCTUnwrap(PreviewLinkNavigator.assetFileURL(from: url))
        XCTAssertEqual(fileURL.path, "/Users/me/My Docs/说明.md",
                       "百分号转义必须还原，否则库里带空格/中文的路径全打不开")
    }

    func testAssetFileURLIgnoresOtherSchemes() throws {
        XCTAssertNil(PreviewLinkNavigator.assetFileURL(from: try XCTUnwrap(URL(string: "https://example.com/a.md"))))
        XCTAssertNil(PreviewLinkNavigator.assetFileURL(from: try XCTUnwrap(URL(string: "file:///tmp/a.md"))))
    }

    func testIsRegularFileDistinguishesFileFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("other.md")
        try "# 别的文档\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(PreviewLinkNavigator.isRegularFile(file))
        XCTAssertFalse(PreviewLinkNavigator.isRegularFile(dir), "目录不是可打开的文件")
        XCTAssertFalse(PreviewLinkNavigator.isRegularFile(dir.appendingPathComponent("nope.md")))
    }

    // MARK: - 决策

    func testCrossFileFragmentLinkOpensTheTargetFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("other.md")
        try "# 别的文档\n\n## 小节\n".write(to: other, atomically: true, encoding: .utf8)

        let base = MeditorAssetSchemeHandler.baseURLString(forDirectory: dir)
        let url = try XCTUnwrap(URL(string: base + "other.md#小节"))
        let current = dir.appendingPathComponent("preview.html")

        // 旧行为：一律 .cancel ⇒ 死链。现在必须还原成文件路径并交给系统打开
        // （.md 的默认打开者是本应用 ⇒ 回到 app 里开 tab）。
        XCTAssertEqual(PreviewLinkNavigator.action(for: url, currentURL: current),
                       .open(other.standardizedFileURL))
    }

    func testCrossFileFragmentOnMissingFileIsCancelled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = MeditorAssetSchemeHandler.baseURLString(forDirectory: dir)
        let url = try XCTUnwrap(URL(string: base + "missing.md#小节"))
        XCTAssertEqual(PreviewLinkNavigator.action(for: url, currentURL: dir.appendingPathComponent("preview.html")),
                       .cancel, "目标不存在时不该弹出 Finder")
    }

    /// 纯页内锚点在 markdown 预览里也被 `<base>` 改写成「目录 + fragment」：
    /// 目录不是文件 ⇒ 策略层取消（真正的滚动由页面内的 HTMLAnchorGuard 做）。
    func testPageAnchorRewrittenToDirectoryIsCancelled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = MeditorAssetSchemeHandler.baseURLString(forDirectory: dir)
        let url = try XCTUnwrap(URL(string: base + "#小节"))
        XCTAssertEqual(PreviewLinkNavigator.action(for: url, currentURL: dir.appendingPathComponent("preview.html")),
                       .cancel)
    }

    func testSamePageAnchorIsAllowed() throws {
        let current = URL(fileURLWithPath: "/tmp/preview.html")
        let url = try XCTUnwrap(URL(string: "file:///tmp/preview.html#小节"))
        XCTAssertEqual(PreviewLinkNavigator.action(for: url, currentURL: current), .allow)
    }

    func testWebLinkOpensExternally() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(PreviewLinkNavigator.action(for: url, currentURL: URL(fileURLWithPath: "/tmp/preview.html")),
                       .open(url))
    }
}
