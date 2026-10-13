import Foundation
import Observation

// MARK: - AgentRunner

/// Manages the multi-turn agent loop: AI decides → calls tools → gets results → continues.
/// Observable so views can bind to its state.
/// Backend is injected via factory closure — easy to mock in tests.
@MainActor
@Observable
final class AgentRunner {

    // MARK: - Owned run state

    /// 该次运行的可观测状态。生命周期独立于 Runner：Runner 完成后外层可保留它展示历史步骤。
    let state: AgentRunState

    // MARK: - State (forwarded to state)

    var steps: [AgentRunnerStep] {
        get { state.steps }
        set { state.steps = newValue }
    }
    var isRunning: Bool {
        get { state.isRunning }
        set { state.isRunning = newValue }
    }
    var finalText: String {
        get { state.finalText }
        set { state.finalText = newValue }
    }
    var error: String? {
        get { state.error }
        set { state.error = newValue }
    }
    var wasTruncated: Bool {
        get { state.wasTruncated }
        set { state.wasTruncated = newValue }
    }
    /// 运行完成后暴露的完整 AgentMessage 列表（含工具调用上下文）
    private(set) var finalMessages: [AgentMessage] = []

    /// 当前 step 的流式累积文本；onChunk 始终回调「累积全文」而非增量 delta，
    /// 让 UI 侧可直接赋值显示（无需自行拼接）。
    private var streamAccumulated = ""
    /// 上次 onChunk 推送时间：delta 每次都累积，但 UI 回调按 ≥50ms 合批
    /// （同 AIClient.streamTask 思路），避免高速流式时主队列洪峰。
    private var lastStreamFlush: Date = .distantPast

    /// 流式 chunk 回调（主线程，可选）
    var onChunk: (@MainActor (String) -> Void)? = nil
    /// 完成回调（主线程，isRunning 已设为 false）
    var onComplete: (@MainActor () -> Void)? = nil

    // MARK: - Config

    private let maxSteps: Int
    /// Backend factory，默认从 AIConfig 创建；测试时可注入 mock
    private let backendFactory: @Sendable (AIConfig) -> any AgentBackend
    private var runTask: Task<Void, Never>? = nil
    /// 当前 run 的 context：cancel() 需要经它解除挂起的命令/写入确认——工具确认与
    /// 写审阅的 continuation 不响应 Task 取消，必须显式 reject，否则 run 卡到超时，
    /// 且取消后用户在 diff 视图点「全部接受」时写入仍会落盘。
    private var activeContext: (any AgentContextProtocol)? = nil

    /// 停滞检测阈值（规则 1）：相同 (工具名, 参数) 的调用连续失败达到该次数即中断 run。
    /// 3 = 给模型两次换参数/换思路的机会，第三次原样失败基本可判定卡住。
    private static let stallThreshold = 3

    /// 停滞检测阈值（规则 2）：连续该步数内「本步所有工具调用都失败」即中断。
    /// 规则 1 只认**相同参数**的重复失败，模型每次微调一点参数就完全绕过；
    /// 连续 4 步无一成功是更强的卡死信号。
    private static let allFailedStepThreshold = 4

    /// 停滞检测阈值（规则 3）：连续该步数内「没有任何新结果」即中断。
    /// 覆盖规则 1 管不到的另一种盲区——调用**成功但无进展**：反复读到相同内容、
    /// 反复把同一段写回去。这类行为不报错，却能烧满 maxSteps。
    private static let noProgressStepThreshold = 4

    /// 可并行执行的只读工具：纯查询、无副作用（不写文档/文件、不动编辑器 UI、
    /// 不弹确认框）。新增工具默认走串行（安全缺省），确认无副作用后才加入此清单。
    /// run_command 永不加入：确认弹框并行会乱。
    private static let parallelReadOnlyTools: Set<String> = [
        "read_document", "search_document",
        "list_files", "read_file", "search_workspace",
        "get_html_template", "load_skill",
    ]

    /// 运行代际计数：cancel() 会同步放行 isRunning，但旧 _run 可能仍卡在不可取消点
    /// （如工具确认 continuation），此时新 run() 能通过 guard 启动，两个 _run 共享
    /// state/回调。每次 runMessages 递增 generation，旧 _run 发现代际不匹配时静默
    /// 放弃收尾，避免覆盖新 run 的 finalMessages/isRunning 或触发旧 onComplete。
    private var runGeneration = 0

