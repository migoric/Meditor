import XCTest
@testable import MEditor

// MARK: - ClaudeCLIClientInvocationTests
//
// 守住「claude CLI 只当模型用」这条约定。
//
// 背景（实测，claude 2.1.278）：MEditor 原来只传
// `-p --output-format stream-json --verbose --include-partial-messages`，于是 CLI 带着
// 自己的 Write / Edit / Bash 启动。模型一旦用它们，CLI 会回一条 is_error 的 tool_result
// （"requested permissions … but you haven't granted it yet"），而 MEditor 既不解析这类
// 事件、也没有实现 can_use_tool 控制协议（stdin 写完就 close）⇒ 审批请求无处投递，
// 用户在面板里看不到任何按钮，动作也不会发生。
// 只加 `--tools ""` 不够：协议留在 stdin 文本里时模型会改用自家 DSML 标记，
// `<tool_call>` 命中 0 次、工具调用整轮丢失。必须同时把协议送进 system 位。
//
// 这里用一个假 CLI（shell 脚本）记录真实 argv，验证两件事都还在。

final class ClaudeCLIClientInvocationTests: XCTestCase {

    /// 写一个把 argv 逐行落盘、把 stdin 整读落盘、再输出合法 result 事件的假 claude。
    private func makeStub() throws -> (dir: URL, cliPath: String, argsFile: URL, stdinFile: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meditor-cli-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let argsFile = dir.appendingPathComponent("args.txt")
        let stdinFile = dir.appendingPathComponent("stdin.txt")
        let cli = dir.appendingPathComponent("claude")
        // 每个参数单独一行（空串也会落成空行）；再整读 stdin（MEditor 写完 prompt 会关掉它）。
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > "\(argsFile.path)"
        cat > "\(stdinFile.path)"
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (dir, cli.path, argsFile, stdinFile)
    }

    private func config(cliPath: String) -> AIConfig {
        AIConfig(
            kind: .claudeCLI,
            baseURL: "",
            model: "",
            cliPath: cliPath,
            cliModel: "",
            apiKey: "",
            requestTimeoutSeconds: 30,
            cliTimeoutSeconds: 30
        )
    }

    func test_argv_disablesBuiltinToolsAndUsesSystemPrompt() async throws {
        let stub = try makeStub()
        defer { try? FileManager.default.removeItem(at: stub.dir) }

        var out = ""
        for try await chunk in AIClient(config: config(cliPath: stub.cliPath)).stream([
            AIMessage(role: .system, content: "SYS-PROMPT"),
            AIMessage(role: .user,   content: "hello")
        ]) {
            out += chunk
        }
        XCTAssertEqual(out, "ok", "假 CLI 的 result 事件应被正常解析")

        let args = try String(contentsOf: stub.argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // 1) 内建工具必须全关（`--tools` 后紧跟空串）
        guard let toolsIndex = args.firstIndex(of: "--tools") else {
            return XCTFail("必须传 --tools，否则 CLI 自带 Write/Edit/Bash 会绕过 MEditor 的审批")
        }
        XCTAssertEqual(args[toolsIndex + 1], "", "--tools 的值必须是空串（关掉全部内建工具）")

        // 2) system 必须走 --system-prompt（真正的 system 位），不能混进 stdin 文本
        guard let sysIndex = args.firstIndex(of: "--system-prompt") else {
            return XCTFail("必须用 --system-prompt 送协议，否则模型会改用 DSML 等自家标记")
        }
        XCTAssertEqual(args[sysIndex + 1], "SYS-PROMPT")

        // 3) 对话仍走 stdin，且 system 不再重复出现在里面
        let stdin = try String(contentsOf: stub.stdinFile, encoding: .utf8)
        XCTAssertTrue(stdin.contains("User: hello"), "对话内容应经 stdin 送入")
        XCTAssertFalse(stdin.contains("SYS-PROMPT"), "system 不应再被拼进 stdin 的对话文本")

        // 4) 空的 cliModel 不应产生 --model
        XCTAssertFalse(args.contains("--model"))
    }
}
