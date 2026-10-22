import XCTest
@testable import MEditor

/// Regression tests for the sidebar-not-refreshing bug: when a file/folder is
/// created externally (Finder, terminal, git) inside a directory that is
/// already expanded in the sidebar, `reload(rootURL:)` must pick it up.
///
/// Root cause: `DirectoryRow.onChange(of: isExpanded)` only fires when the
/// expansion state *flips*. An already-expanded directory's `isExpanded`
/// never changes, so if `reload` merely marks `childrenLoaded = false` (the
/// old behavior), the new item is never fetched until the user manually
/// collapses and re-expands. `reload` must therefore eagerly rescan any
/// directory whose children were already loaded.
@MainActor
final class FileTreeManagerTests: XCTestCase {

    var tempDir: URL!
    var fileService: FileService!
    var manager: FileTreeManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTreeManagerTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manager = FileTreeManager(fileService: fileService)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        manager = nil
        fileService = nil
        tempDir = nil
        super.tearDown()
    }

    @discardableResult
    private func createFile(_ name: String, in dir: URL, content: String = "") -> URL {
        let url = dir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func createDir(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Wait for a `Task.detached`-based async reload to finish and observe
    /// the tree via a polling loop (reload has no completion callback).
    private func waitUntil(_ timeout: TimeInterval = 2.0, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_reload_refreshesAlreadyExpandedSubdirectory_withNewFile() {
        let subDir = createDir("sub", in: tempDir)
        createFile("existing.md", in: subDir)

        // Simulate opening the folder and expanding "sub" in the sidebar.
        manager.reloadFresh(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 1 }

        guard let subItem = manager.fileTree.first else {
            return XCTFail("expected sub directory in tree")
        }
        manager.loadChildrenIfNeeded(for: subItem)
        waitUntil { subItem.childrenLoaded }
        XCTAssertEqual(subItem.children?.count, 1, "sub should have exactly 'existing.md' before the external change")

        // External change: a new file appears inside the already-expanded "sub" directory.
        createFile("new.md", in: subDir)

        // FSEvents-triggered reload (what scheduleWatchedReload ultimately calls).
        manager.reload(rootURL: tempDir)
        waitUntil { (subItem.children?.count ?? 0) == 2 }

        let names = Set((subItem.children ?? []).map { $0.name })
        XCTAssertEqual(names, ["existing.md", "new.md"],
                        "reload() must rescan already-expanded directories, not just mark them stale")
        XCTAssertTrue(subItem.childrenLoaded, "expanded directory should remain marked as loaded after reload")
    }

    func test_reload_doesNotEagerlyLoadNeverExpandedSubdirectory() {
        let subDir = createDir("sub", in: tempDir)
        createFile("existing.md", in: subDir)

        manager.reloadFresh(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 1 }

        guard let subItem = manager.fileTree.first else {
            return XCTFail("expected sub directory in tree")
        }
        // Never expanded — childrenLoaded should be false, children nil.
        XCTAssertFalse(subItem.childrenLoaded)

        createFile("new.md", in: subDir)
        manager.reload(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 1 }

        // Same FileItem instance should be reused (identity preserved so
        // SwiftUI doesn't collapse the DisclosureGroup), and still lazy.
        XCTAssertTrue(manager.fileTree.first === subItem)
        XCTAssertFalse(subItem.childrenLoaded, "never-expanded directories should stay lazy — no eager disk scan")
    }

    func test_reload_refreshesNestedGrandchildDirectory() {
        let subDir = createDir("sub", in: tempDir)
        let nestedDir = createDir("nested", in: subDir)
        createFile("a.md", in: nestedDir)

        manager.reloadFresh(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 1 }
        let subItem = manager.fileTree[0]

        manager.loadChildrenIfNeeded(for: subItem)
        waitUntil { subItem.childrenLoaded }
        guard let nestedItem = subItem.children?.first(where: { $0.name == "nested" }) else {
            return XCTFail("expected nested directory")
        }
        manager.loadChildrenIfNeeded(for: nestedItem)
        waitUntil { nestedItem.childrenLoaded }
        XCTAssertEqual(nestedItem.children?.count, 1)

        // External change two levels deep, inside two already-expanded directories.
        createFile("b.md", in: nestedDir)
        manager.reload(rootURL: tempDir)
        waitUntil { (nestedItem.children?.count ?? 0) == 2 }

        let names = Set((nestedItem.children ?? []).map { $0.name })
        XCTAssertEqual(names, ["a.md", "b.md"])
    }

    func test_reload_addsNewTopLevelFile() {
        createFile("first.md", in: tempDir)
        manager.reloadFresh(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 1 }

        createFile("second.md", in: tempDir)
        manager.reload(rootURL: tempDir)
        waitUntil { self.manager.fileTree.count == 2 }

        XCTAssertEqual(Set(manager.fileTree.map { $0.name }), ["first.md", "second.md"])
    }

    func test_rebuildIndex_usesSingleDirectoryEnumeration() {
        // 索引同时要「可搜索文件」与「@mention 全量项（含目录）」，
        // 两份数据的筛选谓词相同，因此必须一次枚举产出。
        // 早先分两次调用 loadAllFiles / loadAllItems，等于把整棵目录树扫两遍
        // （4,650 项实测 174.5ms → 合并后 89ms）。
        let mock = MockFileService()
        let doc = FileItem(url: tempDir.appendingPathComponent("a.md"), isDirectory: false)
        let dir = FileItem(url: tempDir.appendingPathComponent("sub"), isDirectory: true)
        mock.setChildren([dir, doc], for: tempDir)

        let manager = FileTreeManager(fileService: mock)
        manager.reloadFresh(rootURL: tempDir)
        waitUntil { !manager.indexedFiles.isEmpty }

        XCTAssertEqual(Set(manager.indexedFiles.map(\.name)), ["a.md"])
        XCTAssertEqual(Set(manager.mentionItems.map(\.name)), ["a.md", "sub"])
        XCTAssertEqual(mock.separateScanCallCount, 0, "建索引不该再调单列表方法（那会二次枚举目录树）")
        XCTAssertGreaterThanOrEqual(mock.combinedScanCallCount, 1)
    }
}
