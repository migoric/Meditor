import XCTest
@testable import MEditor

// MARK: - Mock

final class MockFileWatcher: FileWatcherServiceProtocol {
    private(set) var watchedURLs: [URL] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var onChange: (@Sendable ([URL]) -> Void)?

    func startWatching(urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) {
        watchedURLs = urls
        startCallCount += 1
        self.onChange = onChange
    }

    func stopWatching() {
        stopCallCount += 1
        onChange = nil
    }
}

final class DelayedFileService: MockFileService, @unchecked Sendable {
    var readDelay: TimeInterval = 0.15

    override func readFile(at url: URL) throws -> String {
        Thread.sleep(forTimeInterval: readDelay)
        if let readError {
            throw readError
        }
        return try super.readFile(at: url)
    }
}

// MARK: - Tests

@MainActor
final class AppStateTests: XCTestCase {

    var state: AppState!
    var mockService: MockFileService!
    var mockWatcher: MockFileWatcher!

    override func setUp() async throws {
        try await super.setUp()
        mockService = MockFileService()
        mockWatcher = MockFileWatcher()
        state = AppState(fileService: mockService, fileWatcher: mockWatcher)
    }

    override func tearDown() async throws {
        state = nil
        mockService = nil
        mockWatcher = nil
        try await super.tearDown()
    }

    // MARK: - historyStore 注入

    func test_historyStore_injectableWithTempDir() {
        // 注入临时目录的 store：init 的后台清理不碰真实 ~/Library
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LocalHistoryStore(baseDir: tmp)
        let s = AppState(fileService: mockService, fileWatcher: mockWatcher,
                         historyStore: store)
        let bucket = s.historyStore.bucketURL(for: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertTrue(bucket.path.hasPrefix(tmp.path))
    }

    // MARK: - Helpers

    func makeItem(_ name: String, isDir: Bool = false) -> FileItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return FileItem(url: url, isDirectory: isDir)
    }

    func setupTab(_ name: String, content: String = "", language: EditorLanguage = .markdown) -> EditorTab {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        mockService.setFile(url, content: content)
        let item = FileItem(url: url, isDirectory: false)
        state.openFile(item)
        waitForCondition {
            self.state.selectedTab?.url == url && self.state.selectedTab?.content == content
        }
        return state.selectedTab!
    }

    func waitForCondition(timeout: TimeInterval = 10.0,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          _ condition: () -> Bool) {
        // 轮询 + 提前返回：上限放宽到 10s 不影响本地速度，只为 CI 慢机留足余量。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    // MARK: - File Tree

    /// Spin the main run loop until `condition` holds or timeout — 用于等待后台 IO
    /// (Task.detached) 异步更新 @MainActor 状态后再断言。
    private func waitUntil(_ timeout: TimeInterval = 10,
                           file: StaticString = #file, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            // 驱动主 runloop 处理后台 Task.detached 完成后回主线程的 @MainActor 更新；
            // 用 run(mode:before:) 在有事件时尽早返回，条件满足后能更快跳出，减少无谓等待。
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "等待条件超时（\(timeout)s）", file: file, line: line)
    }

    func test_openFolder_setsRootURLAndReloadsTree() {
        let root = URL(fileURLWithPath: "/tmp/project")
        mockService.setChildren([
            makeItem("readme.md"),
            makeItem("src", isDir: true),
        ], for: root)

        state.openFolder(root)

        XCTAssertEqual(state.rootURL, root)
        waitUntil { state.fileTree.count == 2 }
        XCTAssertEqual(state.fileTree.count, 2)
        XCTAssertEqual(state.previewFindController.activeMode, .empty)
    }

    func test_reloadFileTree_clearsMapAndReloads() {
        let root = URL(fileURLWithPath: "/tmp/project")
        mockService.setChildren([
            makeItem("a.md"),
            makeItem("b.md"),
        ], for: root)
        state.openFolder(root)
        waitUntil { state.fileTree.count == 2 }
        let staleURL = URL(fileURLWithPath: "/tmp/c.md")
        state.fileTreeManager.fileItemMap[staleURL] = makeItem("c.md") // add stale entry

        state.reloadFileTree()

        waitUntil { state.fileTree.count == 2 && state.fileItemMap.count == 2 }
        XCTAssertEqual(state.fileTree.count, 2)
        XCTAssertEqual(state.fileItemMap.count, 2) // stale entry cleared
    }

