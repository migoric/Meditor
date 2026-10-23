import XCTest
@testable import MEditor

/// 工具预算的契约测试。
///
/// 这里钉的**不是**「裁得更多」，而是「只在有把握时裁」：藏掉唯一能用的工具比
/// 多花 token 更糟（模型没法猜到自己没有的工具，用户看到的是"它说做不到"）。
final class AgentToolBudgetTests: XCTestCase {

    private struct Stub: AgentTool {
        let spec: AgentToolSpec
        init(_ name: String, _ description: String = "") {
            spec = AgentToolSpec(name: name, description: description.isEmpty ? "tool \(name)" : description)
        }
        func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String { "ok" }
    }

    private func builtins(_ n: Int) -> [any AgentTool] {
        (0..<n).map { Stub("builtin_\($0)") }
    }

    private func mcp(_ name: String, _ description: String) -> any AgentTool {
        Stub("mcp__srv__\(name)", description)
    }

    private func names(_ tools: [any AgentTool]) -> [String] { tools.map(\.spec.name) }

    // MARK: - 预算内原样放行

    func test_underBudget_isPassThrough() {
        let tools = builtins(3) + [mcp("create_issue", "Create a GitHub issue"), mcp("list_repos", "List repositories")]
        let sel = AgentToolBudget.select(tools: tools, query: "create issue", maxTools: 32)
        XCTAssertEqual(names(sel.tools), names(tools))
        XCTAssertTrue(sel.dropped.isEmpty)
        XCTAssertNil(sel.notice)
    }

    // MARK: - 超预算且有信号 ⇒ 裁

    func test_overBudget_withSignal_keepsMatchedOnly() {
        let tools = builtins(2)
            + [mcp("create_issue", "Create a GitHub issue in a repository"),
               mcp("list_repos", "List GitHub repositories"),
               mcp("send_email", "Send an email message")]

        let sel = AgentToolBudget.select(tools: tools, query: "please create an issue on github", maxTools: 4)
        let kept = Set(names(sel.tools))

        XCTAssertTrue(kept.contains("builtin_0") && kept.contains("builtin_1"), "内置工具永不裁剪")
        XCTAssertTrue(kept.contains("mcp__srv__create_issue"), "命中查询的工具必须留下")
        XCTAssertTrue(sel.didTrim)
        XCTAssertLessThanOrEqual(sel.tools.count, 4, "裁剪后必须落回预算内")
    }

    func test_notice_listsDroppedTools() {
        let tools = builtins(1)
            + [mcp("create_issue", "Create a GitHub issue"),
               mcp("send_email", "Send an email message"),
               mcp("deploy_site", "Deploy a website")]
        let sel = AgentToolBudget.select(tools: tools, query: "create issue", maxTools: 2)
        let notice = try? XCTUnwrap(sel.notice)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("mcp__srv__") ?? false, "提示必须点名折叠了哪些工具")
        XCTAssertTrue((notice?.count ?? 0) < 400, "提示本身不该变成新的 token 负担")
    }

    // MARK: - 超预算但无信号 ⇒ 不裁（宁可多付）

    func test_overBudget_withoutSignal_keepsEverything() {
        let tools = builtins(1)
            + [mcp("create_issue", "Create a GitHub issue"),
               mcp("send_email", "Send an email message")]
        // 中文提问，英文工具描述 ⇒ 一个词都不命中。此时裁剪等于瞎猜。
        let sel = AgentToolBudget.select(tools: tools, query: "帮我把这个文件整理一下", maxTools: 2)
        XCTAssertEqual(names(sel.tools), names(tools))
        XCTAssertTrue(sel.dropped.isEmpty)
        XCTAssertNil(sel.notice)
    }

    func test_overBudget_emptyQuery_keepsEverything() {
        let tools = builtins(1) + [mcp("a", "A"), mcp("b", "B")]
        let sel = AgentToolBudget.select(tools: tools, query: "", maxTools: 2)
        XCTAssertEqual(sel.tools.count, tools.count)
    }

    // MARK: - 确定性

    func test_sameInput_sameSelection() {
        let tools = builtins(1)
            + [mcp("alpha", "issue tracker"), mcp("beta", "issue tracker"), mcp("gamma", "issue tracker")]
        let a = names(AgentToolBudget.select(tools: tools, query: "issue", maxTools: 3).tools)
        let b = names(AgentToolBudget.select(tools: tools, query: "issue", maxTools: 3).tools)
        XCTAssertEqual(a, b, "同分时必须按名字定序，否则同一句话两次运行工具集不同")
    }

    func test_keptToolsPreserveInputOrder() {
        let tools = builtins(2)
            + [mcp("z_tool", "deploy website"), mcp("a_tool", "deploy website"), mcp("other", "unrelated")]
        // 5 条 > 上限 4 ⇒ 会裁；两个命中者都留下。输出顺序必须跟传入一致
        // （z 在 a 前），不能按分数或名字重排——否则 wire 字节每轮可能变，
        // prompt cache 命中率受害。
        let sel = AgentToolBudget.select(tools: tools, query: "deploy", maxTools: 4)
        XCTAssertEqual(names(sel.tools), ["builtin_0", "builtin_1", "mcp__srv__z_tool", "mcp__srv__a_tool"])
        XCTAssertEqual(names(sel.dropped), ["mcp__srv__other"])
    }

    // MARK: - 命名判据

    func test_isExternal_usesMCPPrefix() {
        XCTAssertTrue(AgentToolBudget.isExternal("mcp__github__create_issue"))
        XCTAssertFalse(AgentToolBudget.isExternal("read_file"))
        XCTAssertFalse(AgentToolBudget.isExternal("mcp"))  // 只是前缀相同？否：必须带分隔符
    }

    func test_tokenize_dropsSingleCharsAndPunctuation() {
        let tokens = AgentToolBudget.tokenize("Create a GitHub issue, please!")
        XCTAssertTrue(tokens.contains("create"))
        XCTAssertTrue(tokens.contains("github"))
        XCTAssertFalse(tokens.contains("a"), "单字符词没有区分度")
        XCTAssertFalse(tokens.contains(","))
    }

    // MARK: - 极端：内置本身超预算

    func test_builtinAloneExceedsBudget_dropsAllExternalWhenSignalExists() {
        let tools = builtins(5) + [mcp("create_issue", "Create a GitHub issue")]
        let sel = AgentToolBudget.select(tools: tools, query: "create issue", maxTools: 3)
        XCTAssertEqual(sel.tools.count, 5, "内置不能裁，只能把外部全折掉")
        XCTAssertEqual(sel.dropped.count, 1)
    }
}
