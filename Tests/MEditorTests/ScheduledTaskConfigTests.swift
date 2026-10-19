import XCTest
@testable import MEditor

// MARK: - ScheduledTaskConfigTests
//
// schedules.json 配置加载/合并/写回：
//   全局/工作区合并、同名覆盖（工作区胜出）、坏条目跳过并记录、
//   缺省 enabled = true、enabled 开关写回保留其余字段
//
// fixture 全部用临时目录，不依赖真实 ~/.meditor。

final class ScheduledTaskConfigTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedules-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 加载：基础与合并

    func test_load_missingFiles_returnsEmpty() {
        let result = ScheduledTaskConfigLoader.load(
            globalConfigURL: tempRoot.appendingPathComponent("global/schedules.json"),
            workspaceRoot: tempRoot.appendingPathComponent("ws"))
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func test_load_globalOnly() throws {
        let global = tempRoot.appendingPathComponent("global/schedules.json")
        try write("""
        {"schedules": [
          {"name": "daily", "cron": "0 9 * * *", "prompt": "do daily", "enabled": true}
        ]}
        """, to: global)
        let result = ScheduledTaskConfigLoader.load(globalConfigURL: global, workspaceRoot: nil)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.name, "daily")
        XCTAssertEqual(result.entries.first?.source, .global)
        XCTAssertEqual(result.entries.first?.enabled, true)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func test_load_workspaceOverridesSameName() throws {
        let global = tempRoot.appendingPathComponent("global/schedules.json")
        let ws = tempRoot.appendingPathComponent("ws")
        try write("""
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "global a", "enabled": true},
          {"name": "b", "cron": "0 10 * * *", "prompt": "global b"}
        ]}
        """, to: global)
        try write("""
        {"schedules": [
          {"name": "a", "cron": "0 8 * * 1", "prompt": "workspace a", "enabled": false}
        ]}
        """, to: ScheduledTaskConfigLoader.workspaceConfigURL(root: ws))

        let result = ScheduledTaskConfigLoader.load(globalConfigURL: global, workspaceRoot: ws)
        XCTAssertEqual(result.entries.map(\.name), ["a", "b"], "覆盖不改变条目顺序")
        XCTAssertEqual(result.entries[0].prompt, "workspace a", "同名条目工作区胜出")
        XCTAssertEqual(result.entries[0].source, .workspace)
        XCTAssertFalse(result.entries[0].enabled)
        XCTAssertEqual(result.entries[1].source, .global)
    }

    func test_load_workspaceOnlyEntryAppended() throws {
        let global = tempRoot.appendingPathComponent("global/schedules.json")
        let ws = tempRoot.appendingPathComponent("ws")
        try write(#"{"schedules": [{"name": "g", "cron": "0 9 * * *", "prompt": "g"}]}"#, to: global)
        try write(#"{"schedules": [{"name": "w", "cron": "0 9 * * *", "prompt": "w"}]}"#,
                  to: ScheduledTaskConfigLoader.workspaceConfigURL(root: ws))
        let result = ScheduledTaskConfigLoader.load(globalConfigURL: global, workspaceRoot: ws)
        XCTAssertEqual(result.entries.map(\.name), ["g", "w"])
    }

    // MARK: - 解析容错：坏条目跳过并记录

    func test_parse_badEntriesSkippedWithIssues() throws {
        let data = """
        {"schedules": [
          {"name": "ok", "cron": "0 9 * * *", "prompt": "fine"},
          {"cron": "0 9 * * *", "prompt": "no name"},
          {"name": "  ", "cron": "0 9 * * *", "prompt": "blank name"},
          {"name": "bad-cron", "cron": "99 * * * *", "prompt": "p"},
          {"name": "no-prompt", "cron": "0 9 * * *"},
          {"name": "empty-prompt", "cron": "0 9 * * *", "prompt": "  "},
          "not an object"
        ]}
        """.data(using: .utf8)!
        let result = ScheduledTaskConfigLoader.parse(data: data, source: .workspace)
        XCTAssertEqual(result.entries.map(\.name), ["ok"], "只有合法条目进入结果")
        XCTAssertEqual(result.entries.first?.source, .workspace)
        XCTAssertEqual(result.issues.count, 6, "每个坏条目都应有一条 issue")
        // 断言不写死语言/文案（CI 英文 locale），只校验记录了条目位置
        XCTAssertTrue(result.issues.allSatisfy { $0.contains("workspace") })
    }

    func test_parse_invalidJSON_andWrongRoot() {
        let badJSON = ScheduledTaskConfigLoader.parse(data: Data("{oops".utf8), source: .global)
        XCTAssertTrue(badJSON.entries.isEmpty)
        XCTAssertEqual(badJSON.issues.count, 1)

        let wrongRoot = ScheduledTaskConfigLoader.parse(data: Data("[1,2]".utf8), source: .global)
        XCTAssertTrue(wrongRoot.entries.isEmpty)
        XCTAssertEqual(wrongRoot.issues.count, 1)
    }

    func test_parse_enabledDefaultsTrue_andFalsePreserved() {
        let data = """
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "x"},
          {"name": "b", "cron": "0 9 * * *", "prompt": "y", "enabled": false}
        ]}
        """.data(using: .utf8)!
        let result = ScheduledTaskConfigLoader.parse(data: data, source: .global)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries[0].enabled, "enabled 缺省视为 true")
        XCTAssertFalse(result.entries[1].enabled)
        XCTAssertEqual(result.entries[0].cron, "0 9 * * *", "cron 原文保留用于展示")
    }

    // MARK: - 写回：enabled 开关

    func test_writer_setEnabled_preservesOtherFields() throws {
        let url = tempRoot.appendingPathComponent("schedules.json")
        try write("""
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "pa", "enabled": true},
          {"name": "b", "cron": "30 18 * * 5", "prompt": "pb", "enabled": true}
        ]}
        """, to: url)

        try ScheduledTaskConfigWriter.setEnabled(false, forName: "b", configURL: url)

        let result = ScheduledTaskConfigLoader.load(globalConfigURL: url, workspaceRoot: nil)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries[0].enabled, "其他条目不受影响")
        XCTAssertFalse(result.entries[1].enabled)
        XCTAssertEqual(result.entries[1].cron, "30 18 * * 5", "其余字段保留")
        XCTAssertEqual(result.entries[1].prompt, "pb")
    }

    func test_writer_missingEntry_throws() throws {
        let url = tempRoot.appendingPathComponent("schedules.json")
        try write(#"{"schedules": [{"name": "a", "cron": "0 9 * * *", "prompt": "p"}]}"#, to: url)
        XCTAssertThrowsError(try ScheduledTaskConfigWriter.setEnabled(false, forName: "nope", configURL: url))
    }

    func test_writer_template_isValidConfig() {
        // 设置页「打开配置文件」写入的模板必须能被加载（示例条目默认停用）
        let result = ScheduledTaskConfigLoader.parse(
            data: Data(ScheduledTaskConfigWriter.template.utf8), source: .global)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(result.entries[0].enabled)
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: - autoApprove：无人值守写入免确认

    func test_parse_autoApprove_defaultsFalse() {
        let data = """
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "x"}
        ]}
        """.data(using: .utf8)!
        let result = ScheduledTaskConfigLoader.parse(data: data, source: .global)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(result.entries[0].autoApprove, "autoApprove 缺省必须为 false（确认条是默认）")
        XCTAssertTrue(result.entries[0].writeAllowlist.isEmpty)
        XCTAssertEqual(result.entries[0].writeAutoApproval, .none)
    }

    func test_parse_autoApprove_withAllowlist() {
        let data = """
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "x", "autoApprove": true, "writeAllowlist": ["weekly/", " /reports "]},
          {"name": "b", "cron": "0 9 * * *", "prompt": "y", "autoApprove": true}
        ]}
        """.data(using: .utf8)!
        let result = ScheduledTaskConfigLoader.parse(data: data, source: .global)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].writeAllowlist, ["weekly/", "reports"],
                       "白名单条目去首尾空白、去开头斜杠")
        XCTAssertEqual(result.entries[0].writeAutoApproval, .dirs(["weekly/", "reports"]))
        XCTAssertEqual(result.entries[1].writeAutoApproval, .all,
                       "autoApprove 无白名单 = 工作区内全部免确认")
    }

    func test_parse_autoApprove_wrongType_isFalse() {
        let data = """
        {"schedules": [
          {"name": "a", "cron": "0 9 * * *", "prompt": "x", "autoApprove": "yes"}
        ]}
        """.data(using: .utf8)!
        let result = ScheduledTaskConfigLoader.parse(data: data, source: .global)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(result.entries[0].autoApprove,
                       "非 Bool 的 autoApprove 按 false（容错方向是多弹确认，不是偷偷放行）")
    }
}