    // MARK: - Tab Management

    func test_openFile_createsTab() {
        let url = URL(fileURLWithPath: "/tmp/hello.md")
        let item = FileItem(url: url, isDirectory: false)
        mockService.setFile(url, content: "# Hello")

        state.openFile(item)
        waitForCondition { self.state.selectedTab?.content == "# Hello" }

        XCTAssertEqual(state.openTabs.count, 1)
        XCTAssertEqual(state.selectedTab?.name, "hello.md")
        XCTAssertEqual(state.selectedTab?.content, "# Hello")
        XCTAssertEqual(state.selectedTab?.language, .markdown)
        XCTAssertEqual(state.selectedFileID, item.id)
    }

    func test_openFile_reusesExistingTab() {
        let tab = setupTab("hello.md", content: "# Hello")
        let item = FileItem(url: tab.url, isDirectory: false)

        state.openFile(item) // open same file again

        // Should reuse existing tab, not create a new one
        XCTAssertEqual(state.openTabs.count, 1)
        XCTAssertEqual(state.selectedTabID, tab.id)
    }

    func test_openFile_doesNotOpenDirectories() {
        let item = makeItem("subdir", isDir: true)

        state.openFile(item)

        XCTAssertEqual(state.openTabs.count, 0)
    }

    func test_openFile_setsEditorLanguageForHTML() {
        let url = URL(fileURLWithPath: "/tmp/page.html")
        mockService.setFile(url, content: "<h1>Hi</h1>")
        let item = FileItem(url: url, isDirectory: false)

        state.openFile(item)
        waitForCondition { self.state.selectedTab?.content == "<h1>Hi</h1>" }

        XCTAssertEqual(state.selectedTab?.language, .html)
        XCTAssertEqual(state.previewFindController.activeMode, .html)
    }

    func test_syncPreviewContent_hidesPreviewFindWhenPreviewBecomesEmpty() {
        state.previewFindController.show()

        // previewMode is now a forwarded get-only property; use clearPreview() to trigger the side-effect
        state.clearPreview()

        XCTAssertFalse(state.previewFindController.isPresented)
        XCTAssertEqual(state.previewFindController.activeMode, .empty)
    }

    func test_showMarkdownPreview_emptyContentKeepsMarkdownMode() {
        state.showMarkdownPreview(content: "")

        XCTAssertEqual(state.previewMode, .markdown)
        XCTAssertEqual(state.previewContent, "")
        XCTAssertEqual(state.previewFindController.activeMode, .markdown)
    }

    func test_openFile_delayedMarkdownLoadDoesNotFlashEmptyPreview() {
        let delayedService = DelayedFileService()
        delayedService.readDelay = 0.2
        let delayedState = AppState(fileService: delayedService, fileWatcher: mockWatcher)
        let url = URL(fileURLWithPath: "/tmp/delayed.md")
        delayedService.setFile(url, content: "# Loaded")
        // 报一个介于同步阈值(512KB)与大文件阈值(1MB)之间的尺寸，强制走异步路径——
        // 小文件现在是同步读盘（避免空白骨架闪烁），异步行为要用「大文件」来验
        delayedService.mockAttributes[url] = [.size: Int64(768 * 1024)]

        delayedState.openFile(FileItem(url: url, isDirectory: false))

        XCTAssertEqual(delayedState.previewMode, .markdown)
        XCTAssertEqual(delayedState.previewContent, "")
        XCTAssertEqual(delayedState.previewFindController.activeMode, .markdown)
        XCTAssertTrue(delayedState.selectedTab?.awaitingInitialContent == true)

        waitForCondition {
            delayedState.selectedTab?.content == "# Loaded"
        }

        XCTAssertEqual(delayedState.previewMode, .markdown)
        XCTAssertEqual(delayedState.previewContent, "# Loaded")
    }

    func test_closeTab_removesTab() {
        let tab1 = setupTab("a.md")
        let tab2 = setupTab("b.md")

        state.closeTab(tab1.id)

        XCTAssertEqual(state.openTabs.count, 1)
        XCTAssertEqual(state.openTabs[0].id, tab2.id)
    }

