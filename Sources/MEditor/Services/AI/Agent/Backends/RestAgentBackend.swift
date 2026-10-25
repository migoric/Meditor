import Foundation
import OSLog

// MARK: - Disabled Backend

struct DisabledBackend: AgentBackend {
    func complete(messages: [AgentMessage], tools: [any AgentTool]) async throws -> AgentCompletionResponse {
        AgentCompletionResponse(text: "AI 未配置，请在设置中启用", toolCalls: [], finishReason: "stop")
    }
}

// MARK: - Wire Protocol

/// HTTP 请求/响应的 wire 格式。
/// 新增 provider 只需在 AIPresets 里加条目并选择对应协议——Backend 代码不动。
enum WireProtocol: Sendable {
    case openAI     // POST /chat/completions  （覆盖 OpenAI / Ollama / OpenRouter / 各类代理）
    case anthropic  // POST /messages          （api.anthropic.com 直连 & 兼容实现）
}

// MARK: - REST Agent Backend

/// 统一 HTTP Backend，通过 WireProtocol 适配两种主流 API 格式。
/// 替代原 OpenAIBackend，同时承载 Anthropic 原生支持。
struct RestAgentBackend: AgentBackend {

    let config: AIConfig
    let wire: WireProtocol

    /// 可注入的 URLSession（测试用）。nil 时使用进程级共享 session（复用连接池）。
    let sessionOverride: (any URLSessionDataProtocol)?

    /// 429/5xx 重试的初始退避间隔（纳秒），每次重试翻倍。可注入（测试用），默认 1s。
    let retryBaseDelayNs: UInt64

    init(config: AIConfig, wire: WireProtocol, session: (any URLSessionDataProtocol)? = nil,
         retryBaseDelayNs: UInt64 = 1_000_000_000) {
        self.config = config
        self.wire = wire
        self.sessionOverride = session
        self.retryBaseDelayNs = retryBaseDelayNs
    }

