import Foundation

/// AI 助手面板业务协调器。
///
/// 承载原本写在 `AIAssistantPanel`（SwiftUI View）私有方法里的纯业务逻辑：
/// 请求编排（`runCompletion`）、AgentRunner 启动（`launchAgentRunner`）、
/// system prompt 构建（`systemContext`）。纯搬运、不改行为（prompt 文本逐字保留、
/// 调用时序保留），View 侧只保留绑定与回调。依赖经 init 注入，便于测试。
@MainActor
final class AIChatCoordinator {
    private let settings: AppSettings
    private let convo: AIConversation
    private let state: AppState

    init(settings: AppSettings, conversation: AIConversation, appState: AppState) {
        self.settings = settings
        self.convo = conversation
        self.state = appState
    }

    /// 助手面板走 AgentRunner（带工具调用能力），兼容流式文本回退。
    /// - Parameter includeAutoContext: 是否自动附带当前文档（输入栏 chip 与设置总开关
    ///   共同决定）；false 时本次发送不注入文档全文（选区注入不受影响）。
    func runCompletion(mentionTokens: [AtMentionToken] = [], includeAutoContext: Bool = true) {
        guard convo.messages.last?.role == .user else { return }
        convo.isResponding = true
        convo.respondingSessionID = convo.activeID

        let config  = AIConfig.current(settings, scene: .agent)
        // run 级文件快照（一键回滚）：随 run 创建，经 context 写路径填充，
        // run 结束且有写入时挂到 runState 供步骤面板提供回滚入口
        let checkpoint = AgentRunCheckpoint()
        let context = AgentContext.make(appState: state, checkpoint: checkpoint)

        // @mention 所需的主线程上下文快照（不能在 Task.detached 里访问 MainActor 属性）
        let docName    = state.selectedTab?.name
        let docContent = state.selectedTab?.content
        let wsRoot     = state.rootURL
        let wsFiles    = Array(state.fileItemMap.values)

        let userTurnCount = convo.messages.filter { $0.role == .user }.count
        let baseSys = systemContext(includeFullDoc: userTurnCount == 1 && includeAutoContext)
        let mcpManager = state.mcpClientManager
        // 工具预算的相关性打分输入：本轮用户原话（不进 Task 里读，避免跨 actor 取状态）
        let userQuery = convo.messages.last(where: { $0.role == .user })?.text ?? ""

        Task {
            // @mention IO 在后台执行
            let mentionCtx = await AtMentionContextBuilder.build(
                tokens: mentionTokens,
                currentDocName: docName,
                currentDocContent: docContent,
                workspaceRoot: wsRoot,
                workspaceFiles: wsFiles
            )
            var sysContent = baseSys
            if !mentionCtx.isEmpty { sysContent += mentionCtx }
            // MCP 客户端：run 开始时才懒连接有配置的 server；连接失败的降级为跳过，
            // 并把失败名单注入系统提示，让模型知道这些 mcp__ 工具本轮不可用
            var tools = BuiltinAgentTools.all
            tools.append(contentsOf: await mcpManager.refreshForAgentRun(workspaceURL: wsRoot))
            if let notice = mcpManager.modelFacingNotice { sysContent += notice }
            // 工具预算：工具定义每轮重发，MCP 挂几台就可能 40+ 条。只在有把握时裁——
            // 没命中任何查询词就原样放行（见 AgentToolBudget 的约束说明）。
            let budget = AgentToolBudget.select(tools: tools, query: userQuery)
            if let notice = budget.notice { sysContent += notice }
            tools = budget.tools
            await MainActor.run {
                launchAgentRunner(sysContent: sysContent, config: config, context: context,
                                  tools: tools, checkpoint: checkpoint)
            }
        }
    }