    func test_closeTab_unmodifiedWithConfirmation() {
        let tab = setupTab("a.md")
        // Don't modify — isModified stays false

        state.closeTab(tab.id)

        // Should close immediately without confirmation
        XCTAssertFalse(state.showingCloseConfirmation)
        XCTAssertNil(state.pendingCloseTab)
        XCTAssertTrue(state.openTabs.isEmpty)
    }

    func test_closeTab_modifiedShowsConfirmation() {
        let tab = setupTab("a.md", content: "original")
        state.updateTabContent(tab.id, content: "modified")

        state.closeTab(tab.id)

        XCTAssertTrue(state.showingCloseConfirmation)
        XCTAssertEqual(state.pendingCloseTab?.id, tab.id)
        XCTAssertEqual(state.openTabs.count, 1) // not removed yet
    }

    func test_confirmCloseTab_withSave() {
        let tab = setupTab("a.md", content: "original")
        state.updateTabContent(tab.id, content: "modified")

        state.closeTab(tab.id)
        state.confirmCloseTab(save: true)

        // saveTab 是 Task.detached 异步落盘——直接断言会和写入竞争（CI 慢机上 flake 过两次）
        waitForCondition { self.mockService.fileContent(at: tab.url) == "modified" }
        XCTAssertTrue(state.openTabs.isEmpty)
        XCTAssertFalse(state.showingCloseConfirmation)
    }

    func test_confirmCloseTab_withoutSave() {
        let tab = setupTab("a.md", content: "original")
        state.updateTabContent(tab.id, content: "modified")

        state.closeTab(tab.id)
        state.confirmCloseTab(save: false)

        // Should NOT have saved
        XCTAssertEqual(mockService.fileContent(at: tab.url), "original")
        XCTAssertTrue(state.openTabs.isEmpty)
    }

    func test_closeTab_selectsNextTab() {
        let tab1 = setupTab("a.md")
        let tab2 = setupTab("b.md")

        state.closeTab(tab1.id)

        XCTAssertEqual(state.selectedTabID, tab2.id)
    }

    func test_closeTab_selectsPreviousTabWhenLast() {
        let tab1 = setupTab("a.md")
        let tab2 = setupTab("b.md")

        state.closeTab(tab2.id) // close last tab

        XCTAssertEqual(state.selectedTabID, tab1.id)
    }

    func test_closeLastTab_clearsSelection() {
        let tab = setupTab("a.md")

        state.closeTab(tab.id)

        XCTAssertNil(state.selectedTabID)
        XCTAssertEqual(state.previewContent, "")
    }

    // 回归：closeOtherTabs/closeAllTabs 逐张处理 dirty tab（此前单槽 pendingCloseTab
    // 只保留最后一个，前面的 dirty tab 既不确认也不关闭）。
    func test_closeOtherTabs_multipleDirty_confirmEachAndCloseAll() {
        let keep = setupTab("keep.md", content: "K")
        let b = setupTab("b.md", content: "B")
        let c = setupTab("c.md", content: "C")
        state.updateTabContent(keep.id, content: "K2")
        state.updateTabContent(b.id, content: "B2")
        state.updateTabContent(c.id, content: "C2")

        state.closeOtherTabs(keeping: keep.id)
        XCTAssertTrue(state.showingCloseConfirmation, "第一张 dirty tab 应弹确认")

        state.confirmCloseTab(save: false)                     // 处理 b
        waitUntil { self.state.showingCloseConfirmation }       // c 的确认框（异步重新弹）
        state.confirmCloseTab(save: false)                     // 处理 c

        waitUntil { self.state.openTabs.count == 1 }
        XCTAssertEqual(state.openTabs.first?.id, keep.id)
    }

    func test_closeAllTabs_cleanTabsClosedImmediately() {
        let a = setupTab("a.md", content: "A")
        let b = setupTab("b.md", content: "B")

        state.closeAllTabs()

        XCTAssertTrue(state.openTabs.isEmpty)
        XCTAssertNil(state.selectedTabID)
        _ = (a, b)
    }

    // MARK: - Tab Selection

    func test_selectTab_switchesPreview() {
        let tab1 = setupTab("a.md", content: "# A")
        _ = setupTab("b.md", content: "# B")

        state.selectTab(tab1.id)

        XCTAssertEqual(state.selectedTabID, tab1.id)
        XCTAssertEqual(state.previewContent, "# A")
    }

