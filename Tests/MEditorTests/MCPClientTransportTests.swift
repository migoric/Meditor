import XCTest
@testable import MEditor

// MARK: - MCPClientTransportTests
//
// 覆盖：
//   - stdio roundtrip：临时 shell 脚本假 MCP server（initialize / tools/list / tools/call 应答）
//   - 请求超时（silent server 不应答 → 按超时失败，不悬挂）
//   - 进程退出（EOF）后请求失败
//   - streamable HTTP 的 SSE 响应解析（纯逻辑）
//
// 不依赖真实外部 MCP server；测试用 useLoginShell: false 直接拉起脚本，
// 避开 CI 机器上 login shell rc 文件的噪音与慢启动。
// 注意：CI 是英文 locale，断言只查结构性内容与 ASCII 片段。

final class MCPClientTransportTests: XCTestCase {

    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-mcp-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
    }

    // MARK: - Helpers

    /// 写一个假 MCP server 脚本：逐行读 stdin，按 method 回一行 JSON-RPC 响应。
    /// 用 awk 而非 sh 循环：shell 脚本的 stdout 是块缓冲，响应会攒到缓冲满/进程退出
    /// 才写出（rapid 场景下曾卡死测试）；awk 的 fflush() 每条响应立即落管道。
    /// id 用正则从请求行提取回显；tools/call 把 arguments.text 回显为 "echo:<text>"。
    private func makeFakeServerScript() throws -> URL {
        let script = ##"""
        #!/usr/bin/awk -f
        /notifications/ { next }
        {
          line = $0
          id = ""
          if (match(line, /"id":[0-9]+/)) {
            id = substr(line, RSTART + 5, RLENGTH - 5)
          }
          if (id == "") next
          # 注意：Foundation 的 JSONSerialization 会把 "/" 转义为 "\/"，
          # 线上请求是 "method":"tools\/list" —— 用宽松匹配，不逐字匹配带斜杠的 method
          if (line ~ /initialize/) {
            printf "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.0\"}}}\n", id
          } else if (line ~ /tools/ && line ~ /list/) {
            printf "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}}\n", id
          } else if (line ~ /tools/ && line ~ /call/) {
            text = ""
            if (match(line, /"text":"[^"]*"/)) {
              text = substr(line, RSTART + 8, RLENGTH - 9)
            }
            printf "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo:%s\"}]}}\n", id, text
          }
          fflush()
        }
        """##
        let url = tempRoot.appendingPathComponent("fake-mcp-server.awk")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 只读不应答的 silent server（超时测试用）。
    private func makeSilentServerScript() throws -> URL {
        let url = tempRoot.appendingPathComponent("silent-mcp-server.sh")
        try "#!/bin/sh\nwhile IFS= read -r line; do :; done\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - stdio roundtrip

    func test_stdio_initializeListCall_roundtrip() async throws {
        let script = try makeFakeServerScript()
        let config = MCPServerConfig(name: "fake", kind: .stdio(command: script.path, args: [], env: [:]))
        let transport = try MCPStdioTransport(command: script.path, args: [], env: [:], useLoginShell: false)
        let client = MCPClient(config: config) { _ in transport }

        try await client.connect()

        let tools = await client.tools
        XCTAssertEqual(tools.map(\.name), ["echo"])
        XCTAssertEqual(tools.first?.inputSchema["type"]?.stringValue, "object")

        let result = try await client.callTool(name: "echo", arguments: ["text": "hello"])
        XCTAssertEqual(result, "echo:hello")

        await client.close()
    }

    func test_stdio_requestTimeout_throws() async throws {
        let script = try makeSilentServerScript()
        let transport = try MCPStdioTransport(command: script.path, args: [], env: [:], useLoginShell: false)

        let startedAt = Date()
        do {
            _ = try await transport.request(method: "ping", params: .empty, timeout: 1)
            XCTFail("silent server should time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"),
                          "unexpected error: \(error.localizedDescription)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10, "超时路径不应悬挂")
        await transport.close()
    }

    func test_stdio_processExit_failsPendingAndFutureRequests() async throws {
        // /usr/bin/true 立即退出 → stdout EOF → 挂起/后续请求一律失败
        let transport = try MCPStdioTransport(command: "/usr/bin/true", args: [], env: [:], useLoginShell: false)
        do {
            _ = try await transport.request(method: "ping", params: .empty, timeout: 10)
            XCTFail("request on a dead process should fail")
        } catch {
            // EOF（closed）或写管道失败均可，关键是快速失败而不是悬挂
        }
        await transport.close()
    }

    // MARK: - SIGPIPE 防护
    //
    // 背景：往「读端已关闭」的管道写数据，内核默认投递 SIGPIPE，其默认动作是
    // **终止整个进程**且不打印任何诊断。上面的 test_stdio_processExit_* 因此
    // 间歇性把测试进程静默打死（CI 现场：934 个测试后无任何断言输出、退出码 1）。
    // 最小探针复现 20/20，退出码 141 = 128 + 13。修复见 PipeSafety：
    // init 里对 stdin fd 关掉 SIGPIPE，让 write 抛 EPIPE 走既有 catch。

    /// 机制层回归，**不依赖时序**：管道两端都在本进程手里，关掉读端后写必命中
    /// EPIPE。未设 F_SETNOSIGPIPE 时这一行会raise SIGPIPE 把测试进程打死。
    func test_pipeSafety_disableSIGPIPE_writeThrowsInsteadOfRaisingSignal() throws {
        let pipe = Pipe()
        try? pipe.fileHandleForReading.close()   // 读端消失 → 写端再无读者
        let writeEnd = pipe.fileHandleForWriting
        PipeSafety.disableSIGPIPE(on: writeEnd)
        XCTAssertThrowsError(try writeEnd.write(contentsOf: Data("ping\n".utf8)))
    }

    /// 真代码路径的确定性回归：子进程**关掉自己的 stdin 读端但不退出**
    /// （`exec 0<&-`）——读循环因此永远等不到 EOF（isClosed 保持 false），
    /// 而父进程随后的 write 必定命中「无读者」的管道。未屏蔽 SIGPIPE 时这一行
    /// 直接把测试进程打死（退出码 141）；修复在位时 write 抛 EPIPE、request 快速失败。
    /// 不依赖时序：相比反复构造 /usr/bin/true 打竞态窗口（实测 30 次也打不中），
    /// 这条在拿掉修复后必然杀死测试进程——已变异验证。
    func test_stdio_writeToClosedStdin_neverRaisesSIGPIPE() async throws {
        let transport = try MCPStdioTransport(
            command: "/bin/sh",
            args: ["-c", "exec 0<&-; sleep 30"],
            env: [:],
            useLoginShell: false)
        // 等子进程把 fd 0 关掉：shell 启动是毫秒级，250ms 是充分余量。
        // 即便写赶在关闭之前（数据落进管道缓冲后丢失），也会按 timeout 失败——
        // 两条路径都算「进程活着」，测试依然通过，只是慢一点。
        try await Task.sleep(for: .milliseconds(250))
        do {
            _ = try await transport.request(method: "ping", params: .empty, timeout: 2)
            XCTFail("write to a process that closed its stdin should fail")
        } catch {
            // 预期：EPIPE（写侧，修复在位）或 timeout（写赶在关闭前）。两者都算存活。
        }
        await transport.close()
    }

    // MARK: - SSE 解析（streamable HTTP 响应，纯逻辑）

    func test_parseSSE_matchingID() throws {
        let body = """
        event: message
        data: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}

        """
        let obj = try MCPStreamableHTTPTransport.parseSSE(data: Data(body.utf8), requestID: 7)
        XCTAssertEqual((obj["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func test_parseSSE_multiLineDataConcatenated() throws {
        let body = """
        data: {"jsonrpc":"2.0","id":3,
        data: "result":{"tools":[]}}

        """
        let obj = try MCPStreamableHTTPTransport.parseSSE(data: Data(body.utf8), requestID: 3)
        XCTAssertNotNil(obj["result"])
    }

    func test_parseSSE_skipsNonMatchingEvents() throws {
        // 服务端通知（无 id）与其他 id 的事件都应跳过
        let body = """
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        data: {"jsonrpc":"2.0","id":99,"result":{}}

        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"t"}]}}

        """
        let obj = try MCPStreamableHTTPTransport.parseSSE(data: Data(body.utf8), requestID: 1)
        XCTAssertNotNil(obj["result"])
    }

    func test_parseSSE_noMatch_throws() {
        let body = "data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n\n"
        XCTAssertThrowsError(try MCPStreamableHTTPTransport.parseSSE(data: Data(body.utf8), requestID: 1))
    }

    /// 回归：MCP server 不应继承 app 的完整环境（可能含密钥），只放行运行必需项。
    func test_serverEnvironment_filtersInheritedSecrets() {
        let inherited = [
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
            "CI_TOKEN": "super-secret",
            "AWS_SECRET_ACCESS_KEY": "nope",
        ]
        let env = MCPStdioTransport.serverEnvironment(inherited: inherited, configured: ["MY_VAR": "1"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["MY_VAR"], "1")
        XCTAssertNil(env["CI_TOKEN"], "不得继承 app 环境里的密钥类变量")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
    }

    func test_serverEnvironment_configuredOverridesInherited() {
        let env = MCPStdioTransport.serverEnvironment(
            inherited: ["PATH": "/usr/bin"], configured: ["PATH": "/custom/bin"])
        XCTAssertEqual(env["PATH"], "/custom/bin")
    }
}

// MARK: - MCPClientManagerTests
//
// 覆盖：server 连接失败时优雅降级（工具列表为空、状态记 failed、
// modelFacingNotice 给出模型可见提示），不阻塞整个 run。

@MainActor
final class MCPClientManagerTests: XCTestCase {

    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-mcp-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
    }

    private func writeGlobalConfig(_ content: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("global/mcp.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_refresh_failedServer_degradesGracefully() async throws {
        // 指向一个必然连不上的端口（1 号端口 connection refused，立即失败）
        let globalConfig = try writeGlobalConfig("""
        {"mcpServers": {"dead": {"url": "http://127.0.0.1:1/mcp"}}}
        """)
        let manager = MCPClientManager()

        let tools = await manager.refreshForAgentRun(workspaceURL: nil, globalConfigURL: globalConfig)

        XCTAssertTrue(tools.isEmpty, "失败的 server 不应贡献工具")
        XCTAssertEqual(manager.statuses.count, 1)
        guard case .failed = manager.statuses[0].state else {
            return XCTFail("连接失败应记为 failed，实际：\(manager.statuses[0].state)")
        }
        XCTAssertEqual(manager.statuses[0].kindLabel, "http")
        let notice = try XCTUnwrap(manager.modelFacingNotice, "失败时应生成模型可见提示")
        XCTAssertTrue(notice.contains("dead"))
    }

    func test_refresh_emptyConfig_noServersNoNotice() async throws {
        let globalConfig = try writeGlobalConfig(#"{"mcpServers": {}}"#)
        let manager = MCPClientManager()

        let tools = await manager.refreshForAgentRun(workspaceURL: nil, globalConfigURL: globalConfig)

        XCTAssertTrue(tools.isEmpty)
        XCTAssertTrue(manager.statuses.isEmpty)
        XCTAssertNil(manager.modelFacingNotice)
    }

    func test_reloadConfigSummaries_doesNotConnect() async throws {
        let globalConfig = try writeGlobalConfig("""
        {"mcpServers": {
          "a": {"command": "x"},
          "bad": {"args": "oops"}
        }}
        """)
        let manager = MCPClientManager()

        manager.reloadConfigSummaries(workspaceURL: nil, globalConfigURL: globalConfig)

        XCTAssertEqual(manager.statuses.map(\.name), ["a"])
        guard case .disconnected = manager.statuses[0].state else {
            return XCTFail("摘要加载不应发起连接")
        }
        XCTAssertEqual(manager.configIssues.count, 1, "坏条目应记入 issues")
    }
}