    private func launchAgentRunner(
        sysContent: String,
        config: AIConfig,
        context: AgentContext,
        tools: [any AgentTool],
        checkpoint: AgentRunCheckpoint
    ) {
        // 对话过长时自动截断，保留最近 10 轮对话。agentHistory 同步从最老一端滑动裁剪
        // （保持 tool_calls / tool result 配对完整），而非整体清空。
        // 注意：提示条不在这里插入——必须先构建 agentMessages（依赖「最后一条是 user」
        // 的配对判断），提示条在占位 bubble 之前追加（见下方 didTruncate 分支）。
        let didTruncate = convo.truncateIfOverLimit(keepRecentPairs: 10)

        // 构建 AgentMessage 列表：优先使用已保存的 agentHistory（保留工具调用上下文）
        var agentMessages: [AgentMessage]
        let savedHistory = convo.agentHistory
        if !savedHistory.isEmpty, let newUserMsg = convo.messages.last, newUserMsg.role == .user {
            // 用历史记录（含工具调用）+ 新的用户消息，更新 system prompt
            agentMessages = savedHistory
            if agentMessages.first?.role == .system {
                agentMessages[0] = AgentMessage(role: .system, content: sysContent)
            } else {
                agentMessages.insert(AgentMessage(role: .system, content: sysContent), at: 0)
            }
            agentMessages.append(AgentMessage(
                role: .user, content: newUserMsg.text,
                images: newUserMsg.images.isEmpty ? nil : newUserMsg.images
            ))
        } else {
            // 回退：从 AIChatMessage 重建（丢失工具调用上下文，适用于首轮或旧会话）。
            // 图片只挂在当前这条 user 消息上：历史消息的图片在会话重启后已丢弃，
            // 且不应每轮重复发送（体积/token 成本）。
            agentMessages = [AgentMessage(role: .system, content: sysContent)]
            agentMessages += convo.messages.map {
                AgentMessage(role: $0.role == .user ? .user : .assistant, content: $0.text)
            }
            if let lastUser = convo.messages.last, lastUser.role == .user,
               !lastUser.images.isEmpty, agentMessages.last?.role == .user {
                agentMessages[agentMessages.count - 1].images = lastUser.images
            }
        }

        // Claude CLI 后端是文本-only 的子进程通道，不支持图片 content block：
        // 图片不随消息发送（文字照发），并在 transcript 里给用户明确提示。
        if config.kind == .claudeCLI,
           let lastUser = convo.messages.last, lastUser.role == .user, !lastUser.images.isEmpty {
            if agentMessages.last?.role == .user {
                agentMessages[agentMessages.count - 1].images = nil
            }
            convo.messages.append(
                AIChatMessage(role: .assistant, text: L("ai.images.unsupportedBackend"))
            )
        }

        // 截断提示追加在最新用户消息之后（占位 bubble 之前）——时序上提示是对最新
        // 提问的说明；且不能插到用户消息之前，那会顶掉上面「最后一条是 user」的配对判断
        if didTruncate {
            let notice = AIChatMessage(role: .assistant, text: L("ai.notice.truncatedHistory"))
            convo.messages.append(notice)
        }

        startAgentRun(agentMessages: agentMessages, config: config, context: context,
                      tools: tools, checkpoint: checkpoint)
    }

    /// 断点续传：上次 run 因网络/超时/模型错误中断（termination == .failed）时，
    /// 复用已保存的 agent 历史（原始指令 + 已完成工具调用结果）从中断处继续，
    /// 而不是从零重来。用户取消（.cancelled）不提供续跑入口。
    func resumeInterruptedRun() {
        guard !convo.isResponding else { return }
        guard convo.lastRunState?.termination == .failed else { return }
        // includeFullDoc: false——文档全文已在历史首轮注入过，只提醒文档名
        // （成本口径与 runCompletion 的后续轮一致）
        let sysContent = systemContext(includeFullDoc: false)
        guard let agentMessages = AgentResumeContext.makeMessages(
            history: convo.agentHistory, freshSystemPrompt: sysContent
        ) else { return }

        convo.isResponding = true
        convo.respondingSessionID = convo.activeID

        let config     = AIConfig.current(settings, scene: .agent)
        // 续跑沿用失败 run 的 checkpoint（引用类型，快照累加）：回滚入口覆盖
        // 「失败 run 已落盘的写入 + 续跑的写入」完整链路；没有则新建。
        let checkpoint = convo.lastRunState?.checkpoint ?? AgentRunCheckpoint()
        let context    = AgentContext.make(appState: state, checkpoint: checkpoint)
        // MCP 工具与首发路径同一来源：续跑同样走懒连接 + 失败降级
        Task {
            var tools = BuiltinAgentTools.all
            tools.append(contentsOf: await state.mcpClientManager.refreshForAgentRun(workspaceURL: state.rootURL))
            // 续跑也走工具预算（成本问题在续跑上一样存在），但**补不上提示文案**：
            // system prompt 已在上面 makeMessages 时定型，要补就得重建消息列表。
            // 这条差异是已知的，别当成两条路径一致。
            let selected = AgentToolBudget.select(
                tools: tools,
                query: convo.messages.last(where: { $0.role == .user })?.text ?? ""
            )
            startAgentRun(agentMessages: agentMessages, config: config, context: context,
                          tools: selected.tools, checkpoint: checkpoint)
        }
    }