    func test_selectedTab_computedProperty() {
        let tab = setupTab("a.md")
        XCTAssertEqual(state.selectedTab?.id, tab.id)

        state.selectedTab = nil
        XCTAssertNil(state.selectedTabID)
    }

    // MARK: - Tab Content

    func test_updateTabContent_updatesAndMarksModified() {
        let tab = setupTab("a.md", content: "original")

        state.updateTabContent(tab.id, content: "modified")

        XCTAssertEqual(state.openTabs[0].content, "modified")
        XCTAssertTrue(state.openTabs[0].isModified)
    }

    func test_updateTabContent_nonSelectedTabDoesNotTriggerPreview() {
        let tab1 = setupTab("a.md", content: "# A")
        _ = setupTab("b.md", content: "# B")

        // Update the non-selected tab (tab1, since tab2 is selected)
        state.updateTabContent(tab1.id, content: "# A modified")

        // Preview should still show tab2's content
        XCTAssertEqual(state.previewContent, "# B")
    }

    // MARK: - Insert（回归：纯预览 / AI 模式下插入不得静默丢失）

    /// 回归 bug：编辑器未挂载时 insertIntoEditor 直接改 tab.content 而不置 isModified，
    /// 导致 saveTab 的 `guard tab.isModified` 与自动保存过滤都跳过、closeTab 也不提示。
    func test_insertIntoEditor_previewOnly_marksModifiedAndAppends() {
        let tab = setupTab("a.md", content: "hello")
        tab.language = .markdown
        state.isEditorMounted = false

        state.insertIntoEditor("world")

        XCTAssertEqual(state.openTabs[0].content, "hello\n\nworld")
        XCTAssertTrue(state.openTabs[0].isModified, "插入必须标记为已修改，否则永不落盘")
    }

    func test_insertIntoEditor_previewOnly_emptyContentNoLeadingBlankLine() {
        let tab = setupTab("empty.md", content: "")
        tab.language = .markdown
        state.isEditorMounted = false

        state.insertIntoEditor("first")

        XCTAssertEqual(state.openTabs[0].content, "first")
        XCTAssertTrue(state.openTabs[0].isModified)
    }

    func test_insertIntoEditor_previewOnly_htmlInsertsBeforeBodyClose() {
        let tab = setupTab("page.html", content: "<html><body>old</body></html>")
        tab.language = .html
        state.isEditorMounted = false

        state.insertIntoEditor("<p>new</p>")

        XCTAssertEqual(state.openTabs[0].content, "<html><body>old\n<p>new</p>\n</body></html>")
        XCTAssertTrue(state.openTabs[0].isModified)
    }

    func test_insertIntoEditor_previewOnly_closeTabRequiresConfirmation() {
        _ = setupTab("a.md", content: "hello")
        state.isEditorMounted = false
        state.insertIntoEditor("world")

        state.closeTab(state.openTabs[0].id)

        XCTAssertTrue(state.showingCloseConfirmation, "已修改的 tab 关闭前必须弹确认")
        XCTAssertEqual(state.openTabs.count, 1, "确认前不得关闭 tab")
    }

    // MARK: - Save

    func test_saveTab_writesAndClearsModified() {
        let tab = setupTab("a.md", content: "original")
        state.updateTabContent(tab.id, content: "updated")

        state.saveTab(state.openTabs[0])

        waitUntil { mockService.fileContent(at: tab.url) == "updated" }
        XCTAssertFalse(state.openTabs[0].isModified)
        XCTAssertEqual(mockService.fileContent(at: tab.url), "updated")
    }

    func test_saveTab_unmodifiedDoesNothing() {
        let tab = setupTab("a.md", content: "hello")

        state.saveTab(state.openTabs[0])

        // Original file content unchanged (since we never modified)
        XCTAssertEqual(mockService.fileContent(at: tab.url), "hello")
    }

    func test_saveCurrentTab_noSelectedTabDoesNothing() {
        // No crash when there's no selected tab
        state.saveCurrentTab()
        XCTAssertTrue(state.openTabs.isEmpty, "无选中 tab 时不应产生任何 tab")
    }

    // MARK: - Tab Move

