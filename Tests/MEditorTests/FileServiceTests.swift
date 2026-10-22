import XCTest
@testable import MEditor

final class FileServiceTests: XCTestCase {

    var tempDir: URL!
    var service: FileService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = FileService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        service = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func createFile(_ name: String, content: String = "") -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func createDir(_ name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - loadImmediateChildren

    func test_loadImmediateChildren_returnsFilesAndDirs() {
        createFile("readme.md")
        createFile("index.html")
        createDir("images")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("readme.md"))
        XCTAssertTrue(names.contains("index.html"))
        XCTAssertTrue(names.contains("images"))
    }

    func test_loadImmediateChildren_filtersUnsupportedExtensions() {
        createFile("doc.md")
        createFile("script.js")
        createFile("style.css")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("doc.md"))
        XCTAssertFalse(names.contains("script.js"))
        XCTAssertFalse(names.contains("style.css"))
    }

    func test_loadImmediateChildren_directoriesAlwaysAppear() {
        // 普通目录（即使没有可识别扩展名）始终出现在文件树
        createDir("assets")
        createFile("readme.md")

        let items = service.loadImmediateChildren(of: tempDir)
        let dirNames = items.filter(\.isDirectory).map(\.name)
        XCTAssertTrue(dirNames.contains("assets"))
    }

    func test_loadImmediateChildren_skipsIgnoredNames() {
        // hiddenNames 名单内的项被过滤（精确名单，而非所有点文件）
        createFile(".DS_Store")
        createDir("node_modules")
        createFile("visible.md")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = items.map(\.name)
        XCTAssertFalse(names.contains(".DS_Store"))
        XCTAssertFalse(names.contains("node_modules"))
        XCTAssertTrue(names.contains("visible.md"))
    }

    func test_loadImmediateChildren_keepsDotNamesNotInIgnoreList() {
        // 不在名单中的点目录/文件仍会出现（如 .vscode、.hidden.md）——这是当前实现的预期行为
        createDir(".vscode")
        createFile(".hidden.md")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = items.map(\.name)
        XCTAssertTrue(names.contains(".vscode"))
        XCTAssertTrue(names.contains(".hidden.md"))
    }

    func test_loadImmediateChildren_emptyDir() {
        let items = service.loadImmediateChildren(of: tempDir)
        XCTAssertTrue(items.isEmpty)
    }

    func test_loadImmediateChildren_skipsICloudPlaceholders() {
        // iCloud Drive 占位符（.xxx.icloud）不应出现在文件树
        createFile(".note.md.icloud")
        createFile(".archive.zip.icloud")
        createFile("note.md")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = items.map(\.name)
        XCTAssertFalse(names.contains(".note.md.icloud"))
        XCTAssertFalse(names.contains(".archive.zip.icloud"))
        XCTAssertTrue(names.contains("note.md"))
    }

    // MARK: - Sort order

    func test_loadImmediateChildren_directoriesFirst() {
        createDir("zassets")
        createFile("aaa.md")

        let items = service.loadImmediateChildren(of: tempDir)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isDirectory)  // dirs first
        XCTAssertFalse(items[1].isDirectory)
    }

    func test_loadImmediateChildren_alphabeticalWithinTypes() {
        createFile("zebra.md")
        createFile("alpha.md")
        createDir("beta")
        createDir("aaa")

        let items = service.loadImmediateChildren(of: tempDir)

        // dirs first: aaa, beta
        let dirs = items.filter(\.isDirectory)
        XCTAssertEqual(dirs[0].name, "aaa")
        XCTAssertEqual(dirs[1].name, "beta")

        // files after: alpha, zebra
        let files = items.filter { !$0.isDirectory }
        XCTAssertEqual(files[0].name, "alpha.md")
        XCTAssertEqual(files[1].name, "zebra.md")
    }

    func test_loadImmediateChildren_caseInsensitiveSort() {
        createFile("Zebra.md")
        createFile("alpha.md")

        let items = service.loadImmediateChildren(of: tempDir)
        let names = items.map(\.name)
        XCTAssertEqual(names[0], "alpha.md")
        XCTAssertEqual(names[1], "Zebra.md")
    }

    // MARK: - loadChildren

    func test_loadChildren_setsChildrenOnItem() {
        createDir("sub")
        createFile("sub/a.md")
        createFile("sub/b.html")

        let parent = FileItem(url: tempDir.appendingPathComponent("sub"), isDirectory: true)
        let children = service.loadChildren(for: parent)

        XCTAssertNotNil(parent.children)
        XCTAssertEqual(children.count, 2)
        let names = children.map(\.name)
        XCTAssertTrue(names.contains("a.md"))
        XCTAssertTrue(names.contains("b.html"))
    }

    // MARK: - readFile / writeFile

    func test_readFile_success() throws {
        let url = createFile("hello.md", content: "# Hello")
        let content = try service.readFile(at: url)
        XCTAssertEqual(content, "# Hello")
    }

    func test_readFile_utf16Fallback() throws {
        let url = tempDir.appendingPathComponent("utf16.md")
        let data = "你好，MEditor".data(using: .utf16)
        try XCTUnwrap(data).write(to: url)

        let content = try service.readFile(at: url)

        XCTAssertEqual(content, "你好，MEditor")
    }

    func test_readFile_nonexistent_throws() {
        let url = tempDir.appendingPathComponent("nope.md")
        XCTAssertThrowsError(try service.readFile(at: url))
    }

    func test_writeFile_createsFile() throws {
        let url = tempDir.appendingPathComponent("output.md")
        try service.writeFile(at: url, content: "# Written")
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "# Written")
    }

    func test_writeFile_overwrites() throws {
        let url = createFile("overwrite.md", content: "# Old")
        try service.writeFile(at: url, content: "# New")
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "# New")
    }

    // MARK: - createFile（新建不允许覆盖）

    func test_createFile_createsNewFile() throws {
        let url = tempDir.appendingPathComponent("new.md")
        try service.createFile(at: url, content: "# Fresh")
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "# Fresh")
    }

    func test_createFile_existingFile_throwsAndPreservesContent() throws {
        // 新建文件的目标已存在时：必须抛错且原内容不被截断（数据丢失防护）
        let url = createFile("existing.md", content: "# Precious")

        XCTAssertThrowsError(try service.createFile(at: url, content: "")) { error in
            guard case FileServiceError.alreadyExists(let existingURL) = error else {
                return XCTFail("应抛出 FileServiceError.alreadyExists，实际为 \(error)")
            }
            XCTAssertEqual(existingURL, url)
        }

        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "# Precious", "已存在文件的内容不得被覆盖")
    }

    func test_loadImmediateChildren_nonexistentDir_returnsEmpty() {
        let badURL = URL(fileURLWithPath: "/nonexistent_path_xyz")
        let items = service.loadImmediateChildren(of: badURL)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - loadAllItems (@mention 全量索引)
    // 验证：mention 索引是文件系统全量递归扫描，与 UI 文件树是否展开无关。

    func test_loadAllItems_findsDeeplyNestedFileWithoutExpansion() {
        // 构造深层目录：a/b/c/deep.md —— 从未通过 loadChildren 展开过
        createDir("a")
        createDir("a/b")
        createDir("a/b/c")
        createFile("a/b/c/deep.md", content: "# deep")

        let items = service.loadAllItems(under: tempDir)
        let names = Set(items.map(\.name))

        // 深层文件和沿途所有目录都应被索引到
        XCTAssertTrue(names.contains("deep.md"), "深层文件应被全量扫描索引")
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
        XCTAssertTrue(names.contains("c"))
    }

    func test_loadAllItems_includesDirectoriesAndFiles() {
        createDir("systems")
        createDir("systems/arms")
        createFile("systems/arms/index.html")
        createFile("readme.md")

        let items = service.loadAllItems(under: tempDir)
        let dirs = Set(items.filter(\.isDirectory).map(\.name))
        let files = Set(items.filter { !$0.isDirectory }.map(\.name))

        XCTAssertTrue(dirs.contains("systems"))
        XCTAssertTrue(dirs.contains("arms"))
        XCTAssertTrue(files.contains("index.html"))
        XCTAssertTrue(files.contains("readme.md"))
    }

    func test_loadAllItems_skipsHiddenAndIgnoredTrees() {
        createDir("node_modules")
        createFile("node_modules/pkg.md")     // 应被整树跳过
        createDir(".git")
        createFile(".git/config.md")          // 应被整树跳过
        createFile("keep.md")

        let items = service.loadAllItems(under: tempDir)
        let names = Set(items.map(\.name))

        XCTAssertTrue(names.contains("keep.md"))
        XCTAssertFalse(names.contains("pkg.md"), "node_modules 子树应被跳过")
        XCTAssertFalse(names.contains("config.md"), ".git 子树应被跳过")
    }

    func test_loadAllItems_skipsICloudPlaceholders() {
        // 递归索引同样跳过 iCloud 占位符（包括子目录内的）
        createFile(".note.md.icloud")
        createDir("sub")
        createFile("sub/.deep.md.icloud")
        createFile("sub/deep.md")

        let items = service.loadAllItems(under: tempDir)
        let names = Set(items.map(\.name))
        XCTAssertFalse(names.contains(".note.md.icloud"))
        XCTAssertFalse(names.contains(".deep.md.icloud"))
        XCTAssertTrue(names.contains("deep.md"))

        let files = service.loadAllFiles(under: tempDir)
        let fileNames = Set(files.map(\.name))
        XCTAssertFalse(fileNames.contains(".note.md.icloud"))
        XCTAssertFalse(fileNames.contains(".deep.md.icloud"))
        XCTAssertTrue(fileNames.contains("deep.md"))
    }

    func test_loadAllItems_newlyAddedFileFoundOnRescan() {
        // 模拟外部新增文件后重新建索引（FSEvents → reload → 下次 @ ensureIndexReady 重建）
        createFile("first.md")
        var items = service.loadAllItems(under: tempDir)
        XCTAssertFalse(Set(items.map(\.name)).contains("later.md"))

        // 外部新增一个深层文件
        createDir("newdir")
        createFile("newdir/later.md")

        // 重新扫描即可发现（rebuildIndex 做的就是这件事）
        items = service.loadAllItems(under: tempDir)
        XCTAssertTrue(Set(items.map(\.name)).contains("later.md"), "重建索引后应能搜到新增文件")
    }

    // MARK: - loadAll（一次枚举同时产出两份列表）
    // 建索引要的是「可搜索文件」+「@mention 全量项」，谓词相同 ⇒ 必须一次枚举。
    // 这里钉住合并实现的语义：与两个单列表方法完全等价，顺序也一致。

    func test_loadAll_producesBothListsWithSeparateScanSemantics() {
        createDir("dir1")
        createDir("dir1/sub")
        createFile("readme.md")
        createFile("page.html")
        createFile("skip.xyz")                 // 非支持扩展名：两份列表都不该有
        createFile("dir1/a.md")
        createFile("dir1/sub/b.html")
        createDir("node_modules")
        createFile("node_modules/pkg.md")      // 整树跳过
        createFile("dir1/.draft.md.icloud")    // iCloud 占位符跳过

        let combined = service.loadAll(under: tempDir)

        // 临时目录在 /var → /private/var 的符号链接下，两侧都先解链再取相对路径
        let base = tempDir.resolvingSymlinksInPath().path + "/"
        func rel(_ items: [FileItem]) -> [String] {
            items.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        }

        // 目录在前、同名按 localizedStandardCompare：dir1 → sub → a.md → b.html → page.html → readme.md
        XCTAssertEqual(rel(combined.items), ["dir1", "dir1/sub", "dir1/a.md", "dir1/sub/b.html", "page.html", "readme.md"])
        XCTAssertEqual(rel(combined.files), ["dir1/a.md", "dir1/sub/b.html", "page.html", "readme.md"])
    }

    func test_loadAll_filesAreSubsetOfItemsAndNeverDirectories() {
        createDir("d")
        createDir("d/e")
        createFile("d/e/f.md")
        createFile("top.md")

        let combined = service.loadAll(under: tempDir)

        XCTAssertTrue(combined.files.allSatisfy { !$0.isDirectory }, "files 里不该出现目录")
        XCTAssertTrue(combined.items.contains { $0.isDirectory }, "items 必须含目录，否则 @mention 搜不到文件夹")
        let itemURLs = Set(combined.items.map(\.url))
        XCTAssertTrue(combined.files.allSatisfy { itemURLs.contains($0.url) }, "files 应是 items 的子集")
    }

    func test_loadAll_itemsAndFilesDoNotShareInstances() {
        // 两个列表的 FileItem 各自独立：mention 侧的可变字段（children 等）
        // 不该串到索引侧，反之亦然。
        createFile("x.md")

        let combined = service.loadAll(under: tempDir)
        guard let file = combined.files.first else { return XCTFail("expected one file") }
        guard let item = combined.items.first(where: { $0.url == file.url }) else {
            return XCTFail("expected matching item")
        }
        XCTAssertFalse(file === item, "同一路径在两份列表里应是不同实例")
    }

    /// 排序必须**预取** name，不能在比较器里逐次现算。
    ///
    /// `FileItem.name` 是 `url.lastPathComponent` 计算属性，比较器里直接取等于每次比较
    /// 现算两次：500 项 ≈ 4,500 次比较 ⇒ 9,000 次取值（实测排序 91.7ms vs 13.4ms）。
    /// 这条守的是「性能主张」本身——只断言排序结果正确的用例，把预取删掉照样全绿。
    func test_loadAll_sortDoesNotRecomputeNamePerComparison() {
        var names: [String] = []
        for i in 0..<120 {
            names.append(String(format: "note%03d.md", i))
        }
        createDir("bulk")
        for name in names { createFile("bulk/\(name)") }

        FileItem.nameAccessCount = 0
        let combined = service.loadAll(under: tempDir)
        let accesses = FileItem.nameAccessCount

        XCTAssertEqual(combined.files.count, names.count)
        // 预取实现：每个 item 取一次（两份列表各一份实例 ⇒ ≤ 2N）。
        // 逐次现取：n·log n·2 ≈ 1,700 次。阈值取 3N = 360 留足余量。
        XCTAssertLessThan(
            accesses, names.count * 3,
            "排序里仍在逐次取 name（\(accesses) 次 / \(names.count) 项）—— 预取被去掉了"
        )
    }
}
