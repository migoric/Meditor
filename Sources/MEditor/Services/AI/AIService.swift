import Foundation

// MARK: - API key store

/// API Key 存储：macOS Keychain（generic password，复用 Keychain 封装，
/// 与 Gist token / 分享 token 一致）。使用**系统默认 ACL**——item 只信任创建它的
/// 应用（按 code signature）。代价是：签名身份不稳定时（如 ad-hoc 签名，每次构建
/// designated requirement 都是新的 cdhash），升级后 ACL 匹配不上，用户会看到一次
/// 钥匙串授权弹窗；这是有意选择，安全性优先于少弹一次框（见 `Keychain` 的 ACL 策略）。
///
/// 迁移：首次 load 时若发现 UserDefaults 旧明文（"meditor.ai.apiKey"），
/// 写入 Keychain 并删除明文。Keychain 写入失败时降级为进程内内存值并记日志，
/// 保证当前会话可用，不 crash。
enum AIAPIKeyStore {
    private static let legacyDefaultsKey = "meditor.ai.apiKey"
    private static let keychain = Keychain(service: "com.meditor.app.ai", account: "api-key")

    /// Keychain 写入失败时的进程内降级值（不落盘，进程退出即失效）。
    /// save/load/clear 都是 nonisolated static，会被后端异步上下文碰到 ⇒ 必须加锁。
    /// 这与本文件下方 _cachedShellEnv + _shellEnvLock 是同一类问题的同一解法。
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var memoryFallback: String?

    static func save(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { clear(); return }
        // 写路径只写 Keychain；顺手清掉可能残留的旧明文
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        if keychain.save(v) {
            setFallback(nil)
        } else {
            setFallback(v)
            AppLog.ai.error("AIAPIKeyStore: Keychain 写入失败，本次会话仅保留内存值")
        }
    }

    static func load() -> String? {
        if let v = keychain.load(), !v.isEmpty { return v }
        if let v = fallbackLock.withLock({ memoryFallback }), !v.isEmpty { return v }
        // 兼容已装用户：读取旧 UserDefaults 明文并迁移到 Keychain
        guard let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey),
              !legacy.isEmpty else { return nil }
        save(legacy)   // save 内部会删除 legacyDefaultsKey
        return legacy
    }

    static func clear() {
        keychain.clear()
        setFallback(nil)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    /// 降级值的唯一读写口：锁内做「读旧值 + 写新值」，避免两个 nonisolated 上下文
    /// 交错时一个刚 save 成功、另一个又把旧值写回去。
    private static func setFallback(_ value: String?) {
        fallbackLock.withLock { memoryFallback = value }
    }

    static var hasKey: Bool { load() != nil }
}

// MARK: - Client

/// Stateless streaming client. `stream(_:)` yields response text chunks as they
/// arrive. Runs entirely off the main actor.
struct AIClient {
    let config: AIConfig