    func test_moveTab_reorders() {
        _ = setupTab("a.md")
        _ = setupTab("b.md")
        _ = setupTab("c.md")

        // Tabs are inserted at the front, so current order is c, b, a.
        // Move "a.md" from index 2 to index 0.
        state.moveTab(from: 2, to: 0)

        XCTAssertEqual(state.openTabs[0].name, "a.md")
        XCTAssertEqual(state.openTabs[1].name, "c.md")
        XCTAssertEqual(state.openTabs[2].name, "b.md")
    }

    func test_moveTab_invalidIndexesDoesNothing() {
        _ = setupTab("a.md")
        _ = setupTab("b.md")

        state.moveTab(from: 5, to: 0)

        XCTAssertEqual(state.openTabs.count, 2)
        XCTAssertEqual(state.openTabs[0].name, "b.md")
    }

    // MARK: - Preview

    func test_openFile_syncsPreview() {
        let url = URL(fileURLWithPath: "/tmp/preview.md")
        mockService.setFile(url, content: "# Preview")
        let item = FileItem(url: url, isDirectory: false)

        state.openFile(item)
        waitForCondition { self.state.previewContent == "# Preview" }

        XCTAssertEqual(state.previewContent, "# Preview")
        XCTAssertEqual(state.previewLanguage, .markdown)
    }

    func test_updateTabContent_selectedTabSyncsPreviewImmediately() {
        let tab = setupTab("preview.md", content: "# Before")

        state.updateTabContent(tab.id, content: "# After")

        XCTAssertEqual(state.previewContent, "# After")
    }

    func test_syncPreviewContent_noChangeDoesNotIncrementRevision() {
        _ = setupTab("preview.md", content: "# Stable")
        let revision = state.previewContentRevision

        state.syncPreviewContent(from: state.openTabs[0])

        XCTAssertEqual(state.previewContentRevision, revision)
    }

    func test_saveTab_selectedTabDoesNotResyncPreviewWhenContentUnchanged() {
        let tab = setupTab("preview.md", content: "# Before")
        state.updateTabContent(tab.id, content: "# After")
        let revisionAfterEdit = state.previewContentRevision

        state.saveTab(state.openTabs[0])

        XCTAssertEqual(state.previewContentRevision, revisionAfterEdit)
    }

    func test_currentFileSize_returnsFormattedSize() {
        _ = setupTab("a.md", content: "hello")

        XCTAssertFalse(state.currentFileSize.isEmpty)
        XCTAssertTrue(state.currentFileSize.contains("5")) // "hello" is 5 bytes
    }

    func test_currentFileSize_noSelectedTab_returnsEmpty() {
        // Expect empty string when no tab is selected
        // This can happen if selectedTabID is nil but openTabs has entries
        XCTAssertEqual(state.currentFileSize, "")
    }

    // MARK: - Security Scoped Resources

    func test_beginEndAccessing_roundTrip() {
        let url = URL(fileURLWithPath: "/tmp/test.md")
        state.beginAccessing(url)
        state.endAccessing(url)
        XCTAssertNil(state.accessRefCount(for: url), "endAccessing 后引用计数应清空")
        // 重复 end 幂等，不应崩溃
        state.endAccessing(url)
        XCTAssertNil(state.accessRefCount(for: url))
    }

    // MARK: - Cursor

    func test_updateCursorPosition() {
        state.updateCursorPosition(line: 5, column: 12)
        XCTAssertEqual(state.cursorLine, 5)
        XCTAssertEqual(state.cursorColumn, 12)
    }

    // MARK: - Error

    func test_setError() {
        state.setError("Something went wrong")
        XCTAssertEqual(state.errorMessage, "Something went wrong")
    }

    func test_handleItemRenamed_updatesOpenTabsAndSelection() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let original = root.appendingPathComponent("docs/readme.md")
        let renamed = root.appendingPathComponent("guides/intro.md")

        state.rootURL = root
        state.openTabs = [EditorTab(url: original, content: "# Readme", language: .markdown)]
        state.selectedTabID = state.openTabs[0].id
        state.selectedFileID = original
        state.previewManager.showMarkdown(content: "# Readme")

        state.handleItemRenamed(from: original, to: renamed)

