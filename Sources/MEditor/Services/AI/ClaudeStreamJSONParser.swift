import Foundation

/// claude CLI `-p --output-format stream-json --verbose` 的逐行（JSONL）解析器。
///
/// 事件类型（本机 claude 2.1.233 实测）：
///  - `stream_event`（需 `--include-partial-messages`）：真增量，
///    `event.delta.type == "text_delta"` 时 `delta.text` 是一小段新文本
///  - `assistant`：每条 assistant 消息的累积快照（content 里 text block 为全量），
///    无 partial 时也有此事件，取「与已 yield 文本的差分」即可幂等去重
///  - `result`：终态事件；`subtype == "success"` 时 `result` 是最终全文（差分收尾），
///    否则 `result` 是错误描述，记入 `resultError` 由调用方抛错
///
/// 纯值类型、无 IO，供单测直接构造 JSONL 行验证增量回调。
struct ClaudeStreamJSONParser: Sendable {
    /// 已上抛的累积文本（assistant/result 快照为全量，统一按前缀差分去重）
    private(set) var yielded = ""
    /// 终态错误描述（result 事件 subtype != "success" / is_error == true 时填充）
    private(set) var resultError: String? = nil
    /// CLI 侧工具被拒 / 执行失败的错误描述（`user` 事件里 tool_result 的 is_error == true）。
    ///
    /// CLI 内建工具现在已用 `--tools ""` 关掉，这里是兜底：这类事件此前被整条丢弃，
    /// 用户只会看到模型自己说"等待你授权"，而界面上没有任何提示或按钮。
    private(set) var toolErrorNotice: String? = nil

    /// 喂入一行 stream-json，返回需要上抛的文本增量（无新增返回 nil）。
    mutating func ingest(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            yielded += text
            return text

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            let full = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
            return emitSuffix(of: full)

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let subtype = obj["subtype"] as? String ?? ""
            guard !isError, subtype == "success" else {
                resultError = (obj["result"] as? String) ?? L("ai.error.cliGeneric")
                return nil
            }
            guard let text = obj["result"] as? String else { return nil }
            return emitSuffix(of: text)

        case "user":
            // 工具结果回灌：CLI 侧执行完工具后，结果以 user 消息回到流里。
            // 只挑失败的记下来；记了不 throw，本轮文本仍然有效。
            guard toolErrorNotice == nil,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            for block in content {
                guard block["type"] as? String == "tool_result",
                      (block["is_error"] as? Bool) == true else { continue }
                let text = Self.plainText(block["content"])
                if !text.isEmpty { toolErrorNotice = text }
                return nil
            }
            return nil

        default:
            return nil
        }
    }

    private static func plainText(_ raw: Any?) -> String {
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 快照差分：快照不是已 yield 内容的前缀延伸时（不应发生）保守不补，避免重复文本。
    private mutating func emitSuffix(of full: String) -> String? {
        guard full.count > yielded.count, full.hasPrefix(yielded) else { return nil }
        let suffix = String(full.dropFirst(yielded.count))
        yielded = full
        return suffix
    }
}
