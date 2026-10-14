import Foundation

// MARK: - MCP Server（协议分发层 + stdio 传输循环 + CLI 入口）
//
// 分层：
//   MCPJSONRPC          —— 一行文本 ↔ 结构化消息（纯逻辑）
//   MCPToolCatalog      —— 工具筛选与 tools/list schema 生成（纯逻辑）
//   MCPHeadlessContext  —— 工具执行上下文（无头，工作区固定）
//   MCPServer           —— 消息分发（纯逻辑，handleLine 可单测）
//   MCPServer.runStdioLoop / MCPCommand —— stdio 传输与进程入口

final class MCPServer {

    /// 服务端支持的 MCP 协议版本（initialize 响应中声明）。
    static let protocolVersion = "2025-06-18"

    let context: MCPHeadlessContext
    let tools: [any AgentTool]
    /// initialize 响应的 serverInfo.version；取 app bundle 版本，裸二进制（swift build）降级 "dev"。
    let serverVersion: String

    init(workspaceRoot: URL, allowWarnCommands: Bool = false,
         allowShell: Bool = false, tools: [any AgentTool]? = nil) {
        self.context = MCPHeadlessContext(workspaceRoot: workspaceRoot, allowWarnCommands: allowWarnCommands)
        self.tools = tools ?? MCPToolCatalog.headlessTools(allowShell: allowShell)
        self.serverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - 消息分发（纯逻辑：输入一行，输出可选响应行）

    /// 处理一行 stdio 输入。返回需写回 stdout 的响应行；通知与无需回包的场景返回 nil。
    func handleLine(_ line: String) async -> String? {
        let message: MCPMessage
        switch MCPJSONRPC.parse(line: line) {
        case .failure(let error):
            // 解析失败时 id 不可知，按规范回 id: null
            return MCPJSONRPC.serialize(MCPJSONRPC.errorObject(id: nil, code: error.code, message: error.message))
        case .success(let m):
            message = m
        }

        // 通知（无 id，如 notifications/initialized）：吞掉，不回包
        guard let id = message.id else { return nil }

        switch message.method {
        case "initialize":
            return MCPJSONRPC.serialize(MCPJSONRPC.resultObject(id: id, result: initializeResult()))
        case "ping":
            return MCPJSONRPC.serialize(MCPJSONRPC.resultObject(id: id, result: [:]))
        case "tools/list":
            return MCPJSONRPC.serialize(
                MCPJSONRPC.resultObject(id: id, result: MCPToolCatalog.toolsListResult(tools: tools)))
        case "tools/call":
            return await handleToolCall(id: id, params: message.params)
        default:
            return MCPJSONRPC.serialize(MCPJSONRPC.errorObject(
                id: id, code: MCPJSONRPC.methodNotFoundCode,
                message: "Method not found: \(message.method)"))
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": Self.protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "MEditor", "version": serverVersion],
        ]
    }

    // MARK: - tools/call

    private func handleToolCall(id: MCPRequestID, params: [String: AnySendableValue]) async -> String {
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            return MCPJSONRPC.serialize(MCPJSONRPC.errorObject(
                id: id, code: MCPJSONRPC.invalidParamsCode, message: "Invalid params: missing tool name"))
        }
        guard let tool = tools.first(where: { $0.spec.name == name }) else {
            return MCPJSONRPC.serialize(MCPJSONRPC.errorObject(
                id: id, code: MCPJSONRPC.invalidParamsCode, message: "Invalid params: unknown tool '\(name)'"))
        }
        var arguments: [String: AnySendableValue] = [:]
        if case .dict(let d)? = params["arguments"] { arguments = d }

        // warn 级命令前置拦截：无头模式没有 UI 确认，默认拒绝并说明原因与开关
        // （MCPHeadlessContext.confirmCommandExecution 里还有一层兜底）。
        if name == "run_command",
           let command = arguments["command"]?.stringValue,
           case .warn = CommandSandbox.assess(command),
           !context.allowWarnCommands {
            MCPLog.info("rejected warn-level command (pass --allow-warn-commands to enable): \(command)")
            return toolResultJSON(id: id, isError: true, text: """
            [!] Refused in MCP headless mode: this command is rated WARN by MEditor's command sandbox \
            and warn-level commands are disabled without an interactive confirmation UI. \
            Restart the server with `mcp --allow-warn-commands` to allow them. Command: \(command)
            """)
        }

        do {
            // 参数运行时校验（required/类型/enum）：外部客户端（Claude Desktop 等）
            // 生成的参数同样会类型错乱，失败以 isError 结果回返让客户端自纠，
            // 与 AgentRunner 内部调用共用同一把尺子。
            if let violation = tool.validateArguments(arguments) {
                return toolResultJSON(id: id, isError: true, text: violation)
            }
            let output = try await tool.execute(arguments: arguments, context: context)
            return toolResultJSON(id: id, isError: false, text: output)
        } catch {
            // 工具执行失败是工具结果（isError），不是协议错误
            return toolResultJSON(id: id, isError: true, text: "[!] \(error.localizedDescription)")
        }
    }