        XCTAssertEqual(state.openTabs[0].url, renamed)
        XCTAssertEqual(state.selectedFileID, renamed)
        XCTAssertEqual(state.selectedTab?.url, renamed)
    }

    func test_handleItemDeleted_closesMatchingTabsAndClearsPreview() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let deleted = root.appendingPathComponent("docs/readme.md")

        state.rootURL = root
        state.openTabs = [EditorTab(url: deleted, content: "# Readme", language: .markdown)]
        state.selectedTabID = state.openTabs[0].id
        state.selectedFileID = deleted
        state.previewManager.showMarkdown(content: "# Readme")

        state.handleItemDeleted(at: deleted)

        XCTAssertTrue(state.openTabs.isEmpty)
        XCTAssertNil(state.selectedTabID)
        XCTAssertNil(state.selectedFileID)
        XCTAssertEqual(state.previewContent, "")
        XCTAssertEqual(state.previewMode, .empty)
    }

    func test_restoreSession_keepsSelectedTabWhenEarlierBookmarksDisappear() throws {
        let suiteName = "AppStateRestoreSessionTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let sessionStore = SessionStore(userDefaults: defaults)
        defer {
            sessionStore.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorRestoreSession_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingURL = tempDir.appendingPathComponent("missing.md")
        let selectedURL = tempDir.appendingPathComponent("selected.md")
        try "# Missing".write(to: missingURL, atomically: true, encoding: .utf8)
        try "# Selected".write(to: selectedURL, atomically: true, encoding: .utf8)

        sessionStore.saveNow(
            rootURL: tempDir,
            openTabURLs: [missingURL, selectedURL],
            selectedIndex: 1
        )
        try FileManager.default.removeItem(at: missingURL)

        let restoreState = AppState(fileService: mockService, fileWatcher: mockWatcher, sessionStore: sessionStore)
        mockService.setFile(selectedURL, content: "# Selected")

        restoreState.restoreSession()
        waitForCondition {
            restoreState.selectedTab?.url.standardizedFileURL == selectedURL.standardizedFileURL
        }

        XCTAssertEqual(restoreState.openTabs.count, 1)
        XCTAssertEqual(restoreState.selectedTab?.url.standardizedFileURL, selectedURL.standardizedFileURL)
    }

    func test_openFile_asyncLoadDoesNotOverwriteUserEdits() {
        let delayedService = DelayedFileService()
        let delayedWatcher = MockFileWatcher()
        let delayedState = AppState(fileService: delayedService, fileWatcher: delayedWatcher)
        let url = URL(fileURLWithPath: "/tmp/delayed.md")
        delayedService.setFile(url, content: "# Disk")
        // 同上：强制异步路径，否则小文件同步读完就没有「异步回填」可测了
        delayedService.mockAttributes[url] = [.size: Int64(768 * 1024)]

        delayedState.openFile(FileItem(url: url, isDirectory: false))
        guard let tabID = delayedState.selectedTabID else {
            return XCTFail("Expected tab to open")
        }

        delayedState.updateTabContent(tabID, content: "# Edited")
        waitForCondition {
            delayedState.selectedTab?.content == "# Edited" &&
            delayedState.selectedTab?.awaitingInitialContent == false
        }

        XCTAssertEqual(delayedState.selectedTab?.content, "# Edited")
        XCTAssertTrue(delayedState.selectedTab?.isModified == true)
    }

    func test_openFile_asyncFailureDoesNotCloseEditedTab() {
        let delayedService = DelayedFileService()
        delayedService.readError = NSError(domain: "mock", code: 2, userInfo: nil)
        let delayedWatcher = MockFileWatcher()
        let delayedState = AppState(fileService: delayedService, fileWatcher: delayedWatcher)
        let url = URL(fileURLWithPath: "/tmp/failing.md")
        delayedService.setFile(url, content: "# Disk")

        delayedState.openFile(FileItem(url: url, isDirectory: false))
        guard let tabID = delayedState.selectedTabID else {
            return XCTFail("Expected tab to open")
        }

        delayedState.updateTabContent(tabID, content: "# Edited")
        waitForCondition {
            delayedState.openTabs.count == 1 &&
            delayedState.selectedTab?.content == "# Edited"
        }

        XCTAssertEqual(delayedState.openTabs.count, 1)
        XCTAssertEqual(delayedState.selectedTab?.content, "# Edited")
    }
}
