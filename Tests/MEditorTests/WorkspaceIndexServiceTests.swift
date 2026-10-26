import XCTest
@testable import MEditor

/// WorkspaceIndexService 测试：临时目录 + UUID 隔离（与 AgentFileRepositoryTests 同约定）。
/// 覆盖：全量构建、中英文/大小写/多词短语搜索、扩展名过滤、文件名匹配、
/// 增量更新（单文件 upsert / FSEvents diff 刷新）、删除、大文件与二进制跳过、
/// 以及 Agent search_workspace 走索引路径的格式兼容。
final class WorkspaceIndexServiceTests: XCTestCase {

    var tempDir: URL!
    var index: WorkspaceIndexService!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorIndexTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 枚举器返回 realpath 形式的 URL（/var → /private/var）；统一基准便于路径断言
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(base.path, &buf)
        tempDir = URL(fileURLWithPath: String(cString: buf))
        index = WorkspaceIndexService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        index = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func createFile(_ name: String, content: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func build() async {
        await index.buildIndex(root: tempDir)
    }

    // MARK: - 构建与基础搜索

    func testBuild_indexesFilesAndMarksReady() async {
        XCTAssertFalse(index.isReady, "构建前应未就绪")
        createFile("a.md", content: "hello world")
        createFile("sub/b.md", content: "nested note")
        await build()
        XCTAssertTrue(index.isReady, "构建完成应就绪")
        let count = await index.indexedFileCount
        XCTAssertEqual(count, 2)
    }

    func testSearch_englishCaseInsensitive() async {
        createFile("notes.md", content: "Hello World\nsecond line")
        await build()
        let results = await index.search(query: "hello world")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.relativePath, "notes.md")
        XCTAssertEqual(results.first?.lineNumber, 1)
        XCTAssertEqual(results.first?.line, "Hello World")
    }

