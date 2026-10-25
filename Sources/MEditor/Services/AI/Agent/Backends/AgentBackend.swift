import Foundation

// MARK: - AgentBackend Protocol

/// 每种 AI 后端实现此协议，AgentRunner 通过协议调用，不感知具体后端。
/// 新增后端（Gemini、Anthropic API、本地 LLM）只需实现此协议，无需改 Runner。
protocol AgentBackend: Sendable {
    func complete(
        messages: [AgentMessage],
        tools: [any AgentTool]
    ) async throws -> AgentCompletionResponse

    /// 流式版本：文字 chunk 边生成边回调，工具调用结束后一次性返回完整 response。
    /// 默认实现回退到 complete()，不调用 onTextChunk。
    func completeStreaming(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse
}

extension AgentBackend {
    func completeStreaming(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        try await complete(messages: messages, tools: tools)
    }
}

// MARK: - Agent completion response

struct AgentCompletionResponse: Sendable {
    var text: String
    var toolCalls: [AgentToolCall]
    var finishReason: String  // "stop" | "tool_calls" | "length"
    /// 本次响应的 token 用量。ClaudeCLI 子进程不返回 usage，保持 nil（默认），
    /// Runner 累计时跳过，UI 降级不显示。
    var usage: AgentUsage? = nil
}

// MARK: - Agent AI Message (extended with tool roles)

struct AgentMessage: Sendable, Codable {
    enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    var role: Role
    var content: String
    var toolCalls: [AgentToolCall]?
    var toolCallID: String?
    var toolName: String?
    /// 图片附件（仅 user 消息、仅当前 run 内存）：base64 不进 agentHistory 持久化，
    /// 与 AIChatMessage.images 同一取舍。不参与 Codable（见 CodingKeys）。
    var images: [AIImageAttachment]? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, toolCalls, toolCallID, toolName   // images 故意不编码
    }

    // Convert to standard AIMessage (system/user/assistant only)
    var asAIMessage: AIMessage {
        switch role {
        case .system:    return AIMessage(role: .system,    content: content)
        case .user:      return AIMessage(role: .user,      content: content)
        case .assistant: return AIMessage(role: .assistant, content: content)
        case .tool:
            // tool-role 消息不应通过 asAIMessage 转换（应走 openAIDict）
            // Release 下安全降级为 user 消息，避免静默数据损坏导致 AI 行为异常
            return AIMessage(role: .user, content: "[tool result] " + content)
        }
    }

    // OpenAI wire format
    var openAIDict: [String: Any] {
        switch role {
        case .system:
            return ["role": "system", "content": content]
        case .user:
            // 带图片附件 → OpenAI 多模态 content parts；无图片保持纯文本字符串格式
            // （兼容纯文本模型，且不改变历史请求的 wire 字节）
            if let images, !images.isEmpty {
                var parts: [[String: Any]] = []
                if !content.isEmpty {
                    parts.append(["type": "text", "text": content])
                }
                for image in images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": image.dataURL]
                    ])
                }
                return ["role": "user", "content": parts]
            }
            return ["role": "user", "content": content]
        case .assistant:
            var d: [String: Any] = ["role": "assistant"]
            if let calls = toolCalls, !calls.isEmpty {
                d["content"] = content.isEmpty ? nil : content as Any
                d["tool_calls"] = calls.map { call -> [String: Any] in
                    // 优先回放后端返回的原始参数 JSON（保持历史与线上完全一致）；
                    // 缺失时（手工构造的 call）由强类型 arguments 重新序列化
                    let argsStr: String
                    if let raw = call.rawArgumentsJSON {
                        argsStr = raw
                    } else {
                        let argsDict = call.arguments.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
                        let argsData = (try? JSONSerialization.data(withJSONObject: argsDict)) ?? Data()
                        argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                    }
                    return [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": argsStr] as [String: Any]
                    ]
                }
            } else {
                d["content"] = content
            }
            return d
        case .tool:
            return [
                "role": "tool",
                "tool_call_id": toolCallID ?? "",
                "content": content
            ]
        }
    }
}

// MARK: - System Prompt Segments

/// system prompt 的「稳定前缀 / 易变部分」分段标记。
///
/// 为什么需要它：prompt cache 是**顺序前缀**匹配。system prompt 里只要有一处每轮都变
/// （选区、按本轮原话检索出的记忆、首轮才有的文档全文），从那一处往后的一切就都失效——
/// 包括紧跟着的全部历史消息。把易变内容统一挪到 system 的**尾部**，并在稳定前缀的
/// 末尾打一个 `cache_control` 断点，至少保住「规则 + 策略 + 技能」这一段。
///
/// 标记用 NUL 包裹：正文里不可能出现，且**永远不会被发到线上**——
/// Anthropic 侧在序列化前按它切块，OpenAI / ClaudeCLI 侧在序列化前把它剥掉。
enum SystemPromptSegments {

    /// 稳定块与易变块的分界。两侧各带一个 NUL，避免与正文里的同名字符串混淆。
    static let delimiter = "\u{0}meditor:volatile\u{0}"

    /// 拼接：稳定段在前，易变段在后。易变段为空时不插标记（保持单块 prompt）。
    static func join(stable: String, volatile: String) -> String {
        guard !volatile.isEmpty else { return stable }
        return stable + delimiter + volatile
    }

    /// 切块。没有标记时返回 nil（= 整段都是稳定前缀，无需分块）。
    static func split(_ text: String) -> (stable: String, volatile: String)? {
        guard let range = text.range(of: delimiter) else { return nil }
        return (String(text[text.startIndex..<range.lowerBound]),
                String(text[range.upperBound...]))
    }

    /// 剥掉标记（非 Anthropic wire 用）。两侧不加分隔符——`join` 只是拼接，
    /// 各段自带前导换行，补一个分隔符会让 prompt 里凭空多出空行。
    static func strippingDelimiter(_ text: String) -> String {
        text.replacingOccurrences(of: delimiter, with: "")
    }
}

// MARK: - Factory

/// 根据 AIConfig 创建对应 backend，外部只需调用这一个入口
enum AgentBackendFactory {
    static func make(config: AIConfig) -> any AgentBackend {
        switch config.kind {
        case .disabled:   return DisabledBackend()
        case .openai:     return RestAgentBackend(config: config, wire: .openAI)
        case .anthropic:  return RestAgentBackend(config: config, wire: .anthropic)
        case .claudeCLI:
#if os(macOS)
            return ClaudeCLIBackend(config: config)
#else
            // iOS 无 Process 子进程能力：claude CLI 后端不可用，降级为 Disabled
            return DisabledBackend()
#endif
        }
    }
}
