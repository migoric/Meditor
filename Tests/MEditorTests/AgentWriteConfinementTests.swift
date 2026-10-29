import XCTest
@testable import MEditor

// MARK: - Mock adapter

/// 内存态 AgentDocumentAdapter，仅支撑 confinement 测试。
@MainActor
private final class ConfinementMockAdapter: AgentDocumentAdapter {
    var currentDocument: String?     = nil
    var currentDocumentName: String? = nil
    var workspaceURL: URL?
    var currentTabURL: URL?          = nil

    /// 模拟"已打开的 Tab"集合（标准化路径）
    var openTabPaths: Set<String> = []

    func writeDocument(_ content: String) throws {}
    func patchDocument(find: String, replace: String, all: Bool) throws -> Int { 0 }
    func insertIntoDocument(_ text: String) {}
    func contentForTab(at url: URL) -> String? { nil }
    func openFile(at url: URL) -> Bool { true }
    func hasOpenTab(at url: URL) -> Bool {
        openTabPaths.contains(url.standardizedFileURL.path)
    }

    func notifyFileCreated(_ url: URL) {}
    func notifyFileWritten(_ url: URL, content: String, isNew: Bool) {}
    func notifyDirectoryCreated(_ url: URL) {}

    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool { true }
}

// MARK: - Tests

/// Agent 文件写入的工作区 confinement：
/// 防止 write_file / create_file / create_directory / patch_file 被诱导写工作区外路径。
@MainActor
final class AgentWriteConfinementTests: XCTestCase {

    private var rootURL: URL!
    private var outsideURL: URL!
    private var ctx: AgentContext!
    private var adapter: ConfinementMockAdapter!

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-confinement-\(UUID().uuidString)")
        rootURL = base.appendingPathComponent("workspace")
        outsideURL = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