    func testSearch_chineseContent() async {
        createFile("日记.md", content: "今天天气不错\n明天再说")
        await build()
        let results = await index.search(query: "天气")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.relativePath, "日记.md")
        XCTAssertEqual(results.first?.lineNumber, 1)
    }

    func testSearch_multiWordPhrase_matchesWholeSubstring() async {
        // 短语语义与 grep -i 一致：整体子串匹配，而非分词 AND
        createFile("a.md", content: "the quick brown fox\nquick only here")
        await build()
        let phrase = await index.search(query: "quick brown")
        XCTAssertEqual(phrase.count, 1, "整段短语应只命中包含完整子串的行")
        XCTAssertEqual(phrase.first?.lineNumber, 1)
    }

    func testSearch_multipleMatchesPerFileCapped() async {
        let lines = (1...10).map { "match line \($0)" }.joined(separator: "\n")
        createFile("many.md", content: lines)
        await build()
        let results = await index.search(query: "match line")
        XCTAssertEqual(results.count, 5, "单文件命中应封顶 maxPerFile=5")
        XCTAssertEqual(results.map(\.lineNumber), [1, 2, 3, 4, 5])
    }

    func testSearch_extensionFilter() async {
        createFile("a.md", content: "keyword")
        createFile("b.txt", content: "keyword")
        createFile("c.json", content: "keyword")
        await build()
        let mdOnly = await index.search(query: "keyword", extensions: ["md"])
        XCTAssertEqual(mdOnly.map(\.relativePath), ["a.md"])
        let all = await index.search(query: "keyword")
        XCTAssertEqual(all.count, 3, "空扩展名过滤应搜全部已索引文本文件")
    }

    func testSearch_fileNameMatch_uiOnly() async {
        createFile("meeting-notes.md", content: "no hit in body")
        await build()
        let withNames = await index.search(query: "meeting", includeFileNames: true)
        XCTAssertEqual(withNames.count, 1)
        XCTAssertEqual(withNames.first?.lineNumber, 0, "文件名匹配行号应为 0")
        let withoutNames = await index.search(query: "meeting", includeFileNames: false)
        XCTAssertTrue(withoutNames.isEmpty, "Agent 路径不产出文件名匹配")
    }

    func testSearch_emptyQuery_returnsEmpty() async {
        createFile("a.md", content: "hello")
        await build()
        let results = await index.search(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 增量更新

    func testUpdateFile_newFileBecomesSearchable() async {
        createFile("a.md", content: "alpha")
        await build()
        let url = createFile("b.md", content: "bravo")
        await index.updateFile(at: url)
        let results = await index.search(query: "bravo")
        XCTAssertEqual(results.map(\.relativePath), ["b.md"])
    }

    func testUpdateFile_modifiedContentReflected() async {
        let url = createFile("a.md", content: "before edit")
        await build()
        try! "after edit".write(to: url, atomically: true, encoding: .utf8)
        await index.updateFile(at: url)
        let old = await index.search(query: "before edit")
        let new = await index.search(query: "after edit")
        XCTAssertTrue(old.isEmpty, "旧内容不应再命中")
        XCTAssertEqual(new.count, 1)
    }

    func testUpdateFile_deletedFileRemoved() async {
        let url = createFile("a.md", content: "ephemeral")
        await build()
        try! FileManager.default.removeItem(at: url)
        await index.updateFile(at: url)
        let results = await index.search(query: "ephemeral")
        XCTAssertTrue(results.isEmpty)
    }

    func testRemoveFile_dropsFromIndex() async {
        let url = createFile("a.md", content: "removable")
        await build()
        await index.removeFile(at: url)
        let results = await index.search(query: "removable")
        XCTAssertTrue(results.isEmpty)
    }

    func testScheduleRefresh_picksUpExternalChanges() async {
        createFile("a.md", content: "initial")
        await build()
        // 模拟外部变化：新建 + 删除（不经 updateFile，走 FSEvents diff 路径）
        createFile("b.md", content: "external addition")
        try! FileManager.default.removeItem(at: tempDir.appendingPathComponent("a.md"))
        await index.scheduleRefresh(root: tempDir)   // 内含 300ms 防抖
        let added = await index.search(query: "external addition")
        let removed = await index.search(query: "initial")
        XCTAssertEqual(added.map(\.relativePath), ["b.md"], "新文件应被 diff 刷新收编")
        XCTAssertTrue(removed.isEmpty, "已删除文件应被 diff 刷新移除")
    }

    // MARK: - 大文件 / 二进制跳过

    func testBuild_skipsOversizedFile() async {
        let big = String(repeating: "x", count: WorkspaceIndexService.maxIndexedFileBytes + 1)
        createFile("big.md", content: big)
        createFile("small.md", content: "needle")
        await build()
        let count = await index.indexedFileCount
        XCTAssertEqual(count, 1, "超上限文件不应入索引")
    }

    func testBuild_skipsBinaryFile() async {
        let binaryURL = tempDir.appendingPathComponent("image.png")
        try! Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x01]).write(to: binaryURL)
        createFile("ok.md", content: "needle")
        await build()
        let count = await index.indexedFileCount
        XCTAssertEqual(count, 1, "二进制文件（无法按文本解码）不应入索引")
    }

    func testBuild_skipsNoiseDirectories() async {
        createFile("node_modules/pkg/index.md", content: "needle")
        createFile("docs/real.md", content: "needle")
        await build()
        let results = await index.search(query: "needle")
        XCTAssertEqual(results.map(\.relativePath), ["docs/real.md"], "噪音目录应被跳过")
    }

    // MARK: - 搜索排序键序缓存（守卫：多次搜索不得重复全量排序）

    func testSearch_reusesSortedOrderAcrossQueries() async {
        createFile("b.md", content: "apple")
        createFile("a.md", content: "apple")
        await build()
        _ = await index.search(query: "apple")
        let afterFirst = await index.sortedOrderBuildCount
        _ = await index.search(query: "apple")
        _ = await index.search(query: "apple")
        let afterThird = await index.sortedOrderBuildCount
        XCTAssertEqual(afterFirst, 1, "首次搜索应重建一次排序键序")
        XCTAssertEqual(afterThird, 1, "索引未变时后续搜索必须复用缓存键序，不得重复全量排序")
    }

    func testSearch_invalidatesSortedOrderOnMutation() async {
        createFile("a.md", content: "apple")
        await build()
        _ = await index.search(query: "apple")
        createFile("b.md", content: "apple")
        await index.updateFile(at: tempDir.appendingPathComponent("b.md"))
        let results = await index.search(query: "apple")
        let builds = await index.sortedOrderBuildCount
        XCTAssertEqual(builds, 2, "索引增删后排序缓存必须失效并重建")
        XCTAssertEqual(results.map(\.relativePath), ["a.md", "b.md"], "重建后结果顺序仍按相对路径排序")
    }

    // MARK: - 生命周期

    func testClear_releasesIndex() async {
        createFile("a.md", content: "hello")
        await build()
        await index.clear()
        XCTAssertFalse(index.isReady)
        let results = await index.search(query: "hello")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Agent search_workspace 索引路径

    func testAgentSearch_usesIndexWhenReady() async {
        createFile("notes.md", content: "agent keyword here")
        await build()
        let root = tempDir!
        let service = index!
        let repo = DefaultAgentFileRepository({ root }, indexProvider: { service })
        let results = await repo.searchWorkspace(query: "agent keyword")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].hasPrefix("notes.md:1: "),
                      "索引路径输出格式应与 grep 路径一致（路径:行号: 内容），实际：\(results[0])")
        XCTAssertTrue(results[0].contains("agent keyword here"))
    }

    func testAgentSearch_fallsBackWhenIndexNotReady() async {
        createFile("notes.md", content: "fallback keyword")
        let root = tempDir!
        let service = index!   // 故意不 buildIndex：isReady == false
        let repo = DefaultAgentFileRepository({ root }, indexProvider: { service })
        let results = await repo.searchWorkspace(query: "fallback keyword")
        XCTAssertFalse(results.isEmpty, "索引未就绪时应回退磁盘搜索路径")
        XCTAssertTrue(results[0].contains("notes.md"))
    }

    func testAgentSearch_extensionDefaultFiltersToMarkdownFamily() async {
        createFile("a.md", content: "shared keyword")
        createFile("b.json", content: "shared keyword")
        await build()
        let root = tempDir!
        let service = index!
        let repo = DefaultAgentFileRepository({ root }, indexProvider: { service })
        // 默认扩展名 md/txt/markdown（与 SearchWorkspaceTool 的默认参数一致）
        let results = await repo.searchWorkspace(query: "shared keyword")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].hasPrefix("a.md:"))
    }

    // MARK: - 性能（构造千级文件工作区，打印实测值，断言放宽到数量级兜底）

    func testPerformance_thousandFileWorkspace() async throws {
        let fileCount = 1000
        for i in 0..<fileCount {
            let body = (0..<50).map { "文件 \(i) 第 \($0) 行 some english words mixed 中文混排" }
                .joined(separator: "\n")
            createFile("dir\(i % 20)/file\(i).md", content: body)
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        await build()
        let buildSeconds = CFAbsoluteTimeGetCurrent() - buildStart
        print("[Perf] 索引建立：\(fileCount) 文件耗时 \(String(format: "%.3f", buildSeconds))s")

        // 命中靠后的文件 + 无命中两种查询各测一次
        let hitStart = CFAbsoluteTimeGetCurrent()
        let hits = await index.search(query: "文件 999 第 49 行")
        let hitMs = (CFAbsoluteTimeGetCurrent() - hitStart) * 1000
        let missStart = CFAbsoluteTimeGetCurrent()
        _ = await index.search(query: "绝对不存在的词xyzzy")
        let missMs = (CFAbsoluteTimeGetCurrent() - missStart) * 1000
        print("[Perf] 搜索：命中 \(String(format: "%.1f", hitMs))ms / 未命中 \(String(format: "%.1f", missMs))ms")

        XCTAssertEqual(hits.count, 1)
        // 目标：建立 <1s 级、搜索 <50ms 级（release）。debug 测试放宽兜底，防回归失控：
        // 本地实测命中 ~215ms；共享 CI runner 波动更大（曾 506ms 刚过 500ms 线），
        // 阈值取 1000ms——仍能抓住 10 倍级回归，又不被 CI 机器噪声误杀。
        XCTAssertLessThan(buildSeconds, 10, "索引建立耗时应为 <1s 量级")
        XCTAssertLessThan(hitMs, 1000, "搜索耗时应为 <50ms 量级")
        XCTAssertLessThan(missMs, 1000)
    }
}