    /// 启动 AgentRunner 并接线全部回调（按发起会话定向写回）。
    /// runCompletion 与断点续传共用：差别只在 agentMessages 的构造方式。
    private func startAgentRun(
        agentMessages: [AgentMessage],
        config: AIConfig,
        context: AgentContext,
        tools: [any AgentTool],
        checkpoint: AgentRunCheckpoint
    ) {
        // 在消息列表末尾加一个空 assistant 占位，用于流式显示
        let replyMessage = AIChatMessage(role: .assistant, text: "")
        let replyID      = replyMessage.id
        convo.messages.append(replyMessage)

        // 启动 AgentRunner（maxSteps 走注入的 settings，与上方 AIConfig.current(settings, ...) 一致）
        let runner = AgentRunner(maxSteps: settings.aiAgentMaxSteps)
        convo.agentRunner = runner

        // 捕获发起会话：run 进行中用户可能切换 / 新建会话（cancelStreaming 停掉 runner，
        // 但 onChunk / onComplete 仍会触发），回调必须写回该会话而非当时的活跃会话
        let sessionID = convo.activeID
        // 轨迹开关在 run 开始时取一次：run 中途用户改设置不该产生半条轨迹
        let traceEnabled = settings.aiTraceEnabled

        // 上下文预算淘汰提示（每次 run 最多一次）：与超长截断提示同通道——transcript 里
        // 插一条 subtle 消息，不静默淘汰。按发起会话写回（插在流式占位 bubble 之前）。
        runner.onContextEviction = { [weak convo] result in
            guard let convo else { return }
            var parts: [String] = []
            if result.evictedToolResults > 0 {
                parts.append(L("ai.notice.evictedToolResults", result.evictedToolResults))
            }
            if result.evictedToolCallArgs > 0 {
                parts.append(L("ai.notice.evictedToolArgs", result.evictedToolCallArgs))
            }
            if result.droppedMessages > 0 {
                parts.append(L("ai.notice.droppedMessages"))
            }
            guard !parts.isEmpty else { return }
            let notice = AIChatMessage(
                role: .assistant,
                text: L("ai.notice.contextBudget", parts.joined(separator: L("ai.notice.separator")))
            )
            convo.insertTranscriptNotice(notice, sessionID: sessionID)
        }

        // 流式 chunk 回调 → 更新占位 bubble（按发起会话写回）
        runner.onChunk = { [weak convo] chunk in
            guard let convo else { return }
            convo.updateMessageText(chunk, messageID: replyID, sessionID: sessionID)
        }

        // 完成回调（全部写入按 sessionID 定向到发起会话）
        runner.onComplete = { [weak convo, weak runner] in
            guard let convo else { return }
            let finalText = runner?.finalText ?? ""
            let errText   = runner?.error

            if let err = errText, !err.isEmpty {
                convo.updateMessageText(L("ai.notice.error", err), messageID: replyID, sessionID: sessionID)
            } else if !finalText.isEmpty {
                var text = finalText
                // 输出达到 max_tokens 上限被截断时，在答案下方追加一行提示
                if runner?.state.wasTruncated == true {
                    text += "\n\n" + L("ai.notice.outputTruncated")
                }
                convo.updateMessageText(text, messageID: replyID, sessionID: sessionID)
            } else {
                // Agent 做了工具调用但没有最终文本
                let errorSteps = runner?.steps.filter(\.isError) ?? []
                if !errorSteps.isEmpty {
                    // 有失败的工具步骤 → 生成错误摘要，不要静默消失
                    let lines = errorSteps.compactMap { step -> String? in
                        if case .toolCallDone(_, let name, _, let result, true, _) = step {
                            let short = result.prefix(120)
                            return "• \(name)：\(short)"
                        }
                        return nil
                    }
                    let summary = L("ai.notice.partialFailure") + lines.joined(separator: "\n")
                    convo.updateMessageText(summary, messageID: replyID, sessionID: sessionID)
                } else {
                    // 工具全部成功，结果已体现在文档里，删掉空占位
                    convo.removeMessage(replyID, sessionID: sessionID)
                }
            }

            // 保存完整的 agent 消息历史（含工具调用），下次对话时直接使用——写回发起会话
            if let fm = runner?.finalMessages, !fm.isEmpty {
                convo.setAgentHistory(fm, sessionID: sessionID)
            }

            // 会话级累计用量：run 收尾时把本轮 usage 累加进持久化会话（成本透明，
            // 历史列表展示「累计 tokens ≈ $」）。后端未返回 usage（如 ClaudeCLI）则跳过。
            if let usage = runner?.state.usage {
                convo.recordUsage(usage, model: config.model, sessionID: sessionID)
            }

            // 保存本次运行状态快照（per-session：步骤面板跟随发起会话，不挂到别的会话上）
            // run 级文件快照一并挂入（仅当确有写入）：步骤面板据此提供「撤销本次运行的全部修改」
            if checkpoint.hasWrites {
                runner?.state.checkpoint = checkpoint
            }
            // 运行轨迹（默认关）：只落元数据——工具序列/成败/耗时/token，不落正文。
            // 见 AgentRunTrace 头注释。落盘放后台：收尾在主线程跑，别让磁盘 IO 卡住 UI；
            // 写失败在 store 内部兜住（只记日志），不影响 run 结果。
            if traceEnabled, let state = runner?.state {
                let trace = AgentRunTrace.make(from: state, sessionID: sessionID)
                Task.detached(priority: .utility) { _ = AgentTraceStore.shared.save(trace) }
            }
            convo.setLastRunState(runner?.state, sessionID: sessionID)

            // 仅当全局 runner 仍是本次运行时才复位：切换会话后用户可能已发起新 run，
            // 旧 run 迟到的收尾不得清掉新 run 的进行状态
            if let runner, convo.agentRunner === runner {
                convo.isResponding = false
                convo.respondingSessionID = nil
                convo.agentRunner  = nil
            }
            convo.persist()
        }

        runner.run(messages: agentMessages, tools: tools, config: config, context: context)
    }

