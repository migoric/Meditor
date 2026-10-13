import Foundation

/// 发给后端的 agent 历史的上下文预算裁剪。
///
/// 背景：工具读回的大结果（read_file / read_document 单条可达 64K 字符）会永久留在
/// agentHistory 里逐轮重发，长 run 后期每轮都在为无用的旧结果付费。持久化历史保持完整，
/// 本模块只在 AgentRunner 每次请求后端前对「线上副本」做预算裁剪（存储层不改）。
///
/// 策略（优先保配对、保最近上下文、保原始目标）：
/// 0. 首条对齐：无论是否触发预算裁剪，发给后端的首条（非 system）消息必须是 user
///    （Anthropic 对 assistant 开头的历史直接 400）；assistant(toolCalls) 与其后
///    连续的 tool 结果整组丢弃，保持配对完整。对齐不越过保护边界。
/// 1. system 固定在头部；紧随 system 的首条 user（用户的原始任务指令）一并钉住，
///    不参与任何裁剪与占位。理由见 trim 内的注释。
/// 2. 最近 N 条消息完整保留；更早历史里的长 tool 结果替换为占位符
///    （只改 content，消息条数与角色序列不变，tool_call / tool_result 配对天然保持）。
///    对称地，assistant 消息里的大 toolCalls 参数（write_document 全量写入可达数万字符）
///    超过同一阈值时把参数 JSON 换成占位对象（name/id 配对字段不动）。
/// 3. 仍超预算才从最老一端整轮裁掉，边界不落在 tool 消息上（同 truncateIfOverLimit 的对齐规则），
///    裁完再做一次首条对齐（预算裁剪的终点可以是 assistant）。
enum AgentHistoryBudget {

    /// 默认预算（token 估算值）。主流模型上下文窗口已在 100K~128K 级，取约一半的保守值：
    /// 为 system prompt（可达数千 token）与输出预留空间，同时让早期大工具结果及时淘汰。
    /// 先做常量而非设置项：预算取决于模型窗口而 App 并不感知用户配的模型，暴露 UI 反而易配错；
    /// 确有需求时再开放（类比 AIConversation 的 128K 阈值同样是写死的常量）。
    static let defaultBudgetTokens = 60_000

    /// 完整保留的最近消息条数：模型对最近上下文最敏感，尾部不参与任何裁剪。
    static let defaultKeepRecentMessages = 8

    /// 短于该长度的 tool 结果 / tool_calls 参数不值得替换（占位符本身也占 token）。
    static let minToolResultChars = 400

    /// 长 tool 结果的占位文案：同时是给模型的指引——仍需内容时重新调用工具读取。
    static let toolResultPlaceholder = "[早前读取的内容已省略，如仍需请用工具重新读取]"

    /// 长 toolCalls 参数的占位 JSON：必须是合法 JSON 对象字符串——后端 wire 回放要求
    /// arguments 为 JSON 文本；只替换参数内容，name/id 配对字段保持不动，消息结构不变。
    /// 取舍：占位后该调用的真实参数在线上副本中不可见，模型如需原文可用工具重新读取；
    /// 持久化历史不受影响（本模块只改线上副本）。
    static let toolCallArgsPlaceholder = #"{"omitted":"[早前工具调用的参数已省略，如仍需请用工具重新读取]"}"#

    /// 裁剪结果摘要（也用于 UI 提示）。
    struct TrimResult: Sendable {
        var messages: [AgentMessage]
        /// 被占位符替换的早期 tool 结果条数（仅计仍保留在结果里的）
        var evictedToolResults: Int
        /// 被占位符替换的早期 toolCalls 参数个数（仅计仍保留在结果里的）
        var evictedToolCallArgs: Int
        /// 第二级整轮裁掉的消息条数
        var droppedMessages: Int
        var didTrim: Bool { evictedToolResults > 0 || evictedToolCallArgs > 0 || droppedMessages > 0 }
    }