        let root = rootURL!
        let repo = DefaultAgentFileRepository { root }
        adapter = ConfinementMockAdapter()
        adapter.workspaceURL = root
        ctx = AgentContext(files: repo, doc: adapter)
    }

    override func tearDown() async throws {
        if let base = rootURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
        try await super.tearDown()
    }

    // MARK: 允许的路径

    func testWriteFileInsideWorkspaceAllowed() throws {
        let url = try ctx.writeFile(name: "notes.md", content: "hello")
        XCTAssertTrue(url.path.hasPrefix(rootURL.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
    }

    func testWriteFileNestedRelativePathAllowed() throws {
        let url = try ctx.writeFile(name: "docs/intro.md", content: "nested")
        XCTAssertTrue(url.path.hasPrefix(rootURL.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "nested")
    }

    func testWriteFileOutsideWorkspaceAllowedWhenTabOpen() throws {
        let loose = outsideURL.appendingPathComponent("loose.md")
        adapter.openTabPaths.insert(loose.standardizedFileURL.path)
        let url = try ctx.writeFile(name: loose.path, content: "loose content")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "loose content")
    }

    // MARK: 拒绝的路径

    func testWriteFileAbsolutePathOutsideWorkspaceRejected() {
        let target = outsideURL.appendingPathComponent("evil.md")
        XCTAssertThrowsError(try ctx.writeFile(name: target.path, content: "x")) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testWriteFileTraversalOutsideWorkspaceRejected() {
        let target = outsideURL.appendingPathComponent("escape.md")
        XCTAssertThrowsError(try ctx.writeFile(name: "../outside/escape.md", content: "x")) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCreateFileOutsideWorkspaceRejected() {
        let target = outsideURL.appendingPathComponent("new.md")
        XCTAssertThrowsError(try ctx.createFile(name: target.path, content: "x")) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    func testCreateDirectoryOutsideWorkspaceRejected() {
        XCTAssertThrowsError(try ctx.createDirectory(name: outsideURL.appendingPathComponent("dir").path)) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    func testPatchFileOutsideWorkspaceRejected() async throws {
        let target = outsideURL.appendingPathComponent("patchme.md")
        try "original text".write(to: target, atomically: true, encoding: .utf8)
        await XCTAssertThrowsErrorAsync(try await ctx.patchFile(name: target.path, find: "original", replace: "hacked", all: false)) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
        // 文件内容未被修改
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original text")
    }

    func testShellConfigWriteRejected() {
        // 典型提示注入目标：~/.zshrc（一定在工作区外）
        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        XCTAssertThrowsError(try ctx.writeFile(name: zshrc.path, content: "evil")) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    // MARK: symlink 逃逸

    func testWriteFileSymlinkEscapeRejected() throws {
        // 工作区内的 symlink → 工作区外目录：standardizedFileURL 不解析 symlink，
        // 修复前能把写目标引到工作区外（如指向 ~ 的 symlink）。
        let link = rootURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideURL)
        let target = outsideURL.appendingPathComponent("escape.md")

        XCTAssertThrowsError(try ctx.writeFile(name: "link/escape.md", content: "evil")) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "经 symlink 逃逸的写入不应落盘")
    }

    func testWriteFileSymlinkInsideWorkspaceAllowed() throws {
        // 对照：symlink 指向工作区内部目录时仍允许
        let inner = rootURL.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let link = rootURL.appendingPathComponent("inner-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)

        let url = try ctx.writeFile(name: "inner-link/ok.md", content: "fine")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.appendingPathComponent("ok.md").path))
    }

    // MARK: 读取 confinement（与写入对称）

    func testReadFileInsideWorkspaceAllowed() async throws {
        let url = rootURL.appendingPathComponent("readable.md")
        try "inside".write(to: url, atomically: true, encoding: .utf8)
        let content = try await ctx.readFile(at: url)
        XCTAssertEqual(content, "inside")
    }

    func testReadFileOutsideWorkspaceRejected() async throws {
        let secret = outsideURL.appendingPathComponent("secret.txt")
        try "TOP SECRET".write(to: secret, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await ctx.readFile(at: secret)) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    func testReadFileOutsideWorkspaceAllowedWhenTabOpen() async throws {
        let loose = outsideURL.appendingPathComponent("loose-read.md")
        try "loose".write(to: loose, atomically: true, encoding: .utf8)
        adapter.openTabPaths.insert(loose.standardizedFileURL.path)

        let content = try await ctx.readFile(at: loose)
        XCTAssertEqual(content, "loose")
    }

    func testFileContentFullOutsideWorkspaceRejected() async throws {
        let secret = outsideURL.appendingPathComponent("secret-full.txt")
        try "SECRET".write(to: secret, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await ctx.fileContentFull(at: secret)) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    func testReadFileSymlinkEscapeRejected() async throws {
        // 工作区内 symlink → 工作区外的密钥文件：standardizedFileURL 不解析 symlink，
        // 修复前 read_file 可经 symlink 读取工作区外内容。
        let secret = outsideURL.appendingPathComponent("id_rsa")
        try "PRIVATE KEY".write(to: secret, atomically: true, encoding: .utf8)
        let link = rootURL.appendingPathComponent("id_rsa_link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        await XCTAssertThrowsErrorAsync(try await ctx.readFile(at: link)) { error in
            guard case AgentContextError.pathOutsideWorkspace = error else {
                return XCTFail("期望 pathOutsideWorkspace，实际 \(error)")
            }
        }
    }

    func testOpenFileOutsideWorkspaceRejected() throws {
        // open_file 若不受约束，可先把工作区外文件变成已打开 tab，再绕过读取 confinement。
        let secret = outsideURL.appendingPathComponent("open-secret.md")
        try "x".write(to: secret, atomically: true, encoding: .utf8)

        XCTAssertFalse(ctx.openFile(named: secret.path), "工作区外的 open_file 必须被拒绝")
        XCTAssertTrue(adapter.openTabPaths.isEmpty)
    }

    func testDocumentAdapter_defaultWriteConfirmation_isFailClosed() async {
        let allowed = await adapter.confirmFileWrite("a.md", summary: "write")
        XCTAssertFalse(allowed, "未显式接入确认的适配器必须默认拒绝写入")
    }
}

// MARK: - async 断言辅助

/// @MainActor：调用方是 @MainActor 测试类，闭包参数（autoclosure/errorHandler）
/// 需留在主 actor，避免 Swift 6 把捕获了主 actor 状态的闭包判为 sending 而报错。
@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("期望抛出错误但没有抛出。\(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
