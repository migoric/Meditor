import XCTest
@testable import MEditor

@MainActor
final class TabManagerTests: XCTestCase {

    var tabManager: TabManager!
    var mockService: MockFileService!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        mockService = MockFileService()
        tabManager = TabManager(fileService: mockService)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabManagerTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        tabManager = nil
        mockService = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeFile(_ name: String, size: Int64 = 100) -> FileItem {
        let url = tempDir.appendingPathComponent(name)
        // 只落 min(size, 64KB) 的真实字节：体积一律由 mockAttributes 提供，
        // 免得「20 MB 上限判定」这类用例真往磁盘写 20 MB。填 'a' 而非 0，
        // 避免文本解码器把 NUL 当二进制拒掉。
        let materialized = Int(min(size, 64 * 1024))
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data(repeating: 0x61, count: materialized))
        mockService.mockAttributes[url] = [.size: size]
        return FileItem(url: url, isDirectory: false)
    }

    // MARK: - openFile

    /// 超过上限：报告错误、不建 tab、**不弹确认框**。
    /// 旧实现是「1 MB 以上先问一句仍要打开吗」，两种回答都不带来新信息
    /// （降级早在 150 KB / 512 KB 就发生了），见 TabManager.openSizeLimit 注释。
    func testOpenFileBeyondLimitReportsErrorAndOpensNothing() {
        var reported: AppError?
        tabManager.onReport = { reported = $0 }

        let item = makeFile("big.md", size: TabManager.openSizeLimit + 1)
        XCTAssertFalse(tabManager.openFile(item), "超限必须返回 false")

        guard case .fileTooLarge(let url, size: let size, limit: let limit)? = reported else {
            return XCTFail("应报告 .fileTooLarge，实际 \(String(describing: reported))")
        }
        XCTAssertEqual(url, item.url)
        XCTAssertEqual(size, TabManager.openSizeLimit + 1)
        XCTAssertEqual(limit, TabManager.openSizeLimit)
        XCTAssertTrue(tabManager.openTabs.isEmpty, "超限不得留下未加载的 tab")
    }

    /// 1 MB–上限之间：直接打开，不再打扰。
    func testOpenFileBetweenOneMegabyteAndLimitOpensDirectly() {
        let item = makeFile("large-enough.md", size: 8 * 1024 * 1024)
        XCTAssertTrue(tabManager.openFile(item))
        XCTAssertEqual(tabManager.openTabs.count, 1)
    }

    /// HTML 放宽到 32 MB：带 base64 图片的单页文章常态就过 16 MB。
    func testOpenFileHTMLExtendsLimit() {
        var reported: AppError?
        tabManager.onReport = { reported = $0 }

        let html = makeFile("page.html", size: 20 * 1024 * 1024)
        XCTAssertTrue(tabManager.openFile(html), "20 MB 的 HTML 未超 32 MB 上限")
        XCTAssertNil(reported)

        let htm = makeFile("page.htm", size: TabManager.openSizeLimitHTML + 1)
        XCTAssertFalse(tabManager.openFile(htm))
        guard case .fileTooLarge(_, size: _, limit: let limit)? = reported else {
            return XCTFail("超 32 MB 的 HTML 也应被拒，实际 \(String(describing: reported))")
        }
        XCTAssertEqual(limit, TabManager.openSizeLimitHTML)
    }

    func testOpenFileSmallFileOpensTab() {
        let item = makeFile("small.md", size: 100)
        XCTAssertTrue(tabManager.openFile(item))
        XCTAssertEqual(tabManager.openTabs.count, 1)
    }

    // MARK: - openFile

    func testOpenFileUncheckedExistingTabDoesNotDuplicate() {
        let item = makeFile("a.md")
        tabManager.openFile(item)
        XCTAssertEqual(tabManager.openTabs.count, 1)
        let firstTabID = tabManager.openTabs[0].id

        tabManager.openFile(item)
        XCTAssertEqual(tabManager.openTabs.count, 1)
        XCTAssertEqual(tabManager.selectedTabID, firstTabID)
    }

    func testOpenFileUncheckedSymlinkVariantURLDoesNotDuplicate() {
        let item = makeFile("a2.md")
        tabManager.openFile(item)
        XCTAssertEqual(tabManager.openTabs.count, 1)
        let firstTabID = tabManager.openTabs[0].id

        // tempDir 在 /var/folders 下（/var → /private/var）：
        // 同一文件的符号链接变体 URL 不应开出第二个 tab
        let resolvedURL = item.url.resolvingSymlinksInPath()
        guard resolvedURL != item.url else { return }
        let variant = FileItem(url: resolvedURL, isDirectory: false)
        mockService.mockAttributes[resolvedURL] = [.size: 100]

        tabManager.openFile(variant)
        XCTAssertEqual(tabManager.openTabs.count, 1)
        XCTAssertEqual(tabManager.selectedTabID, firstTabID)
    }

    // MARK: - closeTab

    func testCloseTabModifiedShowsConfirmation() {
        let item = makeFile("b.md")
        tabManager.openFile(item)
        tabManager.openTabs[0].isModified = true
        let tabID = tabManager.openTabs[0].id

        tabManager.closeTab(tabID)

        XCTAssertTrue(tabManager.showingCloseConfirmation)
        XCTAssertNotNil(tabManager.pendingCloseTab)
        XCTAssertEqual(tabManager.openTabs.count, 1)
    }

    func testCloseTabUnmodifiedClosesDirectly() {
        let item = makeFile("c.md")
        tabManager.openFile(item)
        let tabID = tabManager.openTabs[0].id

        tabManager.closeTab(tabID)

        XCTAssertFalse(tabManager.showingCloseConfirmation)
        XCTAssertTrue(tabManager.openTabs.isEmpty)
    }

    // MARK: - performCloseTab

    func testPerformCloseLastTabSetsSelectedTabIDNil() {
        let item = makeFile("d.md")
        tabManager.openFile(item)
        let tabID = tabManager.openTabs[0].id

        tabManager.performCloseTab(tabID)

        XCTAssertNil(tabManager.selectedTabID)
        XCTAssertTrue(tabManager.openTabs.isEmpty)
    }

    func testPerformCloseSelectsNeighbour() {
        let a = makeFile("a.md")
        let b = makeFile("b.md")
        tabManager.openFile(a)
        tabManager.openFile(b)
        let bID = tabManager.openTabs[0].id

        tabManager.performCloseTab(bID)

        XCTAssertNotNil(tabManager.selectedTabID)
        XCTAssertEqual(tabManager.openTabs.count, 1)
    }

    // MARK: - selectNextTab / selectPreviousTab

    func testSelectNextTabWrapsAround() {
        let a = makeFile("a.md"); let b = makeFile("b.md"); let c = makeFile("c.md")
        tabManager.openFile(a)
        tabManager.openFile(b)
        tabManager.openFile(c)
        // Tabs are inserted at index 0, so order is [c, b, a].
        let lastID = tabManager.openTabs.last!.id
        tabManager.selectedTabID = lastID

        tabManager.selectNextTab()

        XCTAssertEqual(tabManager.selectedTabID, tabManager.openTabs.first?.id,
                       "next from last should wrap to first")
    }

    func testSelectPreviousTabWrapsAround() {
        let a = makeFile("a.md"); let b = makeFile("b.md")
        tabManager.openFile(a)
        tabManager.openFile(b)
        let firstID = tabManager.openTabs.first!.id
        tabManager.selectedTabID = firstID

        tabManager.selectPreviousTab()

        XCTAssertEqual(tabManager.selectedTabID, tabManager.openTabs.last?.id,
                       "previous from first should wrap to last")
    }

    // MARK: - moveTab

    func testMoveTabInBounds() {
        let a = makeFile("a.md"); let b = makeFile("b.md"); let c = makeFile("c.md")
        tabManager.openFile(a)
        tabManager.openFile(b)
        tabManager.openFile(c)
        let originalFirst = tabManager.openTabs[0].url

        tabManager.moveTab(from: 0, to: 2)

        XCTAssertEqual(tabManager.openTabs[2].url, originalFirst)
    }

    func testMoveTabOutOfBoundsDoesNotCrash() {
        let a = makeFile("a.md")
        tabManager.openFile(a)

        XCTAssertNoThrow(tabManager.moveTab(from: 0, to: 99))
        XCTAssertNoThrow(tabManager.moveTab(from: -1, to: 0))
        XCTAssertEqual(tabManager.openTabs.count, 1)
    }

    // MARK: - reopenLastClosedTab

    func testReopenLastClosedTabRestoresTab() {
        let item = makeFile("reopen.md")
        tabManager.openFile(item)
        let tabID = tabManager.openTabs[0].id
        tabManager.performCloseTab(tabID)
        XCTAssertTrue(tabManager.openTabs.isEmpty)

        tabManager.reopenLastClosedTab()

        XCTAssertEqual(tabManager.openTabs.count, 1)
        XCTAssertEqual(tabManager.openTabs[0].url, item.url)
    }

    // MARK: - updateTabContent

    func testUpdateTabContentMarksModified() {
        let item = makeFile("mod.md")
        tabManager.openFile(item)
        let tabID = tabManager.openTabs[0].id
        tabManager.openTabs[0].isModified = false

        tabManager.updateTabContent(tabID, content: "new content")

        XCTAssertEqual(tabManager.openTabs[0].isModified, true)
        XCTAssertEqual(tabManager.openTabs[0].content, "new content")
    }

    // MARK: - reopenLastClosedTab (multiple closes)

    func testReopenClosedTabAfterMultipleCloses() {
        let a = makeFile("a.md")
        let b = makeFile("b.md")
        let c = makeFile("c.md")
        tabManager.openFile(a)
        tabManager.openFile(b)
        tabManager.openFile(c)
        let aID = tabManager.openTabs.first { $0.url == a.url }!.id
        let bID = tabManager.openTabs.first { $0.url == b.url }!.id
        tabManager.performCloseTab(aID)
        tabManager.performCloseTab(bID)

        tabManager.reopenLastClosedTab()

        XCTAssertTrue(
            tabManager.openTabs.contains { $0.url == b.url },
            "Most recently closed tab (b) should be restored first"
        )
    }

    // MARK: - saveTab

    func testSaveTabClearsModifiedFlag() {
        let item = makeFile("save.md")
        tabManager.openFile(item)
        let tab = tabManager.openTabs[0]
        tab.isModified = true

        tabManager.saveTab(tab)

        XCTAssertFalse(tab.isModified, "saveTab should clear isModified after a successful write")
    }

    /// M1 回归：同一 URL 的两次快速保存必须按触发顺序落盘。
    /// 第一次写盘被人为放慢；若没有 per-URL 串行化，第二次（新内容）会先写完，
    /// 随后被第一次的旧内容覆盖。
    func testSaveTabSerializesConcurrentWritesForSameURL() async throws {
        let item = makeFile("race.md")
        tabManager.openFile(item)
        let tab = tabManager.openTabs[0]

        mockService.writeDelay = 0.3
        tabManager.updateTabContent(tab.id, content: "old content")
        tabManager.saveTab(tab)

        mockService.writeDelay = 0
        tabManager.updateTabContent(tab.id, content: "new content")
        tabManager.saveTab(tab)

        let deadline = Date().addingTimeInterval(5)
        while mockService.writeCount < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(mockService.writeCount, 2, "both saves should complete")
        XCTAssertEqual(
            mockService.fileContent(at: item.url), "new content",
            "the newer save must land last; the slower older write must not overwrite it"
        )
    }
}