    /// 进程级共享 session：复用连接池（HTTP/2 多路复用），避免每次聊天请求新建
    /// URLSession 的线程/缓存开销（与 RestAgentBackend.sharedSession 同一思路）。
    /// 细粒度超时在各 request 的 timeoutInterval 上设置。
    private static let sharedSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForResource = 3600   // 兜底上限；请求级超时由 URLRequest 控制
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        switch config.kind {
        case .disabled:   return previewStream()
        case .openai:     return restStream(messages, wire: .openAI)
        case .anthropic:  return restStream(messages, wire: .anthropic)
        case .claudeCLI:  return claudeCLIStream(messages)
        }
    }

    /// Convenience Task-wrapper around `stream()`.
    /// Buffers chunks at ≥ 50 ms intervals, then calls `onChunk` on MainActor.
    /// Fires `onComplete` exactly once with the full text or error.
    @MainActor
    func streamTask(
        _ messages: [AIMessage],
        onChunk: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String?, Error?) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var accumulated = ""
            var buffer      = ""
            var lastFlush   = Date.distantPast
            do {
                for try await chunk in stream(messages) {
                    try Task.checkCancellation()
                    buffer += chunk
                    if Date().timeIntervalSince(lastFlush) > 0.05 {
                        accumulated += buffer
                        onChunk(buffer)
                        buffer    = ""
                        lastFlush = Date()
                    }
                }
                if !buffer.isEmpty {
                    accumulated += buffer
                    onChunk(buffer)
                }
                onComplete(accumulated, nil)
            } catch is CancellationError {
                onComplete(accumulated.isEmpty ? nil : accumulated, nil)
            } catch {
                onComplete(accumulated.isEmpty ? nil : accumulated, error)
            }
        }
    }

    // MARK: Offline preview

    private func previewStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(L("ai.previewReply"))
            continuation.finish()
        }
    }

    // MARK: REST SSE（OpenAI-compatible / Anthropic）

    /// 聊天路径与 Agent 路径共用 RestAgentBackend 的 wire format
    /// （请求构造、认证头、SSE 行解析、429/503 退避——此前手写了三遍，行为已分叉）。
    /// 本方法只保留聊天侧职责：AIMessage → AgentMessage 转换、逐 chunk yield、
    /// 以及流的取消/错误语义（CancellationError 视为正常结束，URLError 包装为 AIError.network）。
    private func restStream(_ messages: [AIMessage], wire: WireProtocol) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let agentMessages = messages.map { msg -> AgentMessage in
                let role: AgentMessage.Role
                switch msg.role {
                case .system:    role = .system
                case .user:      role = .user
                case .assistant: role = .assistant
                }
                return AgentMessage(role: role, content: msg.content)
            }
            // 注入聊天路径的共享 session（waitsForConnectivity = false），
            // 保持与原 openAIStream/anthropicStream 一致的网络行为。
            let backend = RestAgentBackend(config: config, wire: wire, session: Self.sharedSession)
            let task = Task {
                do {
                    _ = try await backend.completeStreaming(
                        messages: agentMessages,
                        tools: []
                    ) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as AIError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AIError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Local Claude CLI

    private func claudeCLIStream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
#if os(macOS)
        AsyncThrowingStream { continuation in
            // Box lets the termination closure reach the process after it starts.
            // 用带锁的盒子：watchdog / onTermination 可能在任意线程读写，
            // 裸 var 会数据竞争，且「取消早于进程赋值」时会落空产生孤儿 claude 进程。
            let box = LockedProcessBox()

            let task = Task.detached {
                do {
                    guard !config.cliPath.isEmpty else { throw AIError.notConfigured }
                    guard FileManager.default.isExecutableFile(atPath: config.cliPath) else {
                        throw AIError.cliNotFound(config.cliPath)
                    }

                    // system 与对话必须分开送：system 走 --system-prompt（真正的 system 位），
                    // 对话走 stdin。此前把两者拼成一条 user 文本喂进去，真正的 system 位
                    // 仍是 Claude Code 自己的 prompt（"你是 Claude Code，你有 Write/Bash…"），
                    // 模型因此会在「CLI 自带工具」和 MEditor 的 XML 工具协议之间摇摆。
                    let systemContent = messages
                        .filter { $0.role == .system }
                        .map(\.content)
                        .joined(separator: "\n\n")
                    // Compose the conversation (system 已单独送，见上).
                    let prompt = messages
                        .filter { $0.role != .system }
                        .map { m -> String in
                            switch m.role {
                            case .system:    return m.content   // 已被上面滤掉，仅为穷尽性
                            case .user:      return "User: \(m.content)"
                            case .assistant: return "Assistant: \(m.content)"
                            }
                        }
                        .joined(separator: "\n\n")

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: config.cliPath)
                    // `-p` = print mode (non-interactive). The prompt is fed via
                    // stdin (not argv) so content starting with "-"/"---" isn't
                    // mis-parsed as a CLI option.
                    // stream-json + --verbose + --include-partial-messages：边生成边
                    // 输出 JSONL 事件（text_delta 增量 / assistant 快照 / result 终态），
                    // agent 与聊天路径的 UI 都能增量渲染，不再干等整段回复。
                    // `--tools ""` 关掉 Claude Code 的全部内建工具（Write / Edit / Bash / Read…）。
                    // 这些工具一旦被调用，MEditor 只会从 stream-json 里收到一个 tool_use 块
                    // 和一条 is_error 的 tool_result（"requested permissions to write … but
                    // you haven't granted it yet"）——MEditor 既不解析它们，也没有实现
                    // SDK 的 can_use_tool 控制协议（而且 stdin 写完就 close 了）
                    // ⇒ 权限请求无处投递，用户在面板里看不到任何审批按钮，动作也不会发生。
                    // 关掉工具后 CLI 退化为纯文本模型，一切动作只能走 MEditor 的
                    // <tool_call> 协议，审批重新回到确认条 / diff 审阅。
                    var args = ["-p", "--output-format", "stream-json", "--verbose",
                                "--include-partial-messages", "--tools", ""]
                    // `--system-prompt` 把 MEditor 的 system（含工具协议）放进真正的 system 位。
                    // 实测：只加 `--tools ""`、协议仍留在 stdin 文本里时，模型会改用自家
                    // DSML 标记（<｜｜DSML｜｜ invoke …>），<tool_call> 命中 0 次 ⇒ 工具调用
                    // 整轮丢失、同样看不到审批。两件必须一起做。
                    // 版本兼容：`--system-prompt` 比这条流式路径依赖的
                    // `--include-partial-messages` 更早存在，能跑通现有路径的 CLI 必然支持它。
                    if !systemContent.isEmpty { args += ["--system-prompt", systemContent] }
                    // 设置页的 CLI 模型选择（aiCLIModel）；空则用 CLI 默认模型
                    if !config.cliModel.isEmpty { args += ["--model", config.cliModel] }
                    process.arguments = args

                    // GUI 应用不继承 shell 环境，需要从 login shell 读取关键变量
                    // （包括 ANTHROPIC_BASE_URL 等自定义代理地址）
                    var env = ProcessInfo.processInfo.environment
                    let home = FileManager.default.homeDirectoryForCurrentUser.path

                    // 从 login shell 读取完整环境（包含 .zshrc/.bashrc 里的配置）
                    if let shellEnv = Self.loginShellEnvironment() {
                        for (key, value) in shellEnv {
                            env[key] = value
                        }
                    }

                    // 额外补充常见安装路径
                    let extra = [
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                        "\(home)/.local/bin", "\(home)/.bun/bin",
                        "\(home)/.npm-global/bin", "\(home)/.volta/bin",
                        "\(home)/.nvm/current/bin"
                    ]
                    let current = env["PATH"] ?? ""
                    env["PATH"] = (extra + (current.isEmpty ? [] : [current])).joined(separator: ":")
                    process.environment = env

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    let inPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = inPipe

                    try Task.checkCancellation()
                    try process.run()
                    box.process = process
                    // 与 MCPStdioTransport 同一类隐患：CLI 若在写入前就退出，往 stdin
                    // 写会触发 SIGPIPE 直接打死整个 app。这里紧跟 run() 无 await，窗口
                    // 比 MCP 传输窄得多，但代价一样是静默死亡，一行 fcntl 换掉。
                    PipeSafety.disableSIGPIPE(on: inPipe.fileHandleForWriting)

                    // Feed the prompt via stdin, then close it so the CLI proceeds.
                    if let data = prompt.data(using: .utf8) {
                        inPipe.fileHandleForWriting.write(data)
                    }
                    try? inPipe.fileHandleForWriting.close()

                    // stdout 增量行读：stream-json 每行一个事件，解析出文本增量即上抛。
                    // stderr 并发整读：顺序读会在子进程向 stderr 写满管道缓冲（64KB）
                    // 时死锁——进程阻塞在 stderr 写，stdout 永远等不到 EOF。
                    // 进程退出/被 terminate 后管道关闭，bytes.lines 序列自然结束。
                    async let errRead = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let parseTask = Task.detached { () -> ClaudeStreamJSONParser in
                        var parser = ClaudeStreamJSONParser()
                        do {
                            for try await line in outPipe.fileHandleForReading.bytes.lines {
                                if let chunk = parser.ingest(line: line) {
                                    continuation.yield(chunk)
                                }
                            }
                        } catch {
                            // 读取中断（如 terminate 关闭管道）：成败由下方退出状态判断
                        }
                        return parser
                    }

                    // 请求级超时哨兵：超时后 terminate（SIGTERM 关闭管道，解除
                    // waitUntilExit / bytes.lines 的阻塞）。主流程结束后
                    // cancel 哨兵，正常退出不触发超时。
                    let watchdog = Task.detached {
                        try? await Task.sleep(for: .seconds(config.cliTimeoutSeconds))
                        guard !Task.isCancelled else { return }
                        if process.isRunning {
                            box.timedOut = true
                            process.terminate()
                        }
                    }
                    process.waitUntilExit()
                    watchdog.cancel()
                    let parser = await parseTask.value
                    let errData = await errRead

                    if Task.isCancelled { continuation.finish(); return }

                    if box.timedOut {
                        throw AIError.cliFailed(L("ai.error.cliTimeout", Int(config.cliTimeoutSeconds)))
                    }

                    if process.terminationStatus != 0 {
                        let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                        throw AIError.cliFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    // 退出码为 0 但 result 事件标记失败（如 API 鉴权错误走 JSONL 回传）
                    if let cliError = parser.resultError {
                        throw AIError.cliFailed(cliError)
                    }
                    // CLI 侧工具被拒 / 失败：附在文本尾部透出，不能让用户只能看到模型
                    // 自己说「等待授权」而界面上什么都没有。
                    if let notice = parser.toolErrorNotice {
                        continuation.yield("\n\n⚠️ \(L("ai.error.cliToolBlocked", notice))")
                    }
                    continuation.finish()
                } catch let e as AIError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AIError.cliFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.terminate()
            }
        }
#else
        // iOS 无 Process 子进程能力：claude CLI 流式路径在移动端不可用
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIError.cliFailed(L("ai.error.cliMacOnly")))
        }