    /// 总执行超时（秒），0 = 不限。默认 5 分钟。
    var timeoutSeconds: TimeInterval = 300

    /// 发给后端的上下文预算（token 估算值）：超出时对线上副本做预算裁剪，
    /// 本地 messages（最终写入持久化历史）保持完整。测试可调小以覆盖裁剪路径。
    var contextBudgetTokens = AgentHistoryBudget.defaultBudgetTokens

    /// 上下文预算淘汰回调（每次 run 首次发生淘汰时触发一次）：UI 据此在 transcript
    /// 给出 subtle 提示，不让淘汰静默发生。
    var onContextEviction: (@MainActor (AgentHistoryBudget.TrimResult) -> Void)? = nil

    /// lastThinkingIndex 缓存，O(1) 更新/删除 thinking step
    private var lastThinkingIndex: Int? = nil

    init(
        maxSteps: Int = 30,
        // 用 @Sendable 闭包字面量包一层：直接引用函数值会被判为「非 Sendable 函数值转换」。
        backendFactory: @escaping @Sendable (AIConfig) -> any AgentBackend = { AgentBackendFactory.make(config: $0) }
    ) {
        self.state = AgentRunState()
        self.maxSteps = maxSteps
        self.backendFactory = backendFactory
    }

    // MARK: - Run

    func run(
        systemPrompt: String,
        userMessage: String,
        tools: [any AgentTool],
        config: AIConfig,
        context: any AgentContextProtocol
    ) {
        let messages: [AgentMessage] = [
            AgentMessage(role: .system, content: systemPrompt),
            AgentMessage(role: .user,   content: userMessage)
        ]
        runMessages(messages, tools: tools, config: config, context: context)
    }

    /// 带已有历史消息继续运行（多轮对话）
    func run(
        messages: [AgentMessage],
        tools: [any AgentTool],
        config: AIConfig,
        context: any AgentContextProtocol
    ) {
        runMessages(messages, tools: tools, config: config, context: context)
    }