    /// 对要发给后端的消息列表做预算裁剪，返回裁剪副本；输入不被修改。
    /// token 估算复用 AIConversation.estimateTokens 的混合语言启发式，与截断/banner 口径一致；
    /// assistant 消息的 toolCalls 参数 JSON 一并计入（见 estimatedTokensForBudget）。
    static func trim(
        _ messages: [AgentMessage],
        budgetTokens: Int = defaultBudgetTokens,
        keepRecentMessages: Int = defaultKeepRecentMessages
    ) -> TrimResult {
        var result = messages
        var estimates = messages.map { $0.estimatedTokensForBudget }
        var total = estimates.reduce(0, +)

        // system 固定在头部；紧随 system 的首条 user 指令一并钉住。
        //
        // 为什么钉：长会话里首条 user 是用户的原始目标。此前 headStart 只覆盖 system，
        // 该条落在可裁区，历史一长就被整轮裁掉 —— 模型忘记最初要做什么、继续在错的
        // 方向上编辑文档。AIConversationStore 早有「保留第一条」的做法，预算层没对齐。
        // 取舍与「保护尾部」一致：即使仍超预算也不再牺牲这条锚点。
        var headStart = messages.first?.role == .system ? 1 : 0
        if headStart < messages.count, messages[headStart].role == .user {
            headStart += 1
        }
        /// 钉住的头部自身已以 user 结尾：此时最终消息的首条（非 system）就是它，
        /// 首条对齐无事可做，跳过（强行对齐会把紧随其后的 assistant 一起丢掉，
        /// 破坏「头部完整保留」的语义）。
        let headEndsWithUser = headStart > 0 && messages[headStart - 1].role == .user
        var protectedFrom = max(headStart, messages.count - keepRecentMessages)
        // 保护边界不能劈开 tool_call/tool_result 配对：边界处若是 tool 结果，
        // 其 assistant(toolCalls) 落在非保护区，第二级裁掉它会留下孤儿 result
        // （API 直接报错）。把边界前移，让整对进入保护尾部。
        while protectedFrom > headStart, protectedFrom < result.count,
              result[protectedFrom].role == .tool {
            protectedFrom -= 1
        }

        // 首条对齐（若无钉住的 user 头部）：即使预算内，也不让 assistant 开头的历史
        // 发给后端（持久化历史可能来自旧版本裁剪结果）。
        var start = headStart
        if !headEndsWithUser {
            alignStartToUser(result, start: &start, protectedFrom: protectedFrom,
                             total: &total, estimates: estimates)
        }
        // 对齐丢弃是对旧数据的静默修正，不算「预算裁剪」——不体现在提示文案里
        let alignedStart = start

        guard total > budgetTokens else {
            return makeResult(result, headStart: headStart, start: start,
                              evictedToolResults: 0, evictedToolCallArgs: 0,
                              droppedMessages: 0)
        }

        // 第一级：更早历史里的长 tool 结果替换为占位符（只改 content，配对天然保持）
        var evicted = 0
        if protectedFrom > start {
            let placeholderEstimate = AIConversation.estimateTokens(toolResultPlaceholder)
            for i in start..<protectedFrom
            where result[i].role == .tool && result[i].content.count >= minToolResultChars {
                total += placeholderEstimate - estimates[i]
                estimates[i] = placeholderEstimate
                result[i].content = toolResultPlaceholder
                evicted += 1
            }
        }

        // 第一级（对称规则）：assistant 的大 toolCalls 参数同样永久滞留历史逐轮重发，
        // 超过同一阈值时把参数 JSON 换成占位对象（name/id/toolCallID 配对字段不动）。
        var evictedArgs = 0
        if protectedFrom > start {
            for i in start..<protectedFrom
            where result[i].role == .assistant && result[i].toolCalls?.isEmpty == false {
                var calls = result[i].toolCalls ?? []
                var replaced = 0
                for j in calls.indices
                where calls[j].argumentsJSONForReplay.count >= minToolResultChars {
                    calls[j].rawArgumentsJSON = toolCallArgsPlaceholder
                    // arguments 同步占位：Anthropic wire 走 argumentsDict（不是
                    // rawArgumentsJSON），只置空会让模型连占位提示都收不到
                    calls[j].arguments = ["omitted": .string("[早前工具调用的参数已省略，如仍需请用工具重新读取]")]
                    replaced += 1
                }
                guard replaced > 0 else { continue }
                result[i].toolCalls = calls
                let newEstimate = result[i].estimatedTokensForBudget
                total += newEstimate - estimates[i]
                estimates[i] = newEstimate
                evictedArgs += replaced
            }
        }
        guard total > budgetTokens else {
            return makeResult(result, headStart: headStart, start: start,
                              evictedToolResults: evicted, evictedToolCallArgs: evictedArgs,
                              droppedMessages: 0)
        }

        // 第二级：仍超预算，从最老一端整轮裁掉（不裁进保护尾部；
        // 边界不能落在 tool 消息上——它连同前面的 assistant(toolCalls) 一起整轮丢弃）。
        // 保护尾部即使超预算也不再牺牲：那是本轮对话的进行时上下文。
        while total > budgetTokens, start < protectedFrom {
            total -= estimates[start]
            start += 1
            while start < protectedFrom, result[start].role == .tool {
                total -= estimates[start]
                start += 1
            }
        }
        // 预算裁剪的终点可以是 assistant（ Anthropic 会 400）：再做一次首条对齐。
        // 有钉住的 user 头部时最终首条已是该 user，无需（也不能）对齐。
        if !headEndsWithUser {
            alignStartToUser(result, start: &start, protectedFrom: protectedFrom,
                             total: &total, estimates: estimates)
        }

        return makeResult(result, headStart: headStart, start: start,
                          evictedToolResults: evicted, evictedToolCallArgs: evictedArgs,
                          droppedMessages: start - alignedStart)
    }

