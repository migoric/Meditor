import XCTest
@testable import MEditor

/// 主交互路径的压测：文件树枚举 / 文件打开 / tab 切换（预览渲染的分相在
/// `PreviewRenderBenchTests`，这边管 Swift 侧的三条）。
///
/// 压测不是断言：只在 `MEDITOR_BENCH=1` 时跑，结果以 `BENCH|…` 行 print 出来
/// 人工读，不进 CI（wall time 在 runner 上不稳定）。
///
///     MEDITOR_BENCH=1 ./scripts/test.sh --filter AppBenchTests
@MainActor
final class AppBenchTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEDITOR_BENCH"] == "1",
            "压测用例：MEDITOR_BENCH=1 时才跑"
        )
    }

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        try await super.tearDown()
    }

    // MARK: - 夹具

    /// 造一个含 count 个 .md 的合成工作区（两层目录打散，避免单目录项数失真）。
    private func makeWorkspace(fileCount: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppBench-\(UUID().uuidString)", isDirectory: true)
        let body = "# 标题\n\n正文一段。\n\n- 列表项\n"
        for i in 0..<fileCount {
            let sub = dir.appendingPathComponent("d\(i % 100)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try body.write(to: sub.appendingPathComponent("doc-\(i).md"), atomically: true, encoding: .utf8)
        }
        tempDirs.append(dir)
        return dir
    }

    private func makeFile(named name: String, bytes: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunk = "# 章节\n\n正文段落，含 **加粗** 与 `代码`。\n\n"
        var text = ""
        while text.utf8.count < bytes { text += chunk }
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        tempDirs.append(dir)
        return url
    }

    private func median(_ samples: [Double]) -> Double {
        let s = samples.sorted()
        return s[s.count / 2]
    }

    @discardableResult
    private func timeIt(_ label: String, rounds: Int = 7, _ body: () throws -> Void) rethrows -> Double {
        try? body()   // 热身
        var samples: [Double] = []
        for _ in 0..<rounds {
            let t0 = Date()
            try? body()
            samples.append(Date().timeIntervalSince(t0) * 1000)
        }
        let med = median(samples)
        print("BENCH|\(label)|\(String(format: "%.2f", med))ms")
        return med
    }

    // MARK: - 文件树

    /// 左侧文件树的数据源成本：整棵工作区枚举（loadAll 一次走完）。
    func testTreeEnumerate() async throws {
        for count in [1_000, 5_000, 20_000] {
            let dir = try makeWorkspace(fileCount: count)
            let service = FileService()
            var resultCount = 0
            timeIt("tree/enumerate-\(count)个文件") {
                resultCount = service.loadAll(under: dir).files.count
            }
            XCTAssertEqual(resultCount, count)
        }
    }

    /// 树展开路径的真实成本在单目录枚举（loadImmediateChildren）；
    /// FileTreeManager 的 Task.detached 包装只是异步调度，本身没有可测的量。
    func testTreeExpandDirectory() async throws {
        for count in [100, 1_000] {
            let dir = try makeWorkspace(fileCount: count)
            let service = FileService()
            var loaded = 0
            // 根目录：100 个子目录项
            timeIt("tree/loadImmediateChildren-根(\(count)文件)") {
                loaded = service.loadImmediateChildren(of: dir).count
            }
            XCTAssertEqual(loaded, 100)
            // 子目录：每目录 count/100 个文件项
            let sub = dir.appendingPathComponent("d0", isDirectory: true)
            timeIt("tree/loadImmediateChildren-子目录(\(count / 100)文件)") {
                loaded = service.loadImmediateChildren(of: sub).count
            }
            XCTAssertEqual(loaded, count / 100)
        }
    }

    // MARK: - 文件打开

    /// 打开文件：同步读阈值（512KB）上下两条路径 + 纯读盘解码成本。
    func testFileOpen() async throws {
        let specs: [(String, Int)] = [
            ("10KB", 10 * 1024),
            ("511KB-同步读上限内", 511 * 1024),
            ("1MB-异步", 1 * 1024 * 1024),
            ("15MB-异步贴近上限", 15 * 1024 * 1024),
        ]
        for (label, bytes) in specs {
            let url = try makeFile(named: "doc-\(bytes).md", bytes: bytes)
            let fileService = FileService()
            let tabs = TabManager(fileService: fileService)
            // 纯 I/O + 解码（openFile 异步路径真正付的账）
            timeIt("open/readFile-\(label)") { _ = try? fileService.readFile(at: url) }
            // openFile 调用本身（含上限判定 + tab 入列；>512KB 的内容加载在后台）
            timeIt("open/openFile-\(label)") {
                let tabs2 = TabManager(fileService: fileService)
                _ = tabs2.openFile(FileItem(url: url, isDirectory: false))
            }
            _ = tabs
        }
    }

    // MARK: - Tab 切换

    /// tab 切换本身的状态成本（含 onSyncPreview 回调开销），20 个已开 tab 轮转。
    /// 切 tab 的预览重渲染成本在 PreviewRenderBenchTests 的 renderInto 列。
    func testTabSwitch() async throws {
        let dir = try makeWorkspace(fileCount: 20)
        let fileService = FileService()
        let tabs = TabManager(fileService: fileService)
        let files = fileService.loadAll(under: dir).files
        XCTAssertEqual(files.count, 20)
        for file in files { _ = tabs.openFile(file) }
        XCTAssertEqual(tabs.openTabs.count, 20)

        var syncs = 0
        tabs.onSyncPreview = { _ in syncs += 1 }
        let ids = tabs.openTabs.map(\.id)
        timeIt("tab/selectTab-20个tab轮转", rounds: 50) {
            for id in ids { tabs.selectTab(id) }
        }
        XCTAssertGreaterThan(syncs, 0, "onSyncPreview 必须真的被触发，否则基准没接上")
    }
}
