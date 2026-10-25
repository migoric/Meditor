import XCTest
@testable import MEditor

// MARK: - MCPServerTests
//
// 覆盖：
//   - JSON-RPC 解析与错误码（-32700 / -32600 / -32601 / -32602）
//   - initialize 握手 / notifications 吞掉 / ping
//   - tools/list 完整性（schema 由现有 AgentToolSpec 生成；UI 依赖工具不暴露）
//   - tools/call 文件工具真实往返（临时目录做工作区）
//   - run_command 的沙箱策略：safe 执行 / blocked 拒绝 / warn 无头默认拒绝 + 开关放行
//
// 注意：CI 是英文 locale，断言不写死工具输出的中文文案，只断言结构性内容与 ASCII 片段。

final class MCPServerTests: XCTestCase {

    var tempRoot: URL!
    var server: MCPServer!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // allowShell: true —— 本套件要覆盖 run_command 的沙箱策略；
        // 「默认不暴露 run_command」由 test_headlessTools_* 单独覆盖。
        server = MCPServer(workspaceRoot: tempRoot, allowShell: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        server = nil
    }

    // MARK: - Helpers

    private func requestJSON(_ method: String, params: [String: Any]? = nil, id: Any?? = nil) -> String {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { obj["params"] = params }
        if let id = id, let value = id { obj["id"] = value }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// 处理一行请求并解析响应为字典；响应为 nil（通知）时返回 nil。
    private func handle(_ line: String) async -> [String: Any]? {
        guard let response = await server.handleLine(line) else { return nil }
        let data = response.data(using: .utf8)!
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func callTool(_ name: String, _ arguments: [String: Any] = [:], id: Int = 7) async -> [String: Any]? {
        await handle(requestJSON("tools/call", params: ["name": name, "arguments": arguments], id: id))
    }

    private func toolText(_ response: [String: Any]?) -> String? {
        guard let result = response?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func isErrorResult(_ response: [String: Any]?) -> Bool {
        (response?["result"] as? [String: Any])?["isError"] as? Bool ?? false
    }

    private func errorCode(_ response: [String: Any]?) -> Int? {
        (response?["error"] as? [String: Any])?["code"] as? Int
    }

    // MARK: - JSON-RPC 解析

    func test_parse_invalidJSON_parseError() {
        switch MCPJSONRPC.parse(line: "this is not json") {
        case .failure(let e): XCTAssertEqual(e.code, -32700)
        case .success:        XCTFail("invalid JSON should fail parsing")
        }
    }

    func test_parse_nonObject_invalidRequest() {
        switch MCPJSONRPC.parse(line: "[1,2,3]") {
        case .failure(let e): XCTAssertEqual(e.code, -32600)
        case .success:        XCTFail("non-object message should be invalid request")
        }
    }

    func test_parse_missingMethod_invalidRequest() {
        switch MCPJSONRPC.parse(line: #"{"jsonrpc":"2.0","id":1}"#) {
        case .failure(let e): XCTAssertEqual(e.code, -32600)
        case .success:        XCTFail("missing method should be invalid request")
        }
    }

    func test_parse_boolID_invalidRequest() {
        switch MCPJSONRPC.parse(line: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#) {
        case .failure(let e): XCTAssertEqual(e.code, -32600)
        case .success:        XCTFail("bool id should be invalid request")
        }
    }

    func test_parse_intAndStringIDs() throws {
        let intMsg = try MCPJSONRPC.parse(line: #"{"jsonrpc":"2.0","id":42,"method":"ping"}"#).get()
        XCTAssertEqual(intMsg.id, .int(42))
        let strMsg = try MCPJSONRPC.parse(line: #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#).get()
        XCTAssertEqual(strMsg.id, .string("abc"))
        let nullMsg = try MCPJSONRPC.parse(line: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#).get()
        XCTAssertEqual(nullMsg.id, .null)
    }

    func test_parse_notification_hasNoID() throws {
        let msg = try MCPJSONRPC.parse(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).get()
        XCTAssertNil(msg.id)
        XCTAssertEqual(msg.method, "notifications/initialized")
    }

    func test_parse_paramsConverted() throws {
        let msg = try MCPJSONRPC.parse(
            line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"filename":"a.md"}}}"#
        ).get()
        XCTAssertEqual(msg.params["name"]?.stringValue, "read_file")
        guard case .dict(let args) = msg.params["arguments"] else {
            return XCTFail("arguments should be a dict")
        }
        XCTAssertEqual(args["filename"]?.stringValue, "a.md")
    }

    // MARK: - 握手与基础方法

    func test_initialize_returnsProtocolVersionAndServerInfo() async {
        let resp = await handle(requestJSON("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "test-client", "version": "0.0"],
        ], id: 1))
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, MCPServer.protocolVersion)
        XCTAssertEqual(resp?["id"] as? Int, 1)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "MEditor")
        XCTAssertNotNil(serverInfo?["version"] as? String)
        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"], "initialize should advertise tools capability")
    }