    /// 把裁剪起点向后对齐到 user 消息：发给后端的首条（非 system）必须是 user。
    /// assistant(toolCalls) 与其后连续的 tool 结果整组丢弃，保持配对完整。
    /// 对齐不越过保护边界——保护尾部自身若以 assistant 开头则原样保留
    /// （无法在不牺牲最近上下文的前提下修复，属旧数据边缘情形）。
    private static func alignStartToUser(
        _ result: [AgentMessage], start: inout Int, protectedFrom: Int,
        total: inout Int, estimates: [Int]
    ) {
        while start < protectedFrom, result[start].role != .user {
            total -= estimates[start]
            start += 1
            while start < protectedFrom, result[start].role == .tool {
                total -= estimates[start]
                start += 1
            }
        }
    }

    /// 组装裁剪结果；被淘汰后又遭整轮裁掉的占位不再计入提示数（避免对用户虚报）。
    /// droppedMessages 只含为预算真正裁掉的条数（首条对齐的静默修正不计）。
    private static func makeResult(
        _ result: [AgentMessage], headStart: Int, start: Int,
        evictedToolResults: Int, evictedToolCallArgs: Int, droppedMessages: Int
    ) -> TrimResult {
        let finalMessages = Array(result[0..<headStart]) + Array(result[start...])
        let remainingEvicted = finalMessages.reduce(0) {
            $0 + ($1.role == .tool && $1.content == toolResultPlaceholder ? 1 : 0)
        }
        let remainingEvictedArgs = finalMessages.reduce(0) {
            $0 + ($1.toolCalls ?? []).filter { $0.rawArgumentsJSON == toolCallArgsPlaceholder }.count
        }
        return TrimResult(
            messages: finalMessages,
            evictedToolResults: remainingEvicted,
            evictedToolCallArgs: remainingEvictedArgs,
            droppedMessages: droppedMessages
        )
    }
}

extension AgentMessage {
    /// 上下文预算/横幅共用的 token 估算：content 之外把 assistant toolCalls 的
    /// 参数 JSON 一并计入——一次 write_document 大文件写入的参数可达数万字符，
    /// 只算 content 会让这部分体积永久滞留历史且对预算不可见。
    var estimatedTokensForBudget: Int {
        var total = AIConversation.estimateTokens(content)
        for call in toolCalls ?? [] {
            total += AIConversation.estimateTokens(call.argumentsJSONForReplay)
        }
        return total
    }
}
