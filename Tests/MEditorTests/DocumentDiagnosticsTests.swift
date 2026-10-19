import XCTest
@testable import MEditor

/// DocumentDiagnostics 规则引擎测试：临时目录 + UUID 隔离（与 WorkspaceIndexServiceTests 同约定）。
/// 覆盖：死链、缺图、重复标题、标题层级跳跃、围栏代码块跳过、
/// 外部链接/锚点/fragment/百分号编码、可选 title 与 <...> 包裹目标。
final class DocumentDiagnosticsTests: XCTestCase {

    var tempDir: URL!
    var fileURL: URL!   // 被检查的 Markdown 文件（tempDir 根下）

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorDiagnosticsTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 与 WorkspaceIndexServiceTests 一致：统一 realpath 基准，便于路径断言
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        realpath(base.path, &buf)
        tempDir = URL(fileURLWithPath: String(cString: buf))
        fileURL = tempDir.appendingPathComponent("doc.md")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        fileURL = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func createFile(_ name: String, content: String = "") -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 用真实磁盘检查跑单文件规则
    func run(_ content: String) -> [DocumentIssue] {
        DocumentDiagnostics.issues(in: content, fileURL: fileURL) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func kinds(_ issues: [DocumentIssue]) -> [DocumentIssue.Kind] { issues.map(\.kind) }

    // MARK: - 重复标题

    func testDuplicateHeading_flaggedOnSecondOccurrence() {
        let issues = run("# Intro\n\nsome text\n\n# Intro\n")
        XCTAssertEqual(kinds(issues), [.duplicateHeading("Intro")])
        XCTAssertEqual(issues.first?.line, 4, "重复标题应报在第二次出现的行（0-based）")
    }

    func testDuplicateHeading_differentTextNotFlagged() {
        XCTAssertTrue(run("# Intro\n## Intro2\n# Outro\n").isEmpty)
    }

    // MARK: - 标题层级跳跃

    func testHeadingLevelSkip_h1ToH3Flagged() {
        let issues = run("# Title\n\n### Sub\n")
        XCTAssertEqual(kinds(issues), [.headingLevelSkip(from: 1, to: 3)])
        XCTAssertEqual(issues.first?.line, 2)
    }

    func testHeadingLevelSkip_gradualNotFlagged() {
        XCTAssertTrue(run("# A\n## B\n### C\n## D\n").isEmpty, "逐级加深/回跳不算跳跃")
    }

    // MARK: - 围栏代码块

    func testCodeFence_headingsAndLinksInsideIgnored() {
        let content = """
        # Title

        ```
        # Title
        [x](missing.md)
        ![x](missing.png)
        ```

        ~~~
        ### Skip
        ~~~
        """
        XCTAssertTrue(run(content).isEmpty, "围栏内的标题/链接不应参与检查")
    }

    // MARK: - 死链

    func testDeadLink_missingFileFlagged() {
        let issues = run("see [notes](notes.md)\n")
        XCTAssertEqual(kinds(issues), [.deadLink("notes.md")])
    }

    func testDeadLink_existingFileNotFlagged() {
        createFile("notes.md", content: "hi")
        XCTAssertTrue(run("see [notes](notes.md)\n").isEmpty)
    }

    func testDeadLink_subdirectoryRelativePath() {
        createFile("sub/notes.md", content: "hi")
        XCTAssertTrue(run("[ok](sub/notes.md) [bad](sub/gone.md)\n").map(\.kind) == [.deadLink("sub/gone.md")])
    }

    func testDeadLink_externalAndAnchorLinksIgnored() {
        let content = """
        [web](https://example.com) [mail](mailto:a@b.c) [anchor](#sec) [proto](//cdn.x/a.js)
        """
        XCTAssertTrue(run(content).isEmpty)
    }

    func testDeadLink_fragmentAndQueryStripped() {
        createFile("notes.md", content: "hi")
        XCTAssertTrue(run("[a](notes.md#section) [b](notes.md?v=1)\n").isEmpty)
    }

    func testDeadLink_percentEncodedPath() {
        createFile("my notes.md", content: "hi")
        XCTAssertTrue(run("[a](my%20notes.md)\n").isEmpty)
    }

    func testDeadLink_titleAndAngleBracketTarget() {
        createFile("notes.md", content: "hi")
        XCTAssertTrue(run("[a](notes.md \"标题\") [b](<notes.md>)\n").isEmpty)
    }

    // MARK: - 缺图

    func testMissingImage_flaggedAsImageKind() {
        let issues = run("![shot](images/shot.png)\n")
        XCTAssertEqual(kinds(issues), [.missingImage("images/shot.png")])
    }

    func testMissingImage_existingImageNotFlagged() {
        createFile("shot.png", content: "not-really-png")
        XCTAssertTrue(run("![shot](shot.png)\n").isEmpty)
    }

    // MARK: - 工作区扫描

    func testScan_walksWorkspaceAndSortsResults() async {
        createFile("b.md", content: "# Dup\n# Dup\n")
        createFile("sub/a.md", content: "[x](nope.md)\n")
        createFile("c.txt", content: "[x](nope.md)\n")   // 非 md 文件不扫描
        let issues = await DocumentDiagnostics.scan(rootURL: tempDir)
        XCTAssertEqual(issues.count, 2)
        // 按完整路径字典序排序：根目录 b.md 在 sub/a.md 之前（"b" < "s"）
        XCTAssertEqual(issues[0].fileURL.lastPathComponent, "b.md", "结果应按文件路径排序")
        XCTAssertEqual(issues[1].fileURL.lastPathComponent, "a.md")
    }

    // MARK: - Agent 可修复性（「让 Agent 修复」入口口径）

    func testIsAgentFixable_missingImageNotFixable() {
        // 纯缺失资源：模型变不出图片文件，不计入可修复
        XCTAssertFalse(DocumentIssue.Kind.missingImage("a.png").isAgentFixable)
    }

    func testIsAgentFixable_textEditableKindsAreFixable() {
        let kinds: [DocumentIssue.Kind] = [
            .deadLink("x.md"), .duplicateHeading("T"),
            .headingLevelSkip(from: 1, to: 3), .emptyHeading, .unclosedCodeBlock,
            .mermaidSyntax("parse error")
        ]
        for kind in kinds {
            XCTAssertTrue(kind.isAgentFixable, "\(kind) 应可由模型改文本修复")
        }
    }

    // MARK: - mermaidSyntax 分级

    func testMermaidSyntax_isReportOnlyError() {
        let kind = DocumentIssue.Kind.mermaidSyntax("Parse error on line 1")
        // 修复要靠模型判断（不是确定性文本替换）⇒ 不进「一键修复」列表
        XCTAssertFalse(kind.isDeterministicFix, "mermaid 语法错误应只报告（reportOnly）")
        // 语法错的图在导出产物里是缺内容 ⇒ error 级
        let issue = DocumentIssue(kind: kind, fileURL: fileURL, line: 0)
        XCTAssertEqual(issue.severity, .error)
    }
}
