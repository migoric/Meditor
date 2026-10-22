import XCTest
@testable import MEditor

/// 冷启动恢复会话时，HTML tab 先以空内容入列（`awaitingInitialContent = true`），
/// 内容由后台读取回填。预览必须在这之后**再同步一次**，否则它会永远停在入场
/// 那次「加载空内容」上——表现为「一直白屏，切一下 tab 才渲染」。
///
/// 这里把 TabManager 与 PreviewManager 按 AppState 的接线方式连起来测，
/// 断言的是用户能看见的行为（预览内容与重新加载信号），不是内部调用次数。
@MainActor
final class PreviewRestoreSyncTests: XCTestCase {

    private var tabManager: TabManager!
    private var previewManager: PreviewManager!

    override func setUp() {
        super.setUp()
        tabManager = TabManager(fileService: MockFileService())
        previewManager = PreviewManager()
        // 与 AppState.init 里的接线一致：需要预览跟随时回调这一处。
        tabManager.onSyncPreview = { [unowned self] tab in
            self.previewManager.sync(from: tab)
        }
    }

    override func tearDown() {
        tabManager = nil
        previewManager = nil
        super.tearDown()
    }

    private func makeURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// 复现路径：恢复会话 → 空内容入列并选中 → 同步预览（加载空页）
    /// → 后台读完回填 → 预览应重新加载。
    func testRestoredHTMLTabReloadsPreviewWhenContentArrives() {
        let url = makeURL("html")
        let tab = EditorTab(url: url, content: "", language: .html, awaitingInitialContent: true)
        tabManager.openTabs.append(tab)
        tabManager.selectedTabID = tab.id

        // restoreSession 里对选中 tab 的首次同步：此时内容还是空串。
        previewManager.sync(from: tab)
        let tokenBeforeContentArrives = previewManager.reloadToken
        XCTAssertEqual(previewManager.mode, .html, "空内容阶段预览模式已经切到 html")

        // 后台读取完成，内容回填。
        tabManager.applyLoadedContent(tabID: tab.id, content: "<h1>hello</h1>")

        XCTAssertEqual(previewManager.content, "<h1>hello</h1>",
                       "内容回填后预览内容必须跟上，否则 WebPreviewView 拿到的永远是空串")
        XCTAssertGreaterThan(previewManager.reloadToken, tokenBeforeContentArrives,
                             "reloadToken 是 WebPreviewView 重新加载的唯一信号，不递增就不会重新渲染")
    }

    /// 背景 tab（未选中）读取完成不应打断当前预览。
    func testBackgroundHTMLTabLoadDoesNotTouchPreview() {
        let mdTab = EditorTab(url: makeURL("md"), content: "# 当前文档", language: .markdown)
        let htmlTab = EditorTab(url: makeURL("html"), content: "", language: .html,
                                awaitingInitialContent: true)
        tabManager.openTabs.append(contentsOf: [mdTab, htmlTab])
        tabManager.selectedTabID = mdTab.id
        previewManager.sync(from: mdTab)
        let tokenWhenMarkdownShown = previewManager.reloadToken

        tabManager.applyLoadedContent(tabID: htmlTab.id, content: "<h1>background</h1>")

        XCTAssertEqual(previewManager.mode, .markdown, "背景 tab 的内容回填不该切换预览模式")
        XCTAssertEqual(previewManager.content, "# 当前文档", "背景 tab 不该覆盖当前预览内容")
        XCTAssertEqual(previewManager.reloadToken, tokenWhenMarkdownShown,
                       "背景 tab 不该触发额外重新加载")
    }

    /// markdown 的既有行为不能回归：内容回填后同样要刷新预览。
    ///
    /// 注意 markdown 的刷新信号是 `contentRevision`（MarkdownWebPreview 读它），
    /// HTML 才是 `reloadToken`——两者的驱动通道不同，别互相套用。
    func testRestoredMarkdownTabStillReloadsPreview() {
        let url = makeURL("md")
        let tab = EditorTab(url: url, content: "", language: .markdown, awaitingInitialContent: true)
        tabManager.openTabs.append(tab)
        tabManager.selectedTabID = tab.id
        previewManager.sync(from: tab)
        let revisionBefore = previewManager.contentRevision

        tabManager.applyLoadedContent(tabID: tab.id, content: "# restored")

        XCTAssertEqual(previewManager.content, "# restored")
        XCTAssertGreaterThan(previewManager.contentRevision, revisionBefore)
    }
}
