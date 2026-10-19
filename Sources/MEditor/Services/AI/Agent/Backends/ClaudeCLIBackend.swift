import Foundation

// MARK: - Claude CLI Backend（XML 模拟工具调用）

struct ClaudeCLIBackend: AgentBackend {
    let config: AIConfig

    // MARK: - Intent

    private enum Intent {
        case fileManage  // 明确的文件创建/目录操作
        case command     // 明确的命令执行
        case mixed       // 其余情况（安全干默）
    }

    // MARK: - IntentScorer

    /// 基于权重评分的意图分类器。
    ///
    /// 设计原则：
    ///  - 精确词组（全词匹配）权重高；包含子串的普通匹配权重低
    ///  - 负向词（干扰词）扣分，避免 "runtime" 误触 command 意图
    ///  - 必须达到阈値才分类，低于阈値则 mixed（安全干默）
    ///
    /// `internal`（非 private）以便单测直接访问静态方法。
    struct IntentScorer {

        struct WeightedPhrase {
            let phrase: String
            let weight: Int
            /// 如果 text 中包含这些词中任何一个，则不计分（防止误触）
            let negations: [String]

            init(_ phrase: String, weight: Int, negations: [String] = []) {
                self.phrase   = phrase
                self.weight   = weight
                self.negations = negations
            }
        }

        // 命令意图评分规则
        static let commandPhrases: [WeightedPhrase] = [
            // 负向：精确全词断语（权重 3）
            WeightedPhrase("run command",      weight: 3, negations: ["don't run", "no command", "without command"]),
            WeightedPhrase("run script",       weight: 3, negations: ["don't run"]),
            WeightedPhrase("execute command",  weight: 3),
            WeightedPhrase("execute script",   weight: 3),
            WeightedPhrase("运行命令",        weight: 3),
            WeightedPhrase("执行命令",        weight: 3),
            WeightedPhrase("执行脚本",        weight: 3),
            WeightedPhrase("运行脚本",        weight: 3),
            // 中权重：常见但有歧义（权重 2）
            WeightedPhrase("bash ",            weight: 2, negations: ["bash script", "bash file"]),
            WeightedPhrase("shell command",    weight: 2),
            WeightedPhrase("npm run ",         weight: 2, negations: ["npm run script"]),
            WeightedPhrase("npx ",             weight: 2),
            WeightedPhrase("make ",            weight: 2, negations: ["make sure", "make it", "make the"]),
            // 低权重：干扰容易大的词（权重 1）——单独不足以触发分类
            WeightedPhrase("script",           weight: 1, negations: ["script tag", "inline script", "no script", "shell script is"]),
        ]

        // 文件管理意图评分规则
        static let fileManagePhrases: [WeightedPhrase] = [
            WeightedPhrase("create file",      weight: 3),
            WeightedPhrase("new file",         weight: 3, negations: ["open new file", "save as new file"]),
            WeightedPhrase("make file",        weight: 3),
            WeightedPhrase("mkdir",            weight: 3),
            WeightedPhrase("create directory", weight: 3),
            WeightedPhrase("new directory",    weight: 3),
            WeightedPhrase("新建文件",        weight: 3),
            WeightedPhrase("创建文件",        weight: 3),
            WeightedPhrase("创建目录",        weight: 3),
            WeightedPhrase("新建目录",        weight: 3),
        ]

        /// 分类阈値：评分必须 ≥ threshold 才应用对应意图。
        /// 默认 2：要求至少命中一个中权重匹配，防止子串误打。
        static let threshold: Int = 2

        static func score(text: String, phrases: [WeightedPhrase]) -> Int {
            var total = 0
            for item in phrases {
                guard text.contains(item.phrase) else { continue }
                // 负向词检查：有任意匹配则不计分
                if item.negations.contains(where: { text.contains($0) }) { continue }
                total += item.weight
            }
            return total
        }
    }

    /// 根据最近 3 条用户消息推断意图。
    ///
    /// 保守策略：当两种意图评分都达到阈値时，选择得分更高的；
    ///   得分相同时优先 mixed（不确定则不居分）。
    private func inferIntent(from messages: [AgentMessage]) -> Intent {
        let text = messages
            .filter { $0.role == .user }
            .suffix(3)
            .map { $0.content.lowercased() }
            .joined(separator: " ")

        let commandScore    = IntentScorer.score(text: text, phrases: IntentScorer.commandPhrases)
        let fileManageScore = IntentScorer.score(text: text, phrases: IntentScorer.fileManagePhrases)
        let threshold       = IntentScorer.threshold

        switch (commandScore >= threshold, fileManageScore >= threshold) {
        case (true, false):  return .command
        case (false, true):  return .fileManage
        case (true, true):   return commandScore > fileManageScore ? .command : .fileManage
        case (false, false): return .mixed
        }
    }

