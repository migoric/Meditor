import XCTest
@testable import MEditor

// MARK: - AgentSchedulerServiceTests
//
// 定时任务调度（AgentSchedulerService）：
//   tick 到期触发 / 同分钟不重复 / 下一分钟可再触发 / 未到期不触发 / disabled 不触发 /
//   工作区覆盖生效 / 坏条目进入 configIssues
//
// 不依赖真实 AI 后端与真实时间等待：触发动作注入记录器（不触碰
// BackgroundAgentTaskService），时钟注入固定值，startTimer: false 关掉真实 Timer。
// 时区固定 UTC，断言不写死中文文案（CI 英文 locale）。
//
// 宿主端口（P0-10）：宿主是注入的 AgentHostPort，测试用 RecordingAgentHost 断言
// 「宿主 rootURL 被当作工作区来源」「写回失败的 toast 到达宿主」——
// 修复前服务直接持 AppState 且单测只能传 nil，这些路径无痕可断言。

@MainActor
final class AgentSchedulerServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var calendar: Calendar!
    private var fired: [String]!
    private var now: Date!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = cal
        fired = []
        now = date(2024, 1, 15, 9, 0, 10)   // 默认：周一 09:00
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try await super.tearDown()
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d,
                                           hour: h, minute: mi, second: s))!
    }

    private var globalConfigURL: URL { tempRoot.appendingPathComponent("global/schedules.json") }
    private var workspaceRoot: URL { tempRoot.appendingPathComponent("ws") }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 构造注入假时钟 + 记录器的服务（不起真实 Timer）
    private func makeService() -> AgentSchedulerService {
        let service = AgentSchedulerService(host: nil,
                                            globalConfigURL: globalConfigURL,
                                            startTimer: false)
        service.calendar = calendar
        service.now = { [unowned self] in self.now }
        service.trigger = { [unowned self] entry in self.fired.append(entry.name) }
        return service
    }

    // MARK: - 到期触发

    func test_tick_dueEntryFires() throws {
        try write(#"{"schedules": [{"name": "morning", "cron": "0 9 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        service.tick()
        XCTAssertEqual(fired, ["morning"])
    }

    func test_tick_sameMinute_notFiredTwice() throws {
        try write(#"{"schedules": [{"name": "morning", "cron": "0 9 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        service.tick()                      // 09:00:10
        now = date(2024, 1, 15, 9, 0, 50)   // 同一分钟内再次 tick
        service.tick()
        XCTAssertEqual(fired, ["morning"], "同一分钟不重复触发")
    }

    func test_tick_nextMinute_canFireAgain() throws {
        try write(#"{"schedules": [{"name": "minutely", "cron": "* * * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        service.tick()
        now = date(2024, 1, 15, 9, 1, 10)
        service.tick()
        XCTAssertEqual(fired, ["minutely", "minutely"], "下一分钟是新的触发窗口")
    }

    // MARK: - 不触发

    func test_tick_notDue_noFire() throws {
        try write(#"{"schedules": [{"name": "evening", "cron": "0 18 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        service.tick()
        XCTAssertTrue(fired.isEmpty)
    }

    func test_tick_disabledEntry_noFire() throws {
        try write("""
        {"schedules": [{"name": "off", "cron": "0 9 * * *", "prompt": "p", "enabled": false}]}
        """, to: globalConfigURL)
        let service = makeService()
        service.tick()
        XCTAssertTrue(fired.isEmpty)
        // 停用条目仍在列表里（设置页要展示开关状态）
        XCTAssertEqual(service.entries.map(\.name), ["off"])
    }

    func test_tick_noConfig_noOp() {
        let service = makeService()
        service.tick()
        XCTAssertTrue(fired.isEmpty)
        XCTAssertTrue(service.entries.isEmpty)
    }

    // MARK: - 配置合并与容错

    func test_reload_workspaceOverrideWins() throws {
        // 全局启用，工作区同名条目覆盖为停用 → 不触发
        try write(#"{"schedules": [{"name": "task", "cron": "0 9 * * *", "prompt": "g"}]}"#,
                  to: globalConfigURL)
        try write("""
        {"schedules": [{"name": "task", "cron": "0 9 * * *", "prompt": "w", "enabled": false}]}
        """, to: ScheduledTaskConfigLoader.workspaceConfigURL(root: workspaceRoot))
        let service = makeService()
        service.reload(workspaceURL: workspaceRoot)
        service.tick()
        XCTAssertTrue(fired.isEmpty, "工作区同名条目（停用）应覆盖全局")
        XCTAssertEqual(service.entries.first?.source, .workspace)
    }

    func test_reload_badEntryRecordedInIssues() throws {
        try write(#"{"schedules": [{"name": "bad", "cron": "oops", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(service.configIssues.count, 1, "坏条目应记录到 configIssues 供设置页展示")
    }

    // MARK: - 展示辅助

    func test_nextFireDate_enabledEntry() throws {
        try write(#"{"schedules": [{"name": "daily", "cron": "0 9 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = makeService()
        let entry = try XCTUnwrap(service.entries.first)
        // now = 09:00:10，下一次 09:00 是明天
        XCTAssertEqual(service.nextFireDate(for: entry), date(2024, 1, 16, 9, 0))
    }

    // MARK: - 宿主端口（P0-10）

    /// 宿主 rootURL 必须被当作工作区配置来源（init 时的 reload 参数）。
    func test_init_usesHostRootURL_asWorkspaceSource() throws {
        let host = RecordingAgentHost()
        host.rootURL = workspaceRoot
        try write(#"{"schedules": [{"name": "from-workspace", "cron": "0 9 * * *", "prompt": "w"}]}"#,
                  to: ScheduledTaskConfigLoader.workspaceConfigURL(root: workspaceRoot))

        let service = AgentSchedulerService(host: host,
                                            globalConfigURL: globalConfigURL,
                                            startTimer: false)
        XCTAssertEqual(service.entries.map(\.name), ["from-workspace"],
                       "宿主 rootURL 应作为工作区配置来源")
        XCTAssertEqual(service.entries.first?.source, .workspace)
    }

    /// 写回失败（条目在磁盘上已消失）→ 经端口给宿主一条 toast。
    func test_setEnabled_writeBackFailure_toastReachesHost() throws {
        let host = RecordingAgentHost()
        try write(#"{"schedules": [{"name": "morning", "cron": "0 9 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        let service = AgentSchedulerService(host: host,
                                            globalConfigURL: globalConfigURL,
                                            startTimer: false)
        let entry = try XCTUnwrap(service.entries.first)

        // 磁盘上换成别的条目：setEnabled 找不到 "morning" → 抛错 → 走 toast 分支
        try write(#"{"schedules": [{"name": "other", "cron": "0 9 * * *", "prompt": "p"}]}"#,
                  to: globalConfigURL)
        service.setEnabled(true, entry: entry)

        XCTAssertEqual(host.toasts.count, 1, "写回失败应经端口提示宿主")
        XCTAssertEqual(host.toasts.first?.icon, "exclamationmark.triangle")
        XCTAssertTrue(host.toasts.first?.text.isEmpty == false)
    }
}