    private func runMessages(
        _ messages: [AgentMessage],
        tools: [any AgentTool],
        config: AIConfig,
        context: any AgentContextProtocol
    ) {
        guard !isRunning else { return }

        // Agent Skills（渐进披露）：每次 run 开始重扫技能目录（目录很小，直接重扫，
        // 天然覆盖工作区切换与目录内容变更），再把「名称 + 描述 + 来源」的目录段追加到
        // system 消息——技能正文不进系统提示，模型按需经 load_skill 工具拉取。
        // 仅当本次 run 注册了 load_skill 才注入：slash 命令等按 allowedTools 过滤工具的
        // 路径没有该工具，注入目录会让模型去调不存在的工具。
        // 目录为空时系统提示零改动（回归保证）；消息列表没有 system 消息时跳过注入。
        var prepared = messages
        if tools.contains(where: { $0.spec.name == "load_skill" }) {
            let skillStore = AgentSkillStore.shared
            skillStore.refresh(workspaceURL: context.workspaceURL)
            if let section = skillStore.catalogPromptSection(),
               let sysIndex = prepared.firstIndex(where: { $0.role == .system }) {
                prepared[sysIndex].content += section
            }
        }
        let messages = prepared

        runGeneration += 1
        let generation = runGeneration

        steps              = []
        finalText          = ""
        error              = nil
        wasTruncated       = false
        state.stall        = nil
        state.usage        = nil
        state.modelName    = config.model   // 成本估算用（UI 查价格表）
        state.runDurationSeconds = nil
        state.termination  = .running
        lastThinkingIndex  = nil
        isRunning          = true
        activeContext      = context   // cancel() 经它解除挂起的确认/审阅

        runTask = Task { [weak self] in
            guard let self else { return }
            guard self.timeoutSeconds > 0 else {
                await self._run(messages: messages, tools: tools, config: config, context: context, generation: generation)
                return
            }
            // 两个 Task 赛跑：_run 和超时计时器，任一完成则 cancel 另一个
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await self._run(messages: messages, tools: tools, config: config, context: context, generation: generation)
                    return false   // 正常完成
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(self.timeoutSeconds))
                    } catch {
                        return false   // 被 cancel：主任务已完成，不触发超时
                    }
                    return true   // 超时
                }
                // 代际校验：旧 run 的超时计时器晚到时，state 可能已被新 run 接管，
                // 不得把新 run 误判为超时
                if let timedOut = await group.next(), timedOut, self.isRunning,
                   self.runGeneration == generation {
                    self.error     = "操作超时（\(Int(self.timeoutSeconds))s），请重试或简化任务"
                    self.state.termination = .failed   // 超时可断点续传
                    self.isRunning = false
                    self.runTask   = nil
                    // 拒绝挂起的命令确认：恢复工具内 withCheckedContinuation，否则确认框
                    // 弹出期间超时会让 _run 永不结束（reject 幂等，与 cancelStreaming 不冲突）
                    context.cancelPendingCommandConfirmation()
                    context.cancelPendingWriteConfirmation()
                    // onComplete 不在此处调用 —— _run 的 cleanup 必然执行并统一触发
                    // (group.cancelAll 后 withTaskGroup 会等待 _run 响应取消并结束)
                }
                group.cancelAll()
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        // 注意：这里不递增 runGeneration。cancel 后 _run 仍应走到收尾并触发 onComplete
        // （否则调用方 isResponding 永远为 true）；只有「新 run 启动」才递增 generation
        // 来让旧 run 收尾失效。旧 run 在 await 之后的写入由 _run 内的
        // `generation == runGeneration, !Task.isCancelled` 复核拦住。
        // 解除挂起的命令确认 / 写入确认 / 写审阅：工具可能卡在这些 continuation 上
        //（不响应 Task 取消），不显式 reject 的话 run 会卡到超时，且取消后用户在
        // diff 视图点「全部接受」时写入仍会落盘。reject/dismiss 均幂等，与 _run
        // 收尾和超时路径的兜底调用不冲突（先到先生效）。
        activeContext?.cancelPendingCommandConfirmation()
        activeContext?.cancelPendingWriteConfirmation()
        // 立即置为未运行：不把状态复位会导致 UI 一直停在"运行中"。
        // 之后 _run 的 cleanup 会再次幂等地走一遍收尾流程。
        isRunning = false
        // 用户主动取消：不提供断点续传入口（cleanup 不得覆盖此标记）
        state.termination = .cancelled
        if finalText.isEmpty && error == nil {
            error = "已取消"
        }
    }

    // MARK: - Core loop

    private func _run(
        messages initialMessages: [AgentMessage],
        tools: [any AgentTool],
        config: AIConfig,
        context: any AgentContextProtocol,
        generation: Int
    ) async {
        let backend = backendFactory(config)  // nonisolated factory, safe to call from task
        var messages = initialMessages
        /// run 级起始时间：收尾时写入 state.runDurationSeconds 供 UI 展示总耗时
        let runStartedAt = Date()

        addThinking(label: "AI 思考中…")

        var stepCount = 0

        // 停滞检测状态：跟踪最近一次失败的 (工具名, 参数) 指纹及连续失败次数。
        // 模型反复用相同参数调同一个失败工具时会烧满 maxSteps 才报"超过最大步数"，
        // 这里在「相同调用连续失败达阈值」时提前中断，错误文案指出具体工具。
        // 只读工具同样适用（如反复 read 不存在的文件）。
        var lastFailureFingerprint: String? = nil
        var consecutiveFailures = 0
        var stalled = false
        /// 步级停滞检测状态（规则 2 / 3，见 evaluateStepStall）
        var allFailedStreak = 0
        var noProgressStreak = 0
        /// 本 run 内已出现过的工具结果签名，用于规则 3 判定「有无新进展」
        var seenOutcomes: Set<String> = []
        /// 每次 run 只向 UI 报告一次预算淘汰（后续 step 再淘汰不再重复提示）
        var evictionNotified = false

        while stepCount < maxSteps {
            stepCount += 1
            guard !Task.isCancelled else { break }
            // 代际已易主（cancel 后新 run 启动）：直接走向收尾，收尾会静默放弃，
            // 避免旧 run 继续往共享 state 追加 step 或再发后端请求
            guard generation == runGeneration else { break }

            do {
                streamAccumulated = ""   // 每个 step 重置，reply 只显示当前轮累积文本
                lastStreamFlush = .distantPast   // 每个 step 的首个 delta 立即显示

                // 上下文预算裁剪：只作用于发给后端的线上副本，本地 messages
                //（最终写入持久化历史）保持完整。早期长 tool 结果先替换为占位符，
                // 仍超预算才整轮裁最老历史（tool_call/tool_result 配对保持，见 AgentHistoryBudget）。
                let outgoing = AgentHistoryBudget.trim(messages, budgetTokens: contextBudgetTokens)
                if outgoing.didTrim, !evictionNotified {
                    evictionNotified = true
                    onContextEviction?(outgoing)
                }

                let response = try await backend.completeStreaming(
                    messages: outgoing.messages,
                    tools: tools,
                    onTextChunk: { [weak self] chunk in
                        // 用 DispatchQueue.main.async 而非 Task { @MainActor }：
                        // main queue 严格 FIFO，chunk 按到达顺序应用；
                        // Task 调度顺序不保证，高速流式下累积文本可能乱序。
                        DispatchQueue.main.async { [weak self] in
                            // guard 必须与本闭包的 [weak self] 同层：
                            // 在嵌套 @Sendable 闭包里解包外层 weak 捕获，
                            // 新版编译器会报 captured var 硬错误。
                            guard let self else { return }
                            MainActor.assumeIsolated {
                                self.streamAccumulated += chunk          // 累积 delta
                                // onChunk 按 ≥50ms 合批：不每个 delta 都触发一次 UI 更新
                                let now = Date()
                                if now.timeIntervalSince(self.lastStreamFlush) > 0.05 {
                                    self.lastStreamFlush = now
                                    self.onChunk?(self.streamAccumulated)     // 回调累积全文
                                }
                            }
                        }
                    }
                )

                // 冲刷节流残余：把累积全文最后推一次。与 chunk 同走 main queue（FIFO），
                // 保证在最后一批 delta 之后执行；最终回复随后还会由 onChunk?(response.text) 覆盖。
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        guard !self.streamAccumulated.isEmpty else { return }
                        self.lastStreamFlush = Date()
                        self.onChunk?(self.streamAccumulated)
                    }
                }

                // 代际/取消复核（H4）：completeStreaming 期间可能已 cancel 或被新 run
                // 接管；循环顶的检查在这一轮 await 之前，覆盖不到这里。此时再改
                // wasTruncated/usage/steps 会污染新 run。
                guard generation == runGeneration, !Task.isCancelled else { break }

                // 输出被 max_tokens 截断：置位标记由 UI 提示，不自动续跑（避免死循环）
                if response.finishReason == "length" || response.finishReason == "max_tokens" {
                    wasTruncated = true
                }

                // token 用量累计：各 step 的 usage 求和，供 run 结束后 UI 透出。
                // 后端不返回 usage（如 ClaudeCLI 子进程）时保持 nil，UI 降级不显示。
                if let stepUsage = response.usage {
                    state.usage = (state.usage ?? AgentUsage()) + stepUsage
                }

                if !response.toolCalls.isEmpty {
                    removeLastThinking()

                    messages.append(AgentMessage(
                        role: .assistant,
                        content: response.text,
                        toolCalls: response.toolCalls
                    ))

                    let calls = response.toolCalls
                    /// 各 call 的执行结果/耗时，按 response.toolCalls 原顺序索引。
                    /// 执行可并行/乱序完成，但回灌 messages 与步骤 UI 必须按原顺序，
                    /// 保证 tool result 与 assistant 消息里 tool_calls 的配对合法。
                    var results:   [AgentToolResult?] = Array(repeating: nil, count: calls.count)
                    var durations: [TimeInterval?]    = Array(repeating: nil, count: calls.count)
                    var cancelled = false

                    // 步骤面板按原顺序一次性注册全部调用：并行执行期间面板能展示完整
                    // 计划，且后续 markToolCallDone 只做原地状态过渡、步骤不跳动。
                    for call in calls {
                        addToolCall(id: call.id, name: call.name, args: prettyArgs(call.arguments))
                    }

                    // 分组：纯查询的只读工具并行执行；写工具与短路分支（参数解析失败 /
                    // _parse_error / 未知工具）保持串行。取舍：同一轮读写混合时先并行跑完
                    // 只读、再按原相对顺序串行跑写——模型同一轮先读后写是常态，先跑读不
                    // 破坏「读到写前状态」的语义（反过来先写后读才会）。run_command 不在
                    // 只读清单内，永不并行（确认弹框会乱）。
                    let readIndices = calls.indices.filter { Self.isParallelReadOnly(calls[$0], tools: tools) }
                    let readIndexSet = Set(readIndices)

                    // 只读组：task group 并行执行，省去多个只读调用串行的多次 RTT。
                    // 取消会传播给子任务；group 会等所有已启动的子任务收尾后
                    // 才返回，不会出现「run 结束了工具还在执行」的悬挂写。
                    if !readIndices.isEmpty && !Task.isCancelled {
                        try await withThrowingTaskGroup(of: (Int, AgentToolResult, TimeInterval).self) { group in
                            for i in readIndices {
                                let call = calls[i]
                                // isParallelReadOnly 已保证工具存在且参数解析成功
                                guard let tool = tools.first(where: { $0.spec.name == call.name }) else { continue }
                                group.addTask {
                                    let startedAt = Date()
                                    let result: AgentToolResult
                                    do {
                                        let output = try await tool.execute(arguments: call.arguments, context: context)
                                        result = AgentToolResult(toolCallID: call.id, toolName: call.name, content: output)
                                    } catch {
                                        result = AgentToolResult(
                                            toolCallID: call.id, toolName: call.name,
                                            content: "错误：\(error.localizedDescription)", isError: true
                                        )
                                    }
                                    return (i, result, Date().timeIntervalSince(startedAt))
                                }
                            }
                            for try await (i, result, duration) in group {
                                results[i]   = result
                                durations[i] = duration
                            }
                            // 批结束后检查取消（withTaskGroup 非 throwing 不能逐个透传）：
                            // 被取消时丢弃整批结果抛出 CancellationError，与串行路径一致，
                            // 避免误导性的「错误：cancelled」工具结果回灌历史
                            if Task.isCancelled { throw CancellationError() }
                        }
                        // 步骤 UI 按原顺序统一标记完成：结果可乱序到达，但 state 更新
                        // 保持可预期顺序，避免步骤面板乱跳
                        for i in readIndices {
                            if let result = results[i] {
                                markToolCallDone(id: calls[i].id, result: result, durationSeconds: durations[i])
                            }
                        }
                        // 停滞记账（只读组，按原相对顺序）：达阈值则本轮写工具不再执行
                        for i in readIndices {
                            guard let result = results[i] else { continue }
                            if recordStallIfNeeded(call: calls[i], result: result,
                                                   lastFailureFingerprint: &lastFailureFingerprint,
                                                   consecutiveFailures: &consecutiveFailures) {
                                stalled = true
                                break
                            }
                        }
                    }

                    // 写组/短路组：保持串行与原分支逻辑（写确认弹框依赖串行挂起语义）
                    if !stalled {
                        for i in calls.indices where !readIndexSet.contains(i) {
                            guard !Task.isCancelled else { cancelled = true; break }
                            let call = calls[i]

                            var result: AgentToolResult
                            /// 工具实际执行耗时（仅真实执行分支有值，存入 step 供 UI/排查用）
                            var duration: TimeInterval? = nil
                            if let parseError = call.argumentsParseError {
                                // 参数 JSON 非法（对所有后端生效，同 ClaudeCLIBackend 的 _parse_error）：
                                // 跳过执行，直接回灌错误，让模型重新生成合法 JSON
                                let raw = call.rawArgumentsJSON ?? ""
                                result = AgentToolResult(
                                    toolCallID: call.id,
                                    toolName:   call.name,
                                    content: "工具 '\(call.name)' 的参数 JSON 解析失败（\(parseError)），未执行。\n原始参数：\(raw.prefix(200))\n请重新生成合法的 JSON 参数后再调用该工具。",
                                    isError: true
                                )
                            } else if call.name == "_parse_error" {
                                // ClaudeCLIBackend 注入的占位工具：JSON 解析失败，让 AI 看到错误后重试
                                let args     = call.arguments
                                let original = args["original_tool"]?.stringValue ?? "unknown"
                                let rawArgs  = args["raw_arguments"]?.stringValue ?? ""
                                result = AgentToolResult(
                                    toolCallID: call.id,
                                    toolName:   original,
                                    content: "[X] Tool call '\(original)' failed: arguments JSON could not be parsed.\nRaw: \(rawArgs.prefix(200))\nPlease retry with properly formatted JSON arguments.",
                                    isError: true
                                )
                            } else if let tool = tools.first(where: { $0.spec.name == call.name }) {
                                let startedAt = Date()
                                do {
                                    let output = try await tool.execute(arguments: call.arguments, context: context)
                                    result = AgentToolResult(toolCallID: call.id, toolName: call.name, content: output)
                                } catch {
                                    // 取消不是工具失败：直接抛给外层 catch（break 走向收尾，
                                    // 缺口由 reconcileToolResults 补合成中断结果），不包装成
                                    // 误导性的 tool error 回灌历史、也不计入停滞指纹。
                                    if Self.isCancellation(error) { throw error }
                                    result = AgentToolResult(
                                        toolCallID: call.id, toolName: call.name,
                                        content: "错误：\(error.localizedDescription)", isError: true
                                    )
                                }
                                duration = Date().timeIntervalSince(startedAt)
                            } else {
                                result = AgentToolResult(
                                    toolCallID: call.id, toolName: call.name,
                                    content: "未找到工具：\(call.name)", isError: true
                                )
                            }

                            results[i]   = result
                            durations[i] = duration
                            markToolCallDone(id: call.id, result: result, durationSeconds: duration)

                            if recordStallIfNeeded(call: call, result: result,
                                                   lastFailureFingerprint: &lastFailureFingerprint,
                                                   consecutiveFailures: &consecutiveFailures) {
                                stalled = true
                                break
                            }
                        }
                    }
                    // 并行只读批期间到达的取消：串行组首条 guard 已覆盖；全部只读且
                    // 无串行成员时在这里兜底，保证取消后不再追加 thinking 直接进入收尾
                    if Task.isCancelled { cancelled = true }

                    // 按原顺序回灌 tool result（配对合法性）；取消/停滞造成的空缺由
                    // 收尾 reconcileToolResults 统一补合成结果
                    for i in calls.indices {
                        guard let result = results[i] else { continue }
                        messages.append(AgentMessage(
                            role: .tool,
                            content: result.content,
                            toolCallID: result.toolCallID,
                            toolName: result.toolName
                        ))
                    }

                    if cancelled || stalled { break }

                    // 步级停滞检测（规则 2 / 3）：补规则 1 的两个盲区（换参反复失败、
                    // 成功但无进展）。只在整步结果齐全时评估——取消/规则 1 中断截断的
                    // 半成品步不做判断，避免把「没跑完」误判成「没进展」。
                    if !calls.isEmpty, results.allSatisfy({ $0 != nil }),
                       evaluateStepStall(calls: calls, results: results.compactMap { $0 },
                                         allFailedStreak: &allFailedStreak,
                                         noProgressStreak: &noProgressStreak,
                                         seenOutcomes: &seenOutcomes) {
                        stalled = true
                        break
                    }

                    addThinking(label: "AI 处理结果…")
                    continue

                } else {
                    removeLastThinking()
                    finalText = response.text
                    onChunk?(response.text)
                    messages.append(AgentMessage(role: .assistant, content: response.text))
                    break
                }
            } catch {
                // 取消（含底层 cause 是 CancellationError 的包装错误）走向收尾，
                // 不归类为 run 错误
                if Self.isCancellation(error) { break }
                removeLastThinking()
                self.error = classifyError(error)
                break
            }
        }

        // 代际校验（cancel/新 run 竞态修复）：本 _run 若曾在 cancel 后卡在不可取消点
        //（如工具确认 continuation），期间新 run 已启动并接管 state。旧 run 的收尾
        // 必须静默放弃——不写 finalMessages、不重置 isRunning/runTask、不触发旧
        // onComplete，否则会覆盖新 run 的运行状态。
        guard generation == runGeneration else { return }

        // 仅当循环耗尽且既无最终答案也无更具体错误时才报步数超限：
        // 最终答案恰好在第 maxSteps 轮拿到时不应误报错误
        if stepCount >= maxSteps && finalText.isEmpty && error == nil {
            self.error = "Agent 执行超过最大步数（\(maxSteps)）"
        }

        // 异常结束（cancel/timeout/error）时，为未应答的 tool call 补合成 error tool result，
        // 保证 tool_calls 与 tool result 严格配对，避免坏历史下一轮被 API 400 拒绝
        messages = reconcileToolResults(messages)

        finalMessages     = messages
        isRunning         = false
        lastThinkingIndex = nil
        runTask           = nil
        activeContext     = nil
        // 结束方式分类：用户取消（cancel 已标记）不覆盖；其余按有无错误归类——
        // UI 据此决定是否在错误旁提供「从中断处继续」（仅 .failed 可续跑）
        if state.termination != .cancelled {
            state.termination = (error == nil) ? .completed : .failed
        }
        state.runDurationSeconds = Date().timeIntervalSince(runStartedAt)
        // 正常结束也拒绝挂起的命令确认（幂等），兜底防 continuation 泄漏
        context.cancelPendingCommandConfirmation()
        context.cancelPendingWriteConfirmation()
        onComplete?()
    }

    // MARK: - Step management（O(1) thinking 操作）

    private func addThinking(label: String) {
        let step = AgentRunnerStep.thinking(label: label)
        lastThinkingIndex = steps.count
        steps.append(step)
    }

    private func removeLastThinking() {
        guard let idx = lastThinkingIndex, idx < steps.count else { return }
        if case .thinking = steps[idx] {
            steps.remove(at: idx)
            // 移除后，后续 toolCall 的 index 不变（thinking 总在末尾追加）
        }
        lastThinkingIndex = nil
    }

    private func addToolCall(id: String, name: String, args: String) {
        steps.append(.toolCall(id: id, name: name, args: args))
    }

    private func markToolCallDone(id: String, result: AgentToolResult, durationSeconds: TimeInterval? = nil) {
        // toolCall 在 steps 末尾，从末尾往前找，通常 O(1)
        guard let idx = steps.indices.last(where: {
            if case .toolCall(let cid, _, _) = steps[$0], cid == id { return true }
            return false
        }) else { return }
        steps[idx] = .toolCallDone(
            id: id,
            name: result.toolName,
            args: "",
            result: result.content,
            isError: result.isError,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Helpers

    /// 判断错误是否为取消信号：直接的 CancellationError，或底层 cause 链上
    /// 含 CancellationError 的包装错误（如工具内部把子任务错误重新封装抛出）。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as NSError).underlyingErrors.contains { isCancellation($0) }
    }

    /// 将后端错误分类为统一的中文可操作文案；未识别的错误保留原始信息
    private func classifyError(_ error: Error) -> String {
        if let aiError = error as? AIError, case .server(let code, _) = aiError {
            switch code {
            case 401, 403: return "鉴权失败（HTTP \(code)），请检查 API Key 是否正确"
            case 429:      return "请求过于频繁或额度不足（HTTP 429），请稍后重试"
            default:       break
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return "请求超时，请检查网络连接后重试"
            }
            return "网络连接失败：\(urlError.localizedDescription)"
        }
        return error.localizedDescription
    }

    /// 判断该调用是否可进入并行只读批：工具在只读清单内、参数解析成功、且工具已注册。
    /// 参数解析失败 / _parse_error / 未知工具一律走串行短路分支，保持原有语义。
    private static func isParallelReadOnly(_ call: AgentToolCall, tools: [any AgentTool]) -> Bool {
        guard parallelReadOnlyTools.contains(call.name) else { return false }
        guard call.argumentsParseError == nil else { return false }
        return tools.contains { $0.spec.name == call.name }
    }

    /// 停滞记账：相同 (工具名, 参数) 指纹的失败连续出现达阈值即判定停滞、写错误并返回 true。
    /// 成功调用重置计数（只有「连续」的相同失败才算停滞）。
    /// 指纹序列按执行顺序（先只读批、后串行批）记账，与「先跑读再跑写」的执行取舍一致。
    private func recordStallIfNeeded(
        call: AgentToolCall,
        result: AgentToolResult,
        lastFailureFingerprint: inout String?,
        consecutiveFailures: inout Int
    ) -> Bool {
        guard result.isError else {
            lastFailureFingerprint = nil
            consecutiveFailures = 0
            return false
        }
        // 指纹用排序键的 JSON，保证参数顺序无关
        let fingerprint = stallFingerprint(call)
        if fingerprint == lastFailureFingerprint {
            consecutiveFailures += 1
        } else {
            lastFailureFingerprint = fingerprint
            consecutiveFailures = 1
        }
        guard consecutiveFailures >= Self.stallThreshold else { return false }
        let summary = Self.firstLine(result.content, maxLength: 120)
        state.stall = AgentStallDiagnostic(
            toolName: call.name,
            repeatCount: consecutiveFailures,
            lastErrorSummary: summary
        )
        error = "Agent 在工具 '\(call.name)' 上停滞：相同调用已连续失败 \(consecutiveFailures) 次（最后错误：\(summary)）。已中断运行，请检查该工具的输入或换个说法重试。"
        return true
    }

    /// 停滞检测用的调用指纹：工具名 + 排序键参数 JSON。
    /// AnySendableValue.anyValue 产出的都是 JSON 安全类型（含 NSNull），序列化不会失败；
    /// 失败时退化为「工具名|?」，仍能保证相同工具重复失败可被检测到。
    private func stallFingerprint(_ call: AgentToolCall) -> String {
        let raw = call.arguments.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "\(call.name)|?" }
        return "\(call.name)|\(json)"
    }

    /// 步级停滞检测（规则 2 / 3），达阈值时写 `state.stall` + `error` 并返回 true。
    ///
    /// 规则 1（recordStallIfNeeded）只认「**相同** (工具名, 参数) 连续失败」，留下两个
    /// 能烧满 maxSteps 却报「超过最大步数」的盲区：
    ///   - 规则 2（换参反复失败）：模型每次微调一点参数，指纹每次都不同，规则 1 永不触发。
    ///     判据改为「本步**所有**工具调用都失败」并连续达阈值。
    ///   - 规则 3（成功但无进展）：调用都成功、结果却全是此 run 已出现过的内容
    ///     （反复读同一文件、反复写回同一段）。判据是「本步没有任何新结果签名」。
    ///
    /// 只在整步结果齐全时调用，取消/中断截断的半成品步不参与，避免把「没跑完」
    /// 误判成「没进展」。规则 3 用结果哈希而非全文比较：结果内容漂移（含时间戳等）
    /// 会被保守地当作「有新进展」，宁漏报不误杀。
    private func evaluateStepStall(
        calls: [AgentToolCall],
        results: [AgentToolResult],
        allFailedStreak: inout Int,
        noProgressStreak: inout Int,
        seenOutcomes: inout Set<String>
    ) -> Bool {
        guard !results.isEmpty else { return false }

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

        // 涉及的工具名（去重排序），供诊断与文案使用
        let tools = Set(calls.map(\.name)).sorted().joined(separator: "、")

        if allFailedStreak >= Self.allFailedStepThreshold {
            let summary = Self.firstLine(results.last?.content ?? "", maxLength: 120)
            state.stall = AgentStallDiagnostic(
                toolName: tools, repeatCount: allFailedStreak, lastErrorSummary: summary
            )
            error = "Agent 连续 \(allFailedStreak) 步的工具调用全部失败（涉及：\(tools)）。"
                + "已中断运行——反复换参数仍失败通常意味着前提假设不成立，请检查输入或换个说法重试。"
                + "（最后一次错误：\(summary)）"
            return true
        }

        if noProgressStreak >= Self.noProgressStepThreshold {
            state.stall = AgentStallDiagnostic(
                toolName: tools, repeatCount: noProgressStreak,
                lastErrorSummary: "连续 \(noProgressStreak) 步未产生新结果"
            )
            error = "Agent 连续 \(noProgressStreak) 步没有任何有效进展：工具返回的都是此前已出现过的结果"
                + "（涉及：\(tools)），反复读写同一内容不会推进任务。已中断运行，请换个说法重试。"
            return true
        }

        return false
    }

    /// 工具结果签名：工具名 + 是否错误 + 结果内容哈希。
    /// 用哈希而非全文，避免把每个大 tool 结果（单条可达 64K 字符）都常驻内存；
    /// 进程内哈希稳定，够本 run 内做「是不是老结果」的判定。
    private static func outcomeSignature(_ result: AgentToolResult) -> String {
        "\(result.toolName)|\(result.isError ? "E" : "O")|\(result.content.hashValue)"
    }

    /// 取首行并按长度截断，供错误摘要使用（停滞诊断 / 文案）。
    private static func firstLine(_ s: String, maxLength: Int) -> String {
        let line = s.components(separatedBy: "\n").first ?? s
        return line.count > maxLength ? String(line.prefix(maxLength)) + "…" : line
    }

    /// 为没有对应 tool result 的 tool call 追加合成的中断结果（紧跟其 assistant 消息之后），
    /// 保证持久化历史中 tool_calls 与 tool result 严格配对
    private func reconcileToolResults(_ messages: [AgentMessage]) -> [AgentMessage] {
        let answered = Set(messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        var result: [AgentMessage] = []
        for message in messages {
            result.append(message)
            guard message.role == .assistant, let calls = message.toolCalls else { continue }
            for call in calls where !answered.contains(call.id) {
                result.append(AgentMessage(
                    role: .tool,
                    content: "错误：运行被中断，该工具调用未执行。",
                    toolCallID: call.id,
                    toolName: call.name
                ))
            }
        }
        return result
    }

    private func prettyArgs(_ args: [String: AnySendableValue]) -> String {
        guard !args.isEmpty else { return "{}" }
        // 将 AnySendableValue 还原为 Any 用于 JSON 序列化
        let raw = args.reduce(into: [String: Any]()) { dict, pair in
            dict[pair.key] = pair.value.anyValue
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str.count > 200 ? String(str.prefix(200)) + "…" : str
    }
}