#endif
    }
}

// MARK: - Login shell environment

extension AIClient {
    /// 通过 login shell 获取用户完整环境变量。
    /// GUI 应用不继承 .zshrc/.profile，主要用于读取
    /// ANTHROPIC_BASE_URL、ANTHROPIC_AUTH_TOKEN 等自定义代理配置。
    ///
    /// 结果在进程生命周期内只采集一次（shell 环境在运行时不会改变），
    /// 后续调用直接返回缓存，避免每次 AI 对话都 spawn 子进程。
    static func loginShellEnvironment() -> [String: String]? {
        // 先不加锁读一次：缓存已就绪的情况直接返回，零开销。
        _shellEnvLock.lock()
        if let cached = _cachedShellEnv { _shellEnvLock.unlock(); return cached }
        _shellEnvLock.unlock()

        // 加锁后再检查一次（防止并发双入口），然后采集并缓存。
        _shellEnvLock.lock()
        defer { _shellEnvLock.unlock() }
        if let cached = _cachedShellEnv { return cached }   // double-checked
        let env = _collectShellEnvironment()
        _cachedShellEnv = env
        return env
    }

    // MARK: Private

    /// 进程级缓存，避免重复 spawn login shell。
    nonisolated(unsafe) private static var _cachedShellEnv: [String: String]? = nil
    /// 保护 _cachedShellEnv 首次并发写入。
    private static let _shellEnvLock = NSLock()