    /// System prompt grounding the assistant in the current document.
    ///
    /// - Parameter includeFullDoc: When `true` (first user turn), injects the
    ///   document body via `DocumentContextExcerpt` (budget-aware: head + paragraphs
    ///   around the cursor + tail when over budget). On subsequent turns the model
    ///   already has the document in its conversation history, so we only remind
    ///   it of the document name to avoid re-paying the token cost every round.
    ///   Selected text (and its containing paragraph) is always included because
    ///   it's user-initiated and small.
    /// internal（非 private）：后台任务发起路径（AIAssistantPanel.sendInBackground）
    /// 复用同一份 grounding，不另写一套 system prompt。
    func systemContext(includeFullDoc: Bool = true) -> String {
        var ctx = """
You are a helpful writing assistant embedded in a native macOS Markdown editor.
Rules:
- Always format code in fenced code blocks with the correct language tag.
- Use proper Markdown syntax (## headings, **bold**, _italic_, `inline code`).
- When the user asks to insert or rewrite content, output clean Markdown without any preamble like "Here is..." or "Sure!".
- Keep responses focused and concise; avoid repeating the user's request back to them.
- You have FULL permission to use all provided tools (create_directory, create_file, write_file, etc.) to perform file system operations. These tools are sandboxed to the user's own machine and are safe to use. NEVER refuse a file operation request — always call the appropriate tool directly.
- To read a file's content you MUST call read_file (or read_document for the active tab). The editor loads file content asynchronously, so opening a file does NOT make its content visible to you — never claim you can "see" a file you only opened. If you need the content, call read_file and use its returned text.
- The document tools (read_document, write_document, patch_document, search_document) accept an OPTIONAL 'filename' argument. Omit it to act on the currently active editor tab; pass it (filename / workspace-relative path / absolute path) to act on that specific file directly. You do NOT need to open_file first just to read, rewrite, or patch a specific file — pass its 'filename' to the document tool instead.
"""
        // 注入工作区路径，帮助 AI 正确使用文件/目录工具
        if let rootURL = state.rootURL {
            ctx += "\n\nThe current workspace root is: \(rootURL.path)"
            ctx += "\n- File and directory tools (create_file, write_file, create_directory, etc.) accept EITHER a path relative to the workspace root (e.g. \"docs/api\") OR an absolute path (e.g. \"\(rootURL.path)/docs/api\"). Both forms work."
            ctx += "\n- When the user provides an absolute path, use it directly with the appropriate tool — do NOT refuse or ask the user to run a terminal command."
        }
        // 注入 HTML 主题元信息（简短，不含完整 CSS）
        let themeName = state.themeStore.current.rawValue
        ctx += "\n\n## 创建 / 改版 HTML 文件"
        ctx += "\nWhen the user asks to create a NEW HTML file, or to restyle/redesign an existing one, you MUST FIRST call the get_html_template tool to fetch MEditor's built-in HTML template, and use it as the base."
        ctx += "\n- get_html_template styles: 'doc' (default — MEditor's standard styled document), 'craft' (modern cards), 'tufte' (serif academic), 'dark' (dark code style). If the user doesn't specify, use 'doc'."
        ctx += "\n- Keep the template's <style> block and overall structure; just fill in / replace the body content. Do NOT invent your own CSS from scratch, and do NOT strip the template's styles into a bare semantic-HTML page unless the user explicitly asks for that."
        ctx += "\n- Keep all CSS inlined in a <style> block; never reference external .css files."
        ctx += "\n(Note: \(themeName) is the current PREVIEW theme — that's separate from these file templates.)"
        let selection = state.editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            // Selected text is cheap and always relevant — include regardless of turn.
            let sel = selection.count > 4000 ? String(selection.prefix(4000)) + "…" : selection
            let name = state.selectedTab?.name ?? "document"
            ctx += "\n\nThe user selected this text in \"\(name)\":\n\n\(sel)"
            // 选区所在段落一并带上并标注：选区只是片段时，模型需要段落语境
            // （段落不长于选区上限才注入，避免大段落放大成本）
            if let tab = state.selectedTab,
               let paraRange = ParagraphTargeting.paragraphRange(
                   containing: state.editorSelectedRange, in: tab.content) {
                let para = String(tab.content[paraRange])
                if para.count > selection.count, para.count <= 4000 {
                    ctx += "\n\nThe selection is part of this paragraph in \"\(tab.name)\":\n\n\(para)"
                }
            }
        } else if includeFullDoc, let tab = state.selectedTab {
            // 预算感知截取：超预算时保留首部 + 光标附近段落 + 尾部，而非整篇硬截断
            let body = DocumentContextExcerpt.excerpt(content: tab.content, cursorLine: state.cursorLine)
            ctx += "\n\nThe current document is \"\(tab.name)\":\n\n\(body)"
        } else if let tab = state.selectedTab {
            // Subsequent turns: just name — full content is already in conversation history.
            ctx += "\n\nThe user is editing a document named \"\(tab.name)\"."
        }
        let userSkills = state.pluginManager.userSkillsPrompt()
        if !userSkills.isEmpty {
            ctx += "\n\n---\n\n# 用户自定义技能\n\n" + userSkills
        }
        // 用户在设置里填的自定义系统提示词：始终注入（最高优先级的个人偏好）
        // 走注入的 settings（与 runCompletion 的 AIConfig.current(settings, ...) 一致），
        // 不直接读 AppSettings.shared，保持 DI 可测
        let custom = settings.aiCustomSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            ctx += "\n\n---\n\n# 用户自定义指令（务必遵守）\n\n" + custom
        }
        return ctx
    }
}
