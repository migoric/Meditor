import XCTest
@testable import MEditor

/// Agent 写后自检：防抖合并、分级规则、无问题静默、run 进行中顺延、修复入口接线。
/// 断言不依赖具体文案（CI 英文 locale），只验结构与计数。
@MainActor
final class AgentWriteSelfCheckTests: XCTestCase {

    private let urlA = URL(fileURLWithPath: "/tmp/selfcheck/a.md")
    private let urlB = URL(fileURLWithPath: "/tmp/selfcheck/b.md")

    /// 默认把所有链接目标视为不存在（不碰真实磁盘），便于稳定制造死链/缺图。
    private func makeCheck(interval: TimeInterval = 60) -> AgentWriteSelfCheck {
        let check = AgentWriteSelfCheck(debounceInterval: interval)
        check.fileExists = { _ in false }
        return check
    }

    // MARK: - 防抖合并

    func testDebounceMergesBurstWritesIntoOneRun() async throws {
        let check = makeCheck(interval: 0.05)
        var runCount = 0
        let exp = expectation(description: "checks ran once")
        check.onDidRunChecks = { _ in
            runCount += 1
            exp.fulfill()
        }
        // 模拟 Agent 一轮对同一文档连写 5 次
        for i in 0..<5 {
            check.notifyAgentWrite(url: urlA, content: "# Title \(i)\n\nbody")
        }
        await fulfillment(of: [exp], timeout: 5)
        // 再等几个窗口，确认没有第二次检查
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runCount, 1, "同文档连续写入应合并为一次检查")
        XCTAssertNil(check.pendingReport, "干净内容应静默（不产生报告）")
    }

    func testCoalescesMultipleFilesIntoSingleRun() async {
        let check = makeCheck(interval: 0.05)
        var checkedFiles = 0
        let exp = expectation(description: "checks ran")
        check.onDidRunChecks = { count in
            checkedFiles = count
            exp.fulfill()
        }
        check.notifyAgentWrite(url: urlA, content: "## Dup\n\n## Dup\n")       // 重复标题
        check.notifyAgentWrite(url: urlB, content: "text [link](missing.md)\n") // 死链
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(checkedFiles, 2, "同一窗口内的多文件写入应合并为一次检查")
        let report = check.pendingReport
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.fileURLs.count, 2)
        XCTAssertEqual(report?.totalCount, 2)
    }

    // MARK: - 分级规则

    func testGradingSplitsDeterministicFixesFromReportOnly() {
        let check = makeCheck()
        let content = """
        ## Dup

        ## Dup

        ### Sub

        text [link](missing.md) and ![img](missing.png)
        """
        check.notifyAgentWrite(url: urlA, content: content)
        check.runPendingChecks()

        let report = check.pendingReport
        XCTAssertNotNil(report)
        // 确定性可修：重复标题 + 层级跳跃（H2→? 这里 H2 后直接 ## Dup 同级，无跳跃；
        // 实际分级断言按 kind 核对）
        let fixableKinds = report?.fixable.map(\.kind) ?? []
        let reportOnlyKinds = report?.reportOnly.map(\.kind) ?? []
        XCTAssertTrue(fixableKinds.contains {
            if case .duplicateHeading = $0 { return true }; return false
        }, "重复标题应进一键修复列表")
        XCTAssertTrue(reportOnlyKinds.contains {
            if case .deadLink = $0 { return true }; return false
        }, "死链只报告不自动改")
        XCTAssertTrue(reportOnlyKinds.contains {
            if case .missingImage = $0 { return true }; return false
        }, "缺图只报告不自动改")
        XCTAssertEqual(report?.fixTarget?.lastPathComponent, "a.md")
    }

    func testHeadingLevelSkipIsDeterministicFix() {
        let check = makeCheck()
        check.notifyAgentWrite(url: urlA, content: "# Top\n\n### Skipped\n")
        check.runPendingChecks()
        let kinds = check.pendingReport?.fixable.map(\.kind) ?? []
        XCTAssertTrue(kinds.contains {
            if case .headingLevelSkip = $0 { return true }; return false
        }, "层级跳跃应进一键修复列表")
    }

    // MARK: - 静默与顺延

    func testCleanWriteStaysSilent() {
        let check = makeCheck()
        var reported = false
        check.onReport = { _ in reported = true }
        check.notifyAgentWrite(url: urlA, content: "# Title\n\nAll good.\n")
        check.runPendingChecks()
        XCTAssertNil(check.pendingReport, "无问题时不产生报告")
        XCTAssertFalse(reported, "无问题时不回调通知")
    }

    func testCleanRecheckClearsPreviousReport() {
        let check = makeCheck()
        check.notifyAgentWrite(url: urlA, content: "## Dup\n\n## Dup\n")
        check.runPendingChecks()
        XCTAssertNotNil(check.pendingReport)
        // Agent 修完后再次写入：复查干净 → 报告清除，不打扰
        check.notifyAgentWrite(url: urlA, content: "## Dup\n\n## Fixed\n")
        check.runPendingChecks()
        XCTAssertNil(check.pendingReport, "复查干净应清除旧报告")
    }

    func testDefersWhileAgentRunActive() async throws {
        let check = makeCheck(interval: 0.05)
        var deferFlag = true
        check.shouldDefer = { deferFlag }
        var runCount = 0
        let exp = expectation(description: "checks ran after run ended")
        check.onDidRunChecks = { _ in
            runCount += 1
            exp.fulfill()
        }
        check.notifyAgentWrite(url: urlA, content: "## Dup\n\n## Dup\n")
        // run 进行中：到点应顺延，不检查
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(runCount, 0, "Agent run 进行中不应拿中途态出报告")
        deferFlag = false
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(runCount, 1, "run 结束后应在静默窗口后跑一次")
        XCTAssertNotNil(check.pendingReport)
    }

    // MARK: - 修复入口接线

    private func makeState() -> AppState {
        AppState(fileService: MockFileService(), fileWatcher: MockFileWatcher())
    }

    func testFocusSelfCheckTargetSelectsOpenTab() {
        let state = makeState()
        let tab = EditorTab(url: urlA, content: "## Dup", language: .markdown)
        state.openTabs = [tab]
        state.selectedTabID = nil

        let focused = state.focusSelfCheckTarget(url: urlA)
        XCTAssertEqual(focused?.id, tab.id)
        XCTAssertEqual(state.selectedTab?.id, tab.id, "已打开的 tab 应直接切换选中")
    }

    func testFocusSelfCheckTargetReturnsNilForMissingFile() {
        let state = makeState()
        let missing = URL(fileURLWithPath: "/tmp/selfcheck/definitely-not-here-\(UUID().uuidString).md")
        XCTAssertNil(state.focusSelfCheckTarget(url: missing),
                     "磁盘上不存在且未打开的文件不应定位成功")
    }

    func testFixRequiresFixTarget() {
        let state = makeState()
        // 只有 reportOnly 问题的报告：fixTarget 为 nil，一键修复不发起
        let issue = DocumentIssue(kind: .deadLink("missing.md"), fileURL: urlA, line: 0)
        let report = AgentWriteSelfCheck.Report(fileURLs: [urlA], fixable: [], reportOnly: [issue])
        state.runAgentSelfCheckFix(report)
        XCTAssertNil(state.selectedTab, "无可修问题时不应打开/切换任何文档")
        XCTAssertFalse(state.diffReview.isStreaming, "无可修问题时不应进入写回流程")
    }

    // MARK: - Mermaid 异步校验（注入 mock 校验器，不起真 webview）

    @MainActor
    private final class MockMermaidValidator: MermaidSyntaxChecking {
        /// code → 错误消息；不在表里 = 语法合法
        var results: [String: String] = [:]
        private(set) var validatedCodes: [String] = []
        /// 非 0 时每次校验先睡这么久（制造「在途校验」测取消竞态）。
        /// Task.sleep 随任务取消提前抛错返回，取消后校验立即走到合并守卫。
        var delayNanos: UInt64 = 0

        func validate(code: String) async -> String? {
            validatedCodes.append(code)
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            return results[code]
        }
    }

    /// 轮询直到条件满足（异步校验是 MainActor 上的 Task，sleep 出让即可推进）。
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func mermaidIssues(_ report: AgentWriteSelfCheck.Report?) -> [DocumentIssue] {
        (report?.reportOnly ?? []).filter {
            if case .mermaidSyntax = $0.kind { return true }
            return false
        }
    }

    func testMermaidErrorMergesIntoReportOnlyAtFenceStartLine() async {
        let check = makeCheck()
        let mock = MockMermaidValidator()
        mock.results["graph TD\n  A --> B"] = "Parse error on line 2"
        check.mermaidValidator = mock

        let content = "# Title\n\n```mermaid\ngraph TD\n  A --> B\n```\n"
        check.notifyAgentWrite(url: urlA, content: content)
        check.runPendingChecks()
        XCTAssertNil(check.pendingReport, "同步诊断干净时报告先为 nil，等异步校验")

        let merged = await waitUntil { !self.mermaidIssues(check.pendingReport).isEmpty }
        XCTAssertTrue(merged, "mermaid 语法错误应异步合并进报告")
        let issues = mermaidIssues(check.pendingReport)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.line, 2, "mermaid 错误行号 = 围栏块开栏行")
        XCTAssertEqual(issues.first?.fileURL, urlA)
        XCTAssertTrue(check.pendingReport?.fixable.isEmpty ?? false,
                      "mermaid 错误不应进一键修复列表")
    }

    func testValidMermaidBlocksProduceNoReport() async {
        let check = makeCheck()
        let mock = MockMermaidValidator()
        check.mermaidValidator = mock
        var reported = false
        check.onReport = { _ in reported = true }

        check.notifyAgentWrite(url: urlA, content: "text\n\n```mermaid\ngraph TD\n```\n")
        check.runPendingChecks()
        let ran = await waitUntil { mock.validatedCodes.count == 1 }
        XCTAssertTrue(ran, "含 mermaid 块的写入应触发异步校验")
        XCTAssertNil(check.pendingReport, "语法合法不产生报告")
        XCTAssertFalse(reported, "语法合法不回调通知（静默）")
    }

    func testMermaidErrorMergesIntoExistingSyncReport() async {
        let check = makeCheck()
        let mock = MockMermaidValidator()
        mock.results["bad"] = "Parse error"
        check.mermaidValidator = mock

        let content = "## Dup\n\n## Dup\n\n```mermaid\nbad\n```\n"
        check.notifyAgentWrite(url: urlA, content: content)
        check.runPendingChecks()
        XCTAssertEqual(check.pendingReport?.fixable.count, 1, "重复标题先进同步报告")

        let merged = await waitUntil { !self.mermaidIssues(check.pendingReport).isEmpty }
        XCTAssertTrue(merged)
        XCTAssertEqual(check.pendingReport?.fixable.count, 1, "合并不应丢同步结果")
        XCTAssertEqual(check.pendingReport?.reportOnly.count, 1)
        XCTAssertEqual(check.pendingReport?.fileURLs, [urlA])
    }

    func testNewRoundCancelsInFlightValidation() async {
        let check = makeCheck()
        let mock = MockMermaidValidator()
        mock.delayNanos = 5_000_000_000   // 不取消的话 5 秒后才返回（取消会立即打断 sleep）
        mock.results["graph TD"] = "Parse error"
        check.mermaidValidator = mock

        // 第一轮：含 mermaid 块，校验在途
        check.notifyAgentWrite(url: urlA, content: "```mermaid\ngraph TD\n```\n")
        check.runPendingChecks()
        let started = await waitUntil { mock.validatedCodes.count == 1 }
        XCTAssertTrue(started, "第一轮校验应在途")

        // 第二轮：干净内容（无 mermaid 块）→ 取消第一轮未完成的校验
        check.notifyAgentWrite(url: urlA, content: "# clean\n")
        check.runPendingChecks()

        // 第一轮的迟到结果（sleep 已被取消打断，立即返回错误消息）不得合并
        let settled = await waitUntil(timeout: 2) { check.pendingReport == nil }
        XCTAssertTrue(settled)
        // 再多等一拍，确认没有迟到的合并
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(check.pendingReport, "被取消的上一轮校验结果不得混入新报告")
    }

    func testDismissCancelsInFlightValidation() async {
        let check = makeCheck()
        let mock = MockMermaidValidator()
        mock.delayNanos = 5_000_000_000
        mock.results["graph TD"] = "Parse error"
        check.mermaidValidator = mock

        check.notifyAgentWrite(url: urlA, content: "```mermaid\ngraph TD\n```\n")
        check.runPendingChecks()
        _ = await waitUntil { mock.validatedCodes.count == 1 }

        // 用户在校验在途时点「忽略」：迟到的错误不应让报告条复活
        check.dismissReport()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(check.pendingReport, "忽略后迟到的校验结果不得复活报告条")
    }
}