    /// 按意图过滤工具。
    /// 原则：只排除「当前意图绝对用不到」的重型工具；
    /// 核心读写工具（read/patch/write）始终保留，防止 AI 读完文件想修改时无工具可用。
    /// 过滤后为空时自动回退全量（防止自定义工具全被剔除）。
    private func selectTools(_ tools: [any AgentTool], intent: Intent) -> [any AgentTool] {
        let excluded: Set<String>
        switch intent {
        case .command:                           // 执行命令：不排除任何工具（AI 可能需要先读文件）
            return tools
        case .fileManage:                        // 文件管理：排除命令执行
            excluded = ["run_command"]
        case .mixed:                             // 混合：不排除
            return tools
        }
        let result = tools.filter { !excluded.contains($0.spec.name) }
        return result.isEmpty ? tools : result   // 空结果时回退全量
    }

    // MARK: - complete / completeStreaming

    func complete(
        messages: [AgentMessage],
        tools: [any AgentTool]
    ) async throws -> AgentCompletionResponse {
        try await runOnce(messages: messages, tools: tools, onTextChunk: nil)
    }

    /// 流式版本：claude CLI 走 stream-json 增量输出（见 AIService.claudeCLIStream），
    /// 文本 chunk 边到达边上抛，不再等整段回复生成完。
    func completeStreaming(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AgentCompletionResponse {
        try await runOnce(messages: messages, tools: tools, onTextChunk: onTextChunk)
    }

    private func runOnce(
        messages: [AgentMessage],
        tools: [any AgentTool],
        onTextChunk: (@Sendable (String) -> Void)?
    ) async throws -> AgentCompletionResponse {        var systemPrompt = messages.first(where: { $0.role == .system })?.content ?? ""

        if !tools.isEmpty {
            let intent   = inferIntent(from: messages)
            let selected = selectTools(tools, intent: intent)

            systemPrompt += """


---

## Available Tools

You have NO built-in tools of your own: you cannot run shell commands, read or write
files, or browse. The ONLY way you can act is by emitting a tool call in the exact XML
format below; the host application executes it and returns the result.

To call a tool, output EXACTLY this XML block on its own line:

<tool_call>
<name>TOOL_NAME</name>
<arguments>{"key": "value"}</arguments>
</tool_call>

Rules: arguments MUST be valid JSON • wait for result before continuing • never refuse a tool call
• use this format verbatim (not DSML, not antml, not JSON function calls).

### Tools (name(required: type, optional?: type) → description):

"""
            systemPrompt += selected.map { $0.spec.compactCLIDescription }.joined(separator: "\n")
        }

        // Build conversation text (skip system message, already in systemPrompt)
        var parts: [String] = []
        for msg in messages.filter({ $0.role != .system }) {
            switch msg.role {
            case .user:
                parts.append("Human: \(msg.content)")
            case .assistant:
                parts.append("Assistant: \(msg.content)")
            case .tool:
                parts.append("Tool Result [\(msg.toolName ?? "")]: \(msg.content)")
            default:
                break
            }
        }
        parts.append("Assistant:")
        let conversationText = parts.joined(separator: "\n\n")

        let cliMessages = [
            AIMessage(role: .system, content: systemPrompt),
            AIMessage(role: .user,   content: conversationText)
        ]

        var accumulated = ""
        // 流式上抛前过滤 <tool_call> 协议块：UI 只看自然语言，不看 XML
        var filter = ToolCallStreamFilter()
        for try await chunk in AIClient(config: config).stream(cliMessages) {
            accumulated += chunk
            guard let onTextChunk else { continue }
            let visible = filter.process(chunk)
            if !visible.isEmpty { onTextChunk(visible) }
        }
        if let onTextChunk {
            let tail = filter.flush()
            if !tail.isEmpty { onTextChunk(tail) }
        }

        let toolCalls = parseToolCalls(from: accumulated)

        // 只在解析到工具调用时才清理 XML 标签，保留正常文本
        let text = toolCalls.isEmpty ? accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                                     : removeToolCallTags(from: accumulated)
        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"

        // usage 保持 nil：claude 子进程的非交互输出不回传 token 用量，Runner/UI 按缺失降级
        return AgentCompletionResponse(text: text, toolCalls: toolCalls, finishReason: finishReason)
    }

    // MARK: - XML Parsing（带容错）

    // internal（非 private）以便单测直接验证 _parse_error 等容错路径
    func parseToolCalls(from text: String) -> [AgentToolCall] {
        var calls: [AgentToolCall] = []

        // 主模式：标准格式
        let pattern = #"<tool_call>\s*<name>(.*?)</name>\s*<arguments>(.*?)</arguments>\s*</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return calls
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let name    = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let argsStr = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

            // 验证 arguments 是合法 JSON
            guard let argsData = argsStr.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: argsData)) != nil
            else {
                // 尝试一种明确修复：trim + 补充外层 {}
                let trimmed = argsStr.trimmingCharacters(in: .whitespacesAndNewlines)
                let repairCandidates = [trimmed, "{\(trimmed)}"]
                if let repaired = repairCandidates.first(where: {
                    guard let d = $0.data(using: .utf8) else { return false }
                    return (try? JSONSerialization.jsonObject(with: d)) != nil
                }) {
                    let id = "claude-\(calls.count)-\(name)"
                    calls.append(AgentToolCall(id: id, name: name, argumentsJSON: repaired))
                    continue
                }
                // 修复彻底失败 → 注入 _parse_error，让 AI 看到错误并重试
                let errID = "parse-err-\(calls.count)-\(name)"
                // 用 JSONSerialization 构造：工具名 / 原始参数含引号、反斜杠、换行时，
                // 手工拼接会产出非法 JSON
                let errObj: [String: String] = [
                    "original_tool": name,
                    "raw_arguments": String(argsStr.prefix(300)),
                    "error": "Arguments JSON is malformed — please retry with valid JSON"
                ]
                let errJSON = (try? JSONSerialization.data(withJSONObject: errObj))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? #"{"error": "Arguments JSON is malformed — please retry with valid JSON"}"#
                calls.append(AgentToolCall(id: errID, name: "_parse_error", argumentsJSON: errJSON))
                continue
            }
            // JSON 合法
            let id = "claude-\(calls.count)-\(name)"
            calls.append(AgentToolCall(id: id, name: name, argumentsJSON: argsStr))
        }
        return calls
    }

    private func removeToolCallTags(from text: String) -> String {
        let pattern = #"<tool_call>.*?</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

// MARK: - 流式 XML 过滤器

/// 增量过滤 `<tool_call>…</tool_call>` 协议块：流式上抛给 UI 的文本不应露出 XML。
/// chunk 可能正好切在标签中间（如 "<tool" + "_call>"），用 pending 尾暂存未判定的
/// 疑似标签前缀，下一 chunk 到达后再定夺。internal（非 private）以便单测直接验证。
struct ToolCallStreamFilter {
    private static let openTag  = "<tool_call>"
    private static let closeTag = "</tool_call>"

    /// 当前是否处于工具调用块内（块内文本全部吞掉）
    private var inToolCall = false
    /// 可能是标签前缀的暂存文本（跨 chunk 标签检测）
    private var pending = ""

    /// 处理一个 chunk，返回可以立刻上抛给 UI 的可见文本。
    mutating func process(_ chunk: String) -> String {
        var buf = pending + chunk
        pending = ""
        var out = ""
        while !buf.isEmpty {
            if inToolCall {
                if let range = buf.range(of: Self.closeTag) {
                    buf = String(buf[range.upperBound...])
                    inToolCall = false
                } else {
                    // 整块吞掉，只保留可能是 closeTag 前缀的尾部
                    pending = Self.tagPrefixSuffix(of: buf, tag: Self.closeTag)
                    buf = ""
                }
            } else {
                if let range = buf.range(of: Self.openTag) {
                    out += buf[..<range.lowerBound]
                    buf = String(buf[range.upperBound...])
                    inToolCall = true
                } else {
                    // 尾部可能是 openTag 被切断的前缀，暂存等下一 chunk
                    let tail = Self.tagPrefixSuffix(of: buf, tag: Self.openTag)
                    out += buf.dropLast(tail.count)
                    pending = tail
                    buf = ""
                }
            }
        }
        return out
    }

    /// 流结束冲刷：pending 若不在工具调用块内则原样放出（不是标签，只是普通文本尾）。
    mutating func flush() -> String {
        defer { pending = "" }
        return inToolCall ? "" : pending
    }

    /// s 的最长后缀，同时是 tag 的前缀（跨 chunk 标签检测用）。
    private static func tagPrefixSuffix(of s: String, tag: String) -> String {
        let maxLen = min(s.count, tag.count - 1)
        guard maxLen > 0 else { return "" }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = s.suffix(len)
            if tag.hasPrefix(suffix) { return String(suffix) }
        }
        return ""
    }
}