    private func toolResultJSON(id: MCPRequestID, isError: Bool, text: String) -> String {
        var result: [String: Any] = ["content": [["type": "text", "text": text] as [String: Any]]]
        if isError { result["isError"] = true }
        return MCPJSONRPC.serialize(MCPJSONRPC.resultObject(id: id, result: result))
    }
}

// MARK: - stdio 传输循环

extension MCPServer {
    /// stdio 会话循环：逐行读 stdin，响应写 stdout（每条一行 JSON），EOF 结束进程。
    /// readLine 是阻塞调用，放 detached 任务里读，协议处理留在当前上下文中，
    /// 保证 @MainActor 的工具上下文（MCPHeadlessContext）可以正常调度。
    func runStdioLoop() async -> Int32 {
        MCPLog.info("session started (protocol \(Self.protocolVersion), workspace: \(context.workspaceRoot.path))")
        while true {
            let line = await Task.detached(priority: .userInitiated) { () -> String? in
                readLine(strippingNewline: true)
            }.value
            guard let line else { break }   // stdin EOF：客户端关闭会话
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let response = await handleLine(line) {
                if let data = (response + "\n").data(using: .utf8) {
                    FileHandle.standardOutput.write(data)
                }
            }
        }
        MCPLog.info("session ended (stdin EOF)")
        return 0
    }
}

// MARK: - CLI 入口（MEditor mcp [--workspace <path>] [--allow-warn-commands]）

enum MCPCommand {

    /// 是否应接管进程。在 App 启动最早期（MEditorApp.init）判断，
    /// 命中则走纯 CLI 路径，不启动 AppKit / SwiftUI。
    static func shouldRun(arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == "mcp"
    }

    static let usage = """
    Usage: MEditor mcp [--workspace <path>] [--allow-warn-commands] [--allow-shell]

    Starts an MCP server over stdio (newline-delimited JSON-RPC 2.0) exposing
    MEditor's agent tools against a fixed workspace directory.

      --workspace <path>        Workspace root directory (default: current directory).
      --allow-warn-commands     Allow WARN-level shell commands (e.g. git push, mv).
                                Disabled by default in headless mode; BLOCKED-level
                                commands are always rejected.
      --allow-shell             Expose the run_command tool at all. Disabled by default:
                                headless mode cannot show a confirmation dialog, so the
                                static command blocklist is not a security boundary.
    """

    /// 解析参数并运行 stdio 会话，直到 stdin EOF。返回进程退出码。
    static func run(arguments: [String]) async -> Int32 {
        var workspacePath: String?
        var allowWarn = false
        var allowShell = false
        var i = 2   // arguments[0] = 可执行文件，[1] = "mcp"
        while i < arguments.count {
            switch arguments[i] {
            case "--workspace":
                if i + 1 < arguments.count {
                    workspacePath = arguments[i + 1]
                    i += 1
                } else {
                    MCPLog.info("--workspace requires a path argument")
                    return 2
                }
            case "--allow-warn-commands":
                allowWarn = true
            case "--allow-shell":
                allowShell = true
            case "--help", "-h":
                MCPLog.info("\n\(usage)")
                return 0
            default:
                MCPLog.info("unknown argument: \(arguments[i])\n\(usage)")
                return 2
            }
            i += 1
        }

        let root: URL
        if let workspacePath {
            root = URL(fileURLWithPath: (workspacePath as NSString).expandingTildeInPath)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            MCPLog.info("workspace does not exist or is not a directory: \(root.path)")
            return 2
        }
        if allowWarn {
            MCPLog.info("WARN-level shell commands are ENABLED for this session")
        }
        if !allowShell {
            MCPLog.info("run_command is NOT exposed (pass --allow-shell to enable)")
        }

        let server = MCPServer(workspaceRoot: root, allowWarnCommands: allowWarn, allowShell: allowShell)
        return await server.runStdioLoop()
    }
}