    private static func _collectShellEnvironment() -> [String: String]? {
#if os(macOS)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "env"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()   // 丢弃 stderr
        guard (try? p.run()) != nil else { return nil }
        // 先并发 drain 管道再 waitUntilExit：环境变量超过管道缓冲（~64KB）时，
        // 子进程会阻塞在写端，若先 waitUntilExit 会永久死锁——而这里还持有着
        // _shellEnvLock（defer 无法执行），会导致后续所有 CLI 调用一起卡死。
        // readDataToEndOfFile 读到 EOF（子进程退出关闭管道）才返回，等效于等待退出。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex ..< eq])
            let value = String(line[line.index(after: eq)...])
            result[key] = value
        }
        return result.isEmpty ? nil : result
#else
        // iOS 无 Process：无法 spawn login shell，返回 nil（调用方仅用于 CLI 场景）
        return nil
#endif
    }
}

// MARK: - Discovery helpers

extension AIClient {

#if os(macOS)
    /// Claude CLI 连接自检：真实发送一条 "hi"（30s 超时，走 stream-json 路径）。
    /// 成功返回 nil；失败返回错误文案（复用 AIError 分类描述）。
    /// 设置页「连接测试」与首启引导的就绪校验共用此入口。
    static func testClaudeCLI(cliPath: String, cliModel: String) async -> String? {
        let config = AIConfig(
            kind: .claudeCLI,
            baseURL: "",
            model: "",
            cliPath: cliPath,
            cliModel: cliModel,
            apiKey: "",
            requestTimeoutSeconds: 30,
            cliTimeoutSeconds: 30
        )
        do {
            for try await _ in AIClient(config: config).stream([AIMessage(role: .user, content: "hi")]) {}
            return nil
        } catch let e as AIError {
            return e.errorDescription ?? e.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }
#endif

    /// Fetches available model IDs from an OpenAI-compatible `/models` endpoint.
    /// Returns an empty array on any failure (caller falls back to manual entry).
    static func fetchModels(baseURL: String, apiKey: String) async -> [String] {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return [] }
        let endpoint = base.hasSuffix("/") ? base + "models" : base + "/models"
        guard let url = URL(string: endpoint) else { return [] }

        var req = URLRequest(url: url)
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return [] }
            return arr.compactMap { $0["id"] as? String }.sorted()
        } catch {
            return []
        }
    }

    /// Best-effort detection of the local `claude` CLI: a login shell lookup
    /// first, then a scan of common install locations. Returns an absolute path.
    static func detectClaudeCLI() async -> String? {
#if os(macOS)
        if let p = await loginShellWhich("claude"),
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
#else
        // iOS 无 CLI：直接视为未安装
        return nil
#endif
    }

    private static func loginShellWhich(_ tool: String) async -> String? {
#if os(macOS)
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: shell)
                p.arguments = ["-lc", "command -v \(tool)"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit() }
                catch { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (out?.isEmpty == false) ? out : nil)
            }
        }
#else
        // iOS 无 Process：直接视为未找到
        return nil
#endif
    }
}

// MARK: - LockedProcessBox

#if os(macOS)
/// 线程安全的 Process 持有盒（与 RunCommandTool.ProcessBox 同款思路）。
///
/// watchdog / `continuation.onTermination` 可能在任意线程读写，裸 `var` 是数据竞争；
/// `killRequested` 关闭「终止请求早于进程赋值」的窗口——赋值时补发 terminate，
/// 避免取消后 claude 子进程变成孤儿。`timedOut` 同样加锁，读取不会拿到脏值。
/// 仅在 macOS 编译：iOS 无 `Process`（claude CLI 路径本身也是 macOS-only）。
private final class LockedProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _process: Process?
    private var _timedOut = false
    private var killRequested = false

    var process: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _process }
        set {
            lock.lock()
            _process = newValue
            let shouldKill = killRequested
            lock.unlock()
            if shouldKill { newValue?.terminate() }
        }
    }

    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }

    /// 请求终止子进程；进程尚未就绪时先记账，赋值时补发（重复调用无害）。
    func terminate() {
        lock.lock()
        killRequested = true
        let p = _process
        lock.unlock()
        p?.terminate()
    }
}
#endif