    /// 进程级共享 session：复用连接池（HTTP/2 多路复用），避免每次请求新建
    /// URLSession 的线程/缓存开销。细粒度超时在各 request 的 timeoutInterval 上设置。
    private static let sharedSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForResource = 3600   // 兜底上限；请求级超时由 URLRequest 控制
        return URLSession(configuration: c)
    }()

    /// 返回实际使用的 session：有注入时用注入的，否则用共享 session。
    var resolvedSession: any URLSessionDataProtocol { sessionOverride ?? Self.sharedSession }

    /// SSE 解析诊断日志（畸形行计数等）。subsystem 与 AppLog 一致。
    private static let logger = Logger(subsystem: "com.meditor.app", category: "agent")

    // MARK: - AgentBackend

    func complete(
        messages: [AgentMessage],
        tools: [any AgentTool]
    ) async throws -> AgentCompletionResponse {
        guard config.isConfigured else { throw AIError.notConfigured }
        let req = try buildRequest(messages: messages, tools: tools)
        return try await withRetry {
            let (data, response) = try await resolvedSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network("Invalid response type")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "(empty)"
                throw AIError.server(http.statusCode, String(body.prefix(500)))   // 与流式路径一致，截断 ~500 字符
            }
            return try self.parseResponse(data: data)
        }
    }

    // MARK: - Retry helper（429 / 5xx 指数退避，最多重试 2 次）

    /// 可重试的服务端状态码：429（限流）/ 503（过载）之外补上 500 / 502 / 504——
    /// 网关与负载均衡后的临时故障同样常以这些码返回，重试一次大概率即恢复；
    /// 400/401/403/404/422 等确定性错误不重试（原样抛出，见下方 catch）。
    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    private func withRetry<T: Sendable>(
        maxAttempts: Int = 3,
        _ block: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delayNs: UInt64 = retryBaseDelayNs
        for attempt in 1...maxAttempts {
            do {
                return try await block()
            } catch AIError.server(let code, let body) where Self.retryableStatusCodes.contains(code) && attempt < maxAttempts {
                // 保留真实错误（含响应体）：走到耗尽分支时抛出的必须是真实错误，
                // 不能换成 "retrying" 占位文案把可重试状态码的 body 丢掉
                lastError = AIError.server(code, body)
                // 退避期间任务被取消：Task.sleep 会抛 CancellationError 并向上传播
                // （不用 try?，否则会吞掉取消信号，退避结束后仍会再发一次请求）。
                try await Task.sleep(nanoseconds: delayNs)
                delayNs *= 2
            } catch {
                throw error
            }
        }
        throw lastError ?? AIError.network("retry exhausted")
    }

    // MARK: - Streaming

    func completeStreaming(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        guard config.isConfigured else { throw AIError.notConfigured }
        switch wire {
        case .openAI:    return try await streamOpenAI(messages: messages, tools: tools, onTextChunk: onTextChunk)
        case .anthropic: return try await streamAnthropic(messages: messages, tools: tools, onTextChunk: onTextChunk)
        }
    }

    private func streamOpenAI(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        let req = try openAIRequest(messages: messages, tools: tools, stream: true)
        // 建连/首响应阶段纳入 429/5xx 重试；拿到 2xx 开始消费事件流后不再重试（避免重复输出）
        let bytes = try await withRetry {
            let (bytes, response) = try await resolvedSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw AIError.network("invalid response") }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 500 { break } }
                throw AIError.server(http.statusCode, body)
            }
            return bytes
        }

        struct ToolCallAcc { var id = ""; var name = ""; var args = "" }
        var accText = ""
        var toolByIndex: [Int: ToolCallAcc] = [:]
        var finishReason = "stop"
        var malformedCount = 0   // 解析失败的 data 行计数，流结束后统一记录
        /// 流式 usage（需请求时带 stream_options.include_usage）：末帧 choices 为空、仅携带累计用量
        var usage: AgentUsage? = nil

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                malformedCount += 1
                continue
            }

            // 先取 usage：include_usage 的末帧没有 choices，不能落入下方畸形行计数
            if let usageObj = obj["usage"] as? [String: Any] {
                // OpenAI prompt caching 是服务端自动的（>1024 tokens），命中部分在
                // prompt_tokens_details.cached_tokens 里回传；不支持的实现没有该字段，默认 0
                let cached = (usageObj["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                usage = AgentUsage(
                    promptTokens:     usageObj["prompt_tokens"]     as? Int ?? 0,
                    completionTokens: usageObj["completion_tokens"] as? Int ?? 0,
                    cacheReadTokens:  cached
                )
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                if usage != nil { continue }   // 正常 usage 末帧
                malformedCount += 1
                continue
            }

            if let fr = choice["finish_reason"] as? String, fr != "null", !fr.isEmpty {
                finishReason = fr
            }
            let delta = choice["delta"] as? [String: Any]

            if let content = delta?["content"] as? String, !content.isEmpty {
                accText += content
                onTextChunk(content)
            } else if let message = choice["message"] as? [String: Any],
                      let content = message["content"] as? String, !content.isEmpty {
                // 某些代理会在最后一帧发送完整 message（原 AIClient.decodeDelta 的兼容行为；
                // 聊天路径收拢复用本实现后，两路统一保留）
                accText += content
                onTextChunk(content)
            }
            if let tcs = delta?["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    guard let index = tc["index"] as? Int else { continue }
                    var acc = toolByIndex[index] ?? ToolCallAcc()
                    if let id = tc["id"] as? String { acc.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { acc.name = name }
                        if let args = fn["arguments"] as? String { acc.args += args }
                    }
                    toolByIndex[index] = acc
                }
            }
        }

        let toolCalls = toolByIndex.sorted { $0.key < $1.key }.compactMap { _, acc -> AgentToolCall? in
            guard !acc.id.isEmpty, !acc.name.isEmpty else { return nil }
            return AgentToolCall(id: acc.id, name: acc.name, argumentsJSON: acc.args.isEmpty ? "{}" : acc.args)
        }
        if malformedCount > 0 {
            Self.logger.debug("OpenAI SSE: skipped \(malformedCount) malformed data line(s)")
        }
        return AgentCompletionResponse(text: accText, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    private func streamAnthropic(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        let req = try anthropicRequest(messages: messages, tools: tools, stream: true)
        // 建连/首响应阶段纳入 429/5xx 重试；拿到 2xx 开始消费事件流后不再重试（避免重复输出）
        let bytes = try await withRetry {
            let (bytes, response) = try await resolvedSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw AIError.network("invalid response") }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 500 { break } }
                throw AIError.server(http.statusCode, body)
            }
            return bytes
        }

        struct ToolUseAcc { var id = ""; var name = ""; var inputJSON = "" }
        var accText = ""
        var toolByIndex: [Int: ToolUseAcc] = [:]
        var stopReason = "end_turn"
        var malformedCount = 0   // 解析失败的 data 行计数，流结束后统一记录
        /// 流式 usage：message_start 带 input_tokens（及初始 output_tokens），
        /// 各 message_delta 带累计 output_tokens（直接覆盖，不累加）。
        /// 缓存量（cache_read/cache_creation）随 message_start 的 usage 回传。
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        var cacheReadTokens = 0
        var cacheWriteTokens = 0

        for try await line in bytes.lines {
            // Anthropic SSE: ignore event lines, only parse data lines
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                malformedCount += 1
                continue
            }

            switch type {
            case "message_start":
                // 首帧携带 usage.input_tokens（prompt 用量）及缓存命中/写入量
                if let message = obj["message"] as? [String: Any],
                   let usageObj = message["usage"] as? [String: Any] {
                    inputTokens  = usageObj["input_tokens"]  as? Int ?? inputTokens
                    outputTokens = usageObj["output_tokens"] as? Int ?? outputTokens
                    cacheReadTokens  = usageObj["cache_read_input_tokens"]      as? Int ?? cacheReadTokens
                    cacheWriteTokens = usageObj["cache_creation_input_tokens"]  as? Int ?? cacheWriteTokens
                }

            case "content_block_start":
                guard let index = obj["index"] as? Int,
                      let block = obj["content_block"] as? [String: Any],
                      let blockType = block["type"] as? String,
                      blockType == "tool_use" else { continue }
                var acc = ToolUseAcc()
                acc.id   = block["id"]   as? String ?? ""
                acc.name = block["name"] as? String ?? ""
                toolByIndex[index] = acc

            case "content_block_delta":
                guard let index = obj["index"] as? Int,
                      let delta = obj["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    accText += text
                    onTextChunk(text)
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String {
                    toolByIndex[index]?.inputJSON += partial
                }

            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
                // message_delta.usage.output_tokens 是累计值，逐帧覆盖即可
                if let usageObj = obj["usage"] as? [String: Any] {
                    if let out = usageObj["output_tokens"] as? Int {
                        outputTokens = out
                    }
                    // 部分实现会把缓存量延迟到 message_delta 才回传，顺手覆盖
                    cacheReadTokens  = usageObj["cache_read_input_tokens"]     as? Int ?? cacheReadTokens
                    cacheWriteTokens = usageObj["cache_creation_input_tokens"] as? Int ?? cacheWriteTokens
                }

            case "error":
                // 流中途的 error 事件（如 overloaded_error）不能当畸形行静默跳过：
                // 解析 message 作为正常错误抛出，让用户可见
                let errObj = obj["error"] as? [String: Any]
                let message = errObj?["message"] as? String ?? "unknown stream error"
                throw AIError.server(0, message)

            case "ping":
                break   // 保活帧，忽略

            default: break
            }
        }

        let toolCalls = toolByIndex.sorted { $0.key < $1.key }.compactMap { _, acc -> AgentToolCall? in
            guard !acc.id.isEmpty, !acc.name.isEmpty else { return nil }
            return AgentToolCall(id: acc.id, name: acc.name, argumentsJSON: acc.inputJSON.isEmpty ? "{}" : acc.inputJSON)
        }
        if malformedCount > 0 {
            Self.logger.debug("Anthropic SSE: skipped \(malformedCount) malformed data line(s)")
        }
        let finishReason = Self.mapAnthropicFinishReason(stopReason)
        // 两个方向任一帧出现过 usage 才构造；完全没收到时保持 nil（UI 降级不显示）。
        // Anthropic 的 input_tokens 不含缓存量，这里加回，与 OpenAI 口径（prompt_tokens
        // 含 cached_tokens）对齐为「全部输入 token」，成本计算/展示才有统一基准。
        let usage: AgentUsage? = (inputTokens != nil || outputTokens != nil)
            ? AgentUsage(promptTokens: (inputTokens ?? 0) + cacheReadTokens + cacheWriteTokens,
                         completionTokens: outputTokens ?? 0,
                         cacheReadTokens: cacheReadTokens,
                         cacheWriteTokens: cacheWriteTokens)
            : nil
        return AgentCompletionResponse(text: accText, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    // MARK: - Request Building

    private func buildRequest(messages: [AgentMessage], tools: [any AgentTool]) throws -> URLRequest {
        switch wire {
        case .openAI:    return try openAIRequest(messages: messages, tools: tools)
        case .anthropic: return try anthropicRequest(messages: messages, tools: tools)
        }
    }

    // ── OpenAI ────────────────────────────────────────────────────────────────

    private func openAIRequest(messages: [AgentMessage], tools: [any AgentTool], stream: Bool = false) throws -> URLRequest {
        let base     = config.baseURL.hasSuffix("/") ? config.baseURL : config.baseURL + "/"
        let endpoint = base + "chat/completions"
        guard let url = URL(string: endpoint) else { throw AIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod    = "POST"
        req.timeoutInterval = config.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model":    config.model,
            "stream":   stream,
            // 分段标记只服务 Anthropic 的显式断点，OpenAI 侧靠自然前缀命中缓存 ⇒ 发出前剥掉
            "messages": messages.map { message -> [String: Any] in
                var dict = message.openAIDict
                if message.role == .system, let text = dict["content"] as? String {
                    dict["content"] = SystemPromptSegments.strippingDelimiter(text)
                }
                return dict
            }
        ]
        if !tools.isEmpty {
            payload["tools"]        = tools.map { $0.spec.openAIDict }
            payload["tool_choice"]  = "auto"
        }
        if stream {
            // 让服务端在流末帧回传 usage（OpenAI 及主流兼容服务均支持；
            // 不支持的实现会忽略该字段，解析侧对缺失 usage 已做降级）
            payload["stream_options"] = ["include_usage": true]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    // ── Anthropic ─────────────────────────────────────────────────────────────

    private func anthropicRequest(messages: [AgentMessage], tools: [any AgentTool], stream: Bool = false) throws -> URLRequest {
        let base     = config.baseURL.isEmpty ? "https://api.anthropic.com/v1" : config.baseURL
        let norm     = base.hasSuffix("/") ? base : base + "/"
        let endpoint = norm + "messages"
        guard let url = URL(string: endpoint) else { throw AIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod    = "POST"
        req.timeoutInterval = config.requestTimeoutSeconds
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.setValue(config.apiKey,       forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")

        // system 单独提取，其余按 Anthropic 多轮格式组装
        let systemRaw = messages.first(where: { $0.role == .system })?.content ?? ""
        let systemSegments = SystemPromptSegments.split(systemRaw)
        let system = SystemPromptSegments.strippingDelimiter(systemRaw)
        var convo  = buildAnthropicMessages(from: messages)
        // prompt caching 只对 Anthropic 官方端点开启：自定义 baseURL 可能是
        // 严格校验的第三方中转（one-api/new-api 等），对未知字段直接 400。
        let cacheEnabled: Bool = {
            guard !config.baseURL.isEmpty,
                  let host = URL(string: config.baseURL)?.host()?.lowercased()
            else { return true }   // 默认官方端点
            return host == "api.anthropic.com"
        }()
        if cacheEnabled { Self.applyCacheBreakpoint(to: &convo) }

        var payload: [String: Any] = [
            "model":      config.model,
            "max_tokens": 8096,
            "messages":   convo
        ]
        if stream       { payload["stream"] = true }
        // prompt caching（cache_control: ephemeral，规范上限 4 个断点，这里用 3 个）：
        // ① tools 末尾：工具定义体积大且每次 run 固定，是最稳的可复用前缀
        // ② system **稳定前缀**的末尾：见下方分块说明
        // ③ 消息列表末尾：见上。
        if !system.isEmpty {
            if cacheEnabled, let segments = systemSegments, !segments.stable.isEmpty {
                // system 拆两块：稳定段打断点、易变段挂在断点之后。
                //
                // 旧写法把整段 system 当成「同会话内稳定」——这是错的：选区每拖一下就变、
                // 记忆每轮按本轮原话重检索、首轮才有文档全文。缓存是顺序前缀，断点落在
                // 一段会变的东西之后就等于没打，所以断点必须落在那段**之前**。
                //
                // 已知边界：易变段仍在 system 里 ⇒ 它之后的全部消息（断点 ③）照样每轮失效。
                // 彻底的解法是把易变内容挪到本轮 user 消息里，那要改 systemContext 的返回
                // 形态与历史口径，留到后续（见 docs/ai-document-agents-design.md §4）。
                var blocks: [[String: Any]] = [[
                    "type": "text",
                    "text": segments.stable,
                    "cache_control": ["type": "ephemeral"],
                ]]
                if !segments.volatile.isEmpty {
                    blocks.append(["type": "text", "text": segments.volatile])
                }
                payload["system"] = blocks
            } else if cacheEnabled {
                payload["system"] = [[
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                payload["system"] = system
            }
        }
        if !tools.isEmpty {
            var toolDicts = tools.map { $0.spec.anthropicDict }
            if cacheEnabled {
                toolDicts[toolDicts.count - 1]["cache_control"] = ["type": "ephemeral"]
            }
            payload["tools"] = toolDicts
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// 给消息列表最后一条的最后一个内容块打 cache_control 断点
    /// （content 为字符串时升级为块数组——两种形态对 Anthropic 都合法）。
    private static func applyCacheBreakpoint(to convo: inout [[String: Any]]) {
        guard var last = convo.last else { return }
        var blocks: [[String: Any]]
        if let arr = last["content"] as? [[String: Any]] {
            blocks = arr
        } else if let str = last["content"] as? String, !str.isEmpty {
            blocks = [["type": "text", "text": str]]
        } else {
            return
        }
        guard !blocks.isEmpty else { return }
        blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
        last["content"] = blocks
        convo[convo.count - 1] = last
    }

    /// AgentMessage 数组 → Anthropic 多轮消息格式。
    ///
    /// Anthropic 约束：
    ///   - user / assistant 必须严格交替
    ///   - 工具结果以 tool_result 内容块写入 **user** 消息
    ///   - 同一个 user 轮次的多条工具结果合并到同一个 content 数组
    private func buildAnthropicMessages(from messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for msg in messages where msg.role != .system {
            switch msg.role {

            case .system: break   // 已在外层提取

            case .user:
                // 图片附件 → Anthropic image 内容块（base64 source）。放在文本块之前
                // （官方推荐的 parts 顺序）。无图片时 content 保持字符串形态，与旧版一致。
                var newBlocks: [[String: Any]] = []
                for image in msg.images ?? [] {
                    newBlocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image.mimeType,
                            "data": image.base64
                        ] as [String: Any]
                    ])
                }
                if !msg.content.isEmpty {
                    newBlocks.append(["type": "text", "text": msg.content])
                }
                // 连续 user 消息合并（Anthropic 要求 user/assistant 严格交替）：
                // 从 AIChatMessage fallback 重建历史时可能出现 user-user 相邻。
                // 与下方 tool_result 合并同手法：content 统一升级为块数组再追加。
                if var last = result.last, (last["role"] as? String) == "user" {
                    var blocks: [[String: Any]]
                    if let arr = last["content"] as? [[String: Any]] {
                        blocks = arr
                    } else if let str = last["content"] as? String, !str.isEmpty {
                        blocks = [["type": "text", "text": str]]
                    } else {
                        blocks = []
                    }
                    blocks.append(contentsOf: newBlocks)
                    last["content"] = blocks
                    result[result.count - 1] = last
                } else if msg.images?.isEmpty == false {
                    result.append(["role": "user", "content": newBlocks])
                } else {
                    result.append(["role": "user", "content": msg.content])
                }

            case .assistant:
                if let calls = msg.toolCalls, !calls.isEmpty {
                    // 有工具调用时 content 是数组：先文字（可选）、再 tool_use 块
                    var content: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        content.append(["type": "text", "text": msg.content])
                    }
                    for call in calls {
                        content.append([
                            "type":  "tool_use",
                            "id":    call.id,
                            "name":  call.name,
                            "input": call.argumentsDict
                        ] as [String: Any])
                    }
                    result.append(["role": "assistant", "content": content])
                } else if var last = result.last, (last["role"] as? String) == "assistant",
                          let lastText = last["content"] as? String {
                    // 连续纯文本 assistant 合并（如截断提示条紧邻上一轮回复）：与上方
                    // user 合并同手法，统一升级为块数组。带 tool_use 块的 assistant 不动
                    // （后面必须紧跟 tool_result，并入文字会破坏配对）。
                    var blocks: [[String: Any]] = lastText.isEmpty ? [] : [["type": "text", "text": lastText]]
                    if !msg.content.isEmpty {
                        blocks.append(["type": "text", "text": msg.content])
                    }
                    last["content"] = blocks
                    result[result.count - 1] = last
                } else {
                    result.append(["role": "assistant", "content": msg.content])
                }

            case .tool:
                // tool_result 块归入 user 消息；若末尾已有 user 轮次则合并，否则新建
                let block: [String: Any] = [
                    "type":        "tool_result",
                    "tool_use_id": msg.toolCallID ?? "",
                    "content":     msg.content
                ]
                if var last = result.last, (last["role"] as? String) == "user" {
                    // 将上一条 user 消息的 content 升级为数组并追加
                    var blocks: [[String: Any]]
                    if let arr = last["content"] as? [[String: Any]] {
                        blocks = arr
                    } else if let str = last["content"] as? String, !str.isEmpty {
                        blocks = [["type": "text", "text": str]]
                    } else {
                        blocks = []
                    }
                    blocks.append(block)
                    last["content"] = blocks
                    result[result.count - 1] = last
                } else {
                    result.append(["role": "user", "content": [block]])
                }
            }
        }
        return result
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data) throws -> AgentCompletionResponse {
        switch wire {
        case .openAI:    return try parseOpenAI(data: data)
        case .anthropic: return try parseAnthropic(data: data)
        }
    }

    // ── OpenAI response ───────────────────────────────────────────────────────

    private func parseOpenAI(data: Data) throws -> AgentCompletionResponse {
        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices  = json["choices"] as? [[String: Any]],
              let choice   = choices.first,
              let message  = choice["message"] as? [String: Any]
        else { throw AgentError.parseError("无法解析 OpenAI 响应") }

        let text         = message["content"] as? String ?? ""
        let finishReason = choice["finish_reason"] as? String ?? "stop"

        let toolCalls: [AgentToolCall] = (message["tool_calls"] as? [[String: Any]] ?? [])
            .compactMap { raw in
                guard let id   = raw["id"] as? String,
                      let fn   = raw["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let args = fn["arguments"] as? String
                else { return nil }
                return AgentToolCall(id: id, name: name, argumentsJSON: args)
            }

        let usageObj = json["usage"] as? [String: Any]
        let usage = usageObj.map { u in
            // prompt_tokens_details.cached_tokens：自动 prompt caching 的命中量（缺失则 0）
            let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            return AgentUsage(promptTokens: u["prompt_tokens"] as? Int ?? 0,
                              completionTokens: u["completion_tokens"] as? Int ?? 0,
                              cacheReadTokens: cached)
        }
        return AgentCompletionResponse(text: text, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    // ── Anthropic response ────────────────────────────────────────────────────

    private func parseAnthropic(data: Data) throws -> AgentCompletionResponse {
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw AgentError.parseError("无法解析 Anthropic 响应") }

        let stopReason = json["stop_reason"] as? String ?? "end_turn"

        var text      = ""
        var toolCalls = [AgentToolCall]()

        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id    = block["id"] as? String,
                      let name  = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                let argsJSON = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(AgentToolCall(id: id, name: name, argumentsJSON: argsJSON))
            default:
                break
            }
        }

        let finishReason = Self.mapAnthropicFinishReason(stopReason)
        let usageObj = json["usage"] as? [String: Any]
        let usage = usageObj.map { u in
            // Anthropic 的 input_tokens 不含缓存量（cache_read/cache_creation 单列），
            // 加回后与 OpenAI 口径对齐为「全部输入 token」（见 AgentUsage 头注释）
            let cacheRead  = u["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
            return AgentUsage(promptTokens: (u["input_tokens"] as? Int ?? 0) + cacheRead + cacheWrite,
                              completionTokens: u["output_tokens"] as? Int ?? 0,
                              cacheReadTokens: cacheRead,
                              cacheWriteTokens: cacheWrite)
        }
        return AgentCompletionResponse(text: text, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    /// Anthropic `stop_reason` → 统一 finishReason 口径。
    ///
    /// 关键：`max_tokens` 必须映射为 `"length"`（此前被折叠成 `"stop"`），否则
    /// AgentRunner 检测不到截断，用户会在没有任何提示的情况下拿到被截断的结果。
    static func mapAnthropicFinishReason(_ stopReason: String) -> String {
        switch stopReason {
        case "tool_use":   return "tool_calls"
        case "max_tokens": return "length"
        default:           return "stop"
        }
    }
}
