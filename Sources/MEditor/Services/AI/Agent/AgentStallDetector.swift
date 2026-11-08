import Foundation

struct AgentStallDetection {
    let diagnostic: AgentStallDiagnostic
    let message: String
}

/// Detects repeated tool failures and completed steps that make no progress.
struct AgentStallDetector {
    private static let repeatedCallThreshold = 3
    private static let allFailedStepThreshold = 4
    private static let noProgressStepThreshold = 4

    private var lastFailureFingerprint: String?
    private var consecutiveFailures = 0
    private var allFailedStreak = 0
    private var noProgressStreak = 0
    private var seenOutcomes: Set<String> = []

    /// Same tool and arguments failing consecutively indicates a stuck call.
    mutating func record(call: AgentToolCall, result: AgentToolResult) -> AgentStallDetection? {
        guard result.isError else {
            lastFailureFingerprint = nil
            consecutiveFailures = 0
            return nil
        }

        let fingerprint = Self.callFingerprint(call)
        if fingerprint == lastFailureFingerprint {
            consecutiveFailures += 1
        } else {
            lastFailureFingerprint = fingerprint
            consecutiveFailures = 1
        }
        guard consecutiveFailures >= Self.repeatedCallThreshold else { return nil }

        let summary = Self.firstLine(result.content, maxLength: 120)
        let diagnostic = AgentStallDiagnostic(
            toolName: call.name,
            repeatCount: consecutiveFailures,
            lastErrorSummary: summary
        )
        let message = "Agent 在工具 '\(call.name)' 上停滞：相同调用已连续失败 \(consecutiveFailures) 次（最后错误：\(summary)）。已中断运行，请检查该工具的输入或换个说法重试。"
        return AgentStallDetection(diagnostic: diagnostic, message: message)
    }

    /// Evaluate only complete tool-call steps; partial/cancelled steps do not affect progress.
    mutating func evaluateStep(
        calls: [AgentToolCall],
        results: [AgentToolResult]
    ) -> AgentStallDetection? {
        guard !results.isEmpty else { return nil }

        if results.allSatisfy({ $0.isError }) {
            allFailedStreak += 1
        } else {
            allFailedStreak = 0
        }

        var sawNewOutcome = false
        for result in results where seenOutcomes.insert(Self.outcomeSignature(result)).inserted {
            sawNewOutcome = true
        }
        noProgressStreak = sawNewOutcome ? 0 : noProgressStreak + 1
        let toolNames = Set(calls.map(\.name)).sorted().joined(separator: "、")

        if allFailedStreak >= Self.allFailedStepThreshold {
            let summary = Self.firstLine(results.last?.content ?? "", maxLength: 120)
            let diagnostic = AgentStallDiagnostic(
                toolName: toolNames,
                repeatCount: allFailedStreak,
                lastErrorSummary: summary
            )
            let message = "Agent 连续 \(allFailedStreak) 步的工具调用全部失败（涉及：\(toolNames)）。"
                + "已中断运行——反复换参数仍失败通常意味着前提假设不成立，请检查输入或换个说法重试。"
                + "（最后一次错误：\(summary)）"
            return AgentStallDetection(diagnostic: diagnostic, message: message)
        }

        if noProgressStreak >= Self.noProgressStepThreshold {
            let diagnostic = AgentStallDiagnostic(
                toolName: toolNames,
                repeatCount: noProgressStreak,
                lastErrorSummary: "连续 \(noProgressStreak) 步未产生新结果"
            )
            let message = "Agent 连续 \(noProgressStreak) 步没有任何有效进展：工具返回的都是此前已出现过的结果"
                + "（涉及：\(toolNames)），反复读写同一内容不会推进任务。已中断运行，请换个说法重试。"
            return AgentStallDetection(diagnostic: diagnostic, message: message)
        }

        return nil
    }

    /// Tool name plus sorted-keys JSON makes argument order irrelevant.
    private static func callFingerprint(_ call: AgentToolCall) -> String {
        let raw = call.arguments.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "\(call.name)|?" }
        return "\(call.name)|\(json)"
    }

    private static func outcomeSignature(_ result: AgentToolResult) -> String {
        "\(result.toolName)|\(result.isError ? "E" : "O")|\(result.content.hashValue)"
    }

    private static func firstLine(_ string: String, maxLength: Int) -> String {
        let line = string.components(separatedBy: "\n").first ?? string
        return line.count > maxLength ? String(line.prefix(maxLength)) + "…" : line
    }
}