    func test_initializedNotification_isSwallowed() async {
        let resp = await server.handleLine(requestJSON("notifications/initialized"))
        XCTAssertNil(resp, "notifications must not get a response")
    }

    func test_unknownNotification_isSwallowed() async {
        let resp = await server.handleLine(requestJSON("notifications/whatever"))
        XCTAssertNil(resp)
    }

    func test_ping_returnsEmptyResult() async {
        let resp = await handle(requestJSON("ping", id: 3))
        XCTAssertEqual(resp?["id"] as? Int, 3)
        XCTAssertNotNil(resp?["result"] as? [String: Any])
        XCTAssertNil(resp?["error"])
    }

    func test_unknownMethod_methodNotFound() async {
        let resp = await handle(requestJSON("resources/list", id: 4))
        XCTAssertEqual(errorCode(resp), -32601)
        XCTAssertEqual(resp?["id"] as? Int, 4)
    }

    func test_invalidJSON_returnsParseErrorWithNullID() async {
        let resp = await handle("not json at all")
        XCTAssertEqual(errorCode(resp), -32700)
        XCTAssertTrue(resp?["id"] is NSNull, "parse error response should use id: null")
    }

    // MARK: - tools/list

    func test_toolsList_exposesHeadlessToolSet() async {
        let resp = await handle(requestJSON("tools/list", id: 5))
        let result = resp?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])

        // 结构工具只放**只读**的那 5 个：外部 agent 定位文档需要大纲/结构树/节点读取，
        // 而这几个不产生写入。写类（rewrite_section / patch_style / set_node_class /
        // write_html_with_template）进 MCPToolCatalog.excludedToolNames —— 无头模式
        // 没有 diff 审阅，不该顺手把写入面从 2 个变成 6 个。
        let expected: Set<String> = [
            "read_document", "write_document", "patch_document", "search_document",
            "list_files", "read_file", "create_file", "write_file",
            "create_directory", "search_workspace",
            "run_command", "get_html_template",
            "outline_document", "read_section",
            "html_outline", "read_node", "read_style",
        ]
        XCTAssertEqual(names, expected, "tools/list should expose exactly the headless-safe tool set")
        XCTAssertFalse(names.contains("insert_at_cursor"), "cursor-dependent tool must not be exposed")
        XCTAssertFalse(names.contains("open_file"), "editor-tab tool must not be exposed")
        XCTAssertFalse(names.contains("rewrite_section"), "write tools stay out of headless mode")
    }

    func test_toolsList_entriesCarryGeneratedInputSchema() async {
        let resp = await handle(requestJSON("tools/list", id: 5))
        let tools = (resp?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 17)
        for tool in tools ?? [] {
            XCTAssertNotNil(tool["name"] as? String)
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, "description should come from AgentToolSpec")
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object")
            XCTAssertNotNil(schema?["properties"] as? [String: Any])
            XCTAssertNotNil(schema?["required"] as? [String])
        }
        let readFile = tools?.first { $0["name"] as? String == "read_file" }
        let required = (readFile?["inputSchema"] as? [String: Any])?["required"] as? [String]
        XCTAssertEqual(required, ["filename"])
        let props = (readFile?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual((props?["filename"] as? [String: Any])?["type"] as? String, "string")
    }

    // MARK: - tools/call：文件工具真实往返

    func test_callWriteThenReadFile_roundTrip() async throws {
        let write = await callTool("write_file", ["filename": "notes.md", "content": "hello mcp world"], id: 10)
        XCTAssertFalse(isErrorResult(write), "write_file should succeed, got: \(toolText(write) ?? "nil")")
        XCTAssertEqual(respID(write), 10)

        // 真实落盘校验
        let onDisk = try String(contentsOf: tempRoot.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "hello mcp world")

        let read = await callTool("read_file", ["filename": "notes.md"], id: 11)
        XCTAssertFalse(isErrorResult(read))
        XCTAssertTrue(toolText(read)?.contains("hello mcp world") ?? false,
                      "read_file should return the written content")
    }

    func test_callPatchDocument_withFilename() async throws {
        _ = await callTool("write_file", ["filename": "patch.md", "content": "alpha beta gamma"])
        let patch = await callTool("patch_document", [
            "filename": "patch.md", "find": "beta", "replace": "BETA",
        ])
        XCTAssertFalse(isErrorResult(patch), "patch should succeed, got: \(toolText(patch) ?? "nil")")
        let onDisk = try String(contentsOf: tempRoot.appendingPathComponent("patch.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "alpha BETA gamma")
    }

    func test_callListFiles_listsCreatedFile() async {
        _ = await callTool("create_file", ["filename": "listed.md", "content": "x"])
        let list = await callTool("list_files")
        XCTAssertTrue(toolText(list)?.contains("listed.md") ?? false)
    }

    func test_callSearchWorkspace_findsMatch() async {
        _ = await callTool("write_file", ["filename": "searchable.md", "content": "needle_in_workspace"])
        let search = await callTool("search_workspace", ["query": "needle_in_workspace"])
        let text = toolText(search) ?? ""
        XCTAssertTrue(text.contains("searchable.md"), "search result should name the file, got: \(text)")
    }

    func test_callUnknownTool_invalidParams() async {
        let resp = await callTool("does_not_exist")
        XCTAssertEqual(errorCode(resp), -32602)
    }

    func test_callMissingToolName_invalidParams() async {
        let resp = await handle(requestJSON("tools/call", params: ["arguments": [:]], id: 8))
        XCTAssertEqual(errorCode(resp), -32602)
    }

    func test_callWriteOutsideWorkspace_rejected() async {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-mcp-escape-\(UUID().uuidString).md")
        let resp = await callTool("write_file", ["filename": outside.path, "content": "escape"])
        XCTAssertTrue(isErrorResult(resp), "writes outside the workspace must be rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "rejected write must not touch the filesystem")
    }

    // MARK: - tools/call：run_command 沙箱策略

    func test_runCommand_safe_executes() async {
        let resp = await callTool("run_command", ["command": "echo mcp_safe_probe"])
        XCTAssertFalse(isErrorResult(resp))
        XCTAssertTrue(toolText(resp)?.contains("mcp_safe_probe") ?? false,
                      "safe command should execute, got: \(toolText(resp) ?? "nil")")
    }

    func test_runCommand_blocked_rejectedWithoutExecution() async {
        let resp = await callTool("run_command", ["command": "sudo echo should_not_run"])
        XCTAssertTrue(toolText(resp)?.hasPrefix("[!]") ?? false,
                      "blocked command should be refused by the sandbox")
    }

    func test_runCommand_warn_deniedByDefaultInHeadless() async {
        let resp = await callTool("run_command", ["command": "git push origin main"])
        XCTAssertTrue(isErrorResult(resp), "warn-level command should be an error result in headless mode")
        XCTAssertTrue(toolText(resp)?.contains("--allow-warn-commands") ?? false,
                      "denial should explain the opt-in flag, got: \(toolText(resp) ?? "nil")")
    }

    func test_runCommand_warn_allowedWithFlag() async {
        let permissive = MCPServer(workspaceRoot: tempRoot, allowWarnCommands: true, allowShell: true)
        // mv 是 warn 级；源文件不存在 → 命令实际执行但 shell 报错退出，
        // 以此区分「被策略拒绝」与「被执行后失败」。
        let line = requestJSON("tools/call", params: [
            "name": "run_command",
            "arguments": ["command": "mv missing_a.txt missing_b.txt"],
        ], id: 9)
        guard let raw = await permissive.handleLine(line),
              let resp = try? JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as? [String: Any]
        else { return XCTFail("expected a response") }
        let text = toolText(resp) ?? ""
        XCTAssertFalse(text.contains("--allow-warn-commands"),
                       "with the flag on, warn command must run instead of being policy-denied")
        XCTAssertTrue(text.hasPrefix("[!]"), "mv on missing files should report shell failure, got: \(text)")
    }

    func test_runCommand_cwdOutsideWorkspace_rejected() async {
        let resp = await callTool("run_command", ["command": "echo x", "cwd": "/tmp"])
        XCTAssertTrue(toolText(resp)?.hasPrefix("[!]") ?? false,
                      "cwd outside the workspace should be rejected")
    }

    // MARK: - CLI 参数解析

    func test_shouldRun_onlyForMCPSubcommand() {
        XCTAssertTrue(MCPCommand.shouldRun(arguments: ["/bin/MEditor", "mcp"]))
        XCTAssertTrue(MCPCommand.shouldRun(arguments: ["/bin/MEditor", "mcp", "--workspace", "/tmp"]))
        XCTAssertFalse(MCPCommand.shouldRun(arguments: ["/bin/MEditor"]))
        XCTAssertFalse(MCPCommand.shouldRun(arguments: ["/bin/MEditor", "--workspace", "/tmp"]))
        XCTAssertFalse(MCPCommand.shouldRun(arguments: ["/bin/MEditor", "mcp-extra"]))
    }

    // MARK: - run_command 默认不暴露（headless 无确认对话框，字符串黑名单不是安全边界）

    func test_headlessTools_runCommandHiddenByDefault() {
        let names = Set(MCPToolCatalog.headlessTools.map { $0.spec.name })
        XCTAssertFalse(names.contains("run_command"), "无头模式默认不得暴露 run_command")
        XCTAssertTrue(names.contains("read_file"))
    }

    func test_headlessTools_allowShellExposesRunCommand() {
        let names = Set(MCPToolCatalog.headlessTools(allowShell: true).map { $0.spec.name })
        XCTAssertTrue(names.contains("run_command"))
    }

    func test_toolsList_defaultServerHidesRunCommand() async {
        let defaultServer = MCPServer(workspaceRoot: tempRoot)   // allowShell 默认 false
        guard let respStr = await defaultServer.handleLine(requestJSON("tools/list", id: 1)),
              let data = respStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return XCTFail("tools/list 应有响应")
        }
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("run_command"))
    }

    // MARK: - Private

    private func respID(_ response: [String: Any]?) -> Int? {
        response?["id"] as? Int
    }
}
