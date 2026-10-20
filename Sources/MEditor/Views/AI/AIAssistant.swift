import SwiftUI

// MARK: - Chat / input panel

/// 浮现于编辑器上方的 AI 助手面板。
/// 支持多 provider：OpenAI 兼容接口（远程）或本地 Claude CLI（复用登录态）。
/// 通过 AppSettings 配置 provider；未配置时显示引导界面。
@MainActor
struct AIAssistantPanel: View {
    @Environment(AppState.self) var state
    let onClose: () -> Void

    // internal（非 private）：AIInputBar 等同类型跨文件 extension 也要读（自动附带 chip）
    @Environment(AppSettings.self) var settings
    @State private var showHistory = false
    @State var atBottom = true
    @State var streamScrollWork: DispatchWorkItem?   // 流式滚动 debounce
    @State var mentionTokens: [AtMentionToken] = []
    @State var showMentionPicker = false
    @State var mentionQuery: String = ""
    /// 「自动附带当前文档」chip 被移除的 tab id：仅对当次发送生效——切 tab（id 不
    /// 匹配）或发送完成（重置 nil）后自动恢复，不影响历史消息与其他 tab。
    @State var autoContextRemovedForTab: UUID? = nil
    /// 待发送的图片附件（输入框上方的缩略图 chips；发送后清空）。
    /// 不随草稿持久化——图片只活在当前面板会话内。
    @State var pendingImages: [AIImageAttachment] = []
    /// 气泡里点开的大图预览（popover 展示）
    @State var previewImage: AIImageAttachment? = nil
    @FocusState var inputFocused: Bool

    /// 首次使用引导：显示 @mention 能力提示。
    @AppStorage("ai.hasSeenMentionHint") var hasSeenMentionHint = false
    /// 首次打开时显示 @mention 能力卡片。
    @State var showMentionTip = false
    /// 首启引导：用户在引导里点过「暂时跳过 / 开始对话」后不再打扰
    @AppStorage("ai.onboardingDismissed") private var onboardingDismissed = false
    /// 本次面板会话内通过引导完成了配置：钉住引导展示「就绪 + 演示入口」阶段，
    /// 否则 isConfigured 变 true 后引导立刻消失，演示入口来不及点
    @State private var onboardingPinned = false

    var theme: PreviewTheme { state.themeStore.current }
    var accent: AIAccentStyle { AIAccentStyle.current(settings) }
    var convo: AIConversation { state.aiConversation }
    /// 业务协调器（无状态，随取随建）：承载 runCompletion 等已下沉的业务逻辑。
    private var coordinator: AIChatCoordinator {
        AIChatCoordinator(settings: settings, conversation: convo, appState: state)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // 后台任务区（进行中/最近完成）：有任务时才占位
            AIBackgroundTasksSection(theme: theme)
            content
            // @mention picker：作为独立布局元素显示在输入框正上方，绝不遮挡
            if showMentionPicker {
                mentionPickerPopoverContent
                    .padding(.horizontal, 24)
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97, anchor: .bottom).combined(with: .opacity),
                        removal:   .scale(scale: 0.97, anchor: .bottom).combined(with: .opacity)
                    ))
            }
            composerFooter
        }
        .background(theme.editorBackground)
        .animation(DS.Motion.springFast, value: showMentionPicker)
        .onAppear {
            DispatchQueue.main.async {
                // 如果是内联选中文本触发，预填输入框并清除待消费标记
                if let pending = state.aiUI.pendingSelectionPrompt {
                    convo.input = pending
                    state.aiUI.pendingSelectionPrompt = nil
                }
                inputFocused = true

                // 首次打开：延迟显示 @mention 能力提示卡片
                if !hasSeenMentionHint && convo.messages.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation(DS.Motion.spring) { showMentionTip = true }
                    }
                }
            }
        }
        // 面板已打开时再次「问 AI」：onAppear 不会重触发，这里负责把选区带入输入框
        .onChange(of: state.aiUI.pendingSelectionPrompt) { _, pending in
            guard let pending, !pending.isEmpty else { return }
            if convo.input.isEmpty {
                convo.input = pending
            } else {
                convo.input += "\n\n" + pending
            }
            state.aiUI.pendingSelectionPrompt = nil
            inputFocused = true
        }
        // 气泡缩略图点击后的大图预览（简单弹窗，不引 Quick Look 面板复杂度）
        .popover(item: $previewImage, arrowEdge: .leading) { attachment in
            Group {
                if let image = attachment.nsImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(L("ai.images.decodeFailed"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
            .frame(minWidth: 240, maxWidth: 720, minHeight: 160, maxHeight: 560)
            .padding(10)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                AIHeaderButton(icon: "clock.arrow.circlepath", help: L("ai.history"), theme: theme) {
                    showHistory.toggle()
                }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    AIHistoryView(convo: convo, theme: theme) { showHistory = false }
                }
                Spacer()
                Button(action: newChat) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("ai.newChat"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(theme.craftPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(theme.craftHover))
                    .overlay(Capsule().strokeBorder(theme.separator.opacity(0.5), lineWidth: DS.Stroke.regular))
                }
                .buttonStyle(.plain)
                .help(L("ai.newChat"))
                Spacer()
                AIHeaderButton(icon: "xmark", help: L("common.close"), theme: theme, action: onClose)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)

            // Context-limit warning banner — shown when the conversation is near
            // the model's context window so the user can start a new chat in time.
            if convo.isApproachingContextLimit {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(L("ai.contextNearlyFull"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color(hex: "92400E"))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "FEF3C7"))
                .transition(.opacity)
            }
        }
        .background(
            theme.editorBackground
                .overlay(alignment: .bottom) { theme.separator.opacity(0.4).frame(height: 1) }
        )
    }

    // MARK: Body

    /// Agent 场景是否已配置可用（引导显隐的唯一判据之一）
    private var aiConfigured: Bool {
        AIConfig.current(settings, scene: .agent).isConfigured
    }

    /// 空会话时是否展示首启引导
    private var showOnboarding: Bool {
        guard convo.messages.isEmpty else { return false }
        if onboardingPinned { return true }
        return AIOnboardingLogic.shouldShow(isConfigured: aiConfigured, dismissed: onboardingDismissed)
    }

    @ViewBuilder
    private var content: some View {
        if showOnboarding {
            onboardingView
        } else if convo.messages.isEmpty {
            suggestionsView
        } else {
            transcriptView
        }
    }

    private var onboardingView: some View {
        AIOnboardingView(
            theme: theme,
            isConfigured: aiConfigured,
            isCLIProvider: settings.aiProvider == AIProviderKind.claudeCLI.rawValue,
            cliTest: { [settings] in
                await AIClient.testClaudeCLI(cliPath: settings.aiCLIPath, cliModel: settings.aiCLIModel)
            },
            onUseClaudeCLI: { path in
                settings.aiProvider = AIProviderKind.claudeCLI.rawValue
                settings.aiCLIPath = path
                onboardingPinned = true   // 切到「就绪 + 演示入口」阶段
            },
            onOpenSettings: {
                // 从引导跳去配置：回来后停在「就绪 + 演示入口」阶段，
                // 否则配置完成引导直接消失，演示入口来不及展示
                onboardingPinned = true
                state.settingsRequestedTab = .ai
                state.showingSettings = true
            },
            onRunDemo: {
                let flow = state.agentDemoFlow
                // 已配置 → 真实 Agent；未配置 → 离线预演（runAuto 内部决定）
                Task { await flow.runAuto(appState: state, settings: settings) }
            },
            onDismiss: {
                onboardingDismissed = true
                onboardingPinned = false
            }
        )
    }

    // MARK: Logic

    private func newChat() {
        withAnimation(DS.Motion.fast) {
            convo.newSession()
            convo.showAllSuggestions = false
        }
        mentionTokens = []
        pendingImages = []   // 待发送图片属于上一次提问语境，不带进新会话
        inputFocused = true
    }

    func send() {
        let trimmed = convo.input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 允许纯图片发送（文本为空时 content parts 只含图片块）
        guard !trimmed.isEmpty || !pendingImages.isEmpty, !convo.isResponding else { return }

        // 若带有「引用选段」，作为 markdown 引用拼到提问前，给 AI 完整上下文
        let messageText: String
        if let quoted = state.aiUI.quotedContext, !quoted.isEmpty {
            let quotedBlock = quoted
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            messageText = quotedBlock + "\n\n" + trimmed
        } else {
            messageText = trimmed
        }

        let images = pendingImages
        withAnimation(DS.Motion.standard) {
            convo.messages.append(AIChatMessage(role: .user, text: messageText, images: images))
            convo.input = ""
            pendingImages = []
        }
        state.aiUI.quotedContext = nil
        // 保存当次 @tokens，供 runCompletion 注入上下文，然后清空
        let tokensSnapshot = mentionTokens
        mentionTokens = []
        // 自动附带当前文档：设置总开关 + 本次未点 chip 移除
        let includeAutoContext = settings.aiAutoAttachContext
            && autoContextRemovedForTab != state.selectedTab?.id
        autoContextRemovedForTab = nil
        convo.persist()
        coordinator.runCompletion(mentionTokens: tokensSnapshot, includeAutoContext: includeAutoContext)
    }

    /// Drop the last assistant reply (if any) and re-run the request.
    func regenerate() {
        guard !convo.isResponding else { return }
        if convo.messages.last?.role == .assistant {
            convo.messages.removeLast()
        }
        // 清掉当前会话上一轮的运行快照：否则新 run 完成前，旧步骤面板会一直残留在
        // transcript 里（lastRunState 是 per-session 计算属性，写 nil 即清当前会话）。
        convo.lastRunState = nil
        coordinator.runCompletion(includeAutoContext: settings.aiAutoAttachContext)
    }

    /// 断点续传入口（上次 run 失败中断时出现）：复用已完成的工具调用结果继续跑。
    func resumeInterruptedRun() {
        coordinator.resumeInterruptedRun()
    }

    /// 「后台运行」入口：输入作为独立后台任务发起（独立 AgentRunner + context），
    /// 不占用当前聊天会话——不追加消息、不经流式渲染，完成后 toast + 系统通知。
    /// 已知取舍：@mention 不做上下文展开；图片附件不支持（入口按钮在带图时禁用）。
    func sendInBackground() {
        let trimmed = convo.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingImages.isEmpty else { return }

        // 引用选段与聊天发送同一处理：作为 markdown 引用拼到提问前
        let prompt: String
        if let quoted = state.aiUI.quotedContext, !quoted.isEmpty {
            let quotedBlock = quoted
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            prompt = quotedBlock + "\n\n" + trimmed
        } else {
            prompt = trimmed
        }

        let includeFullDoc = settings.aiAutoAttachContext
            && autoContextRemovedForTab != state.selectedTab?.id
        let started = state.backgroundAgentTasks.start(
            prompt: prompt,
            systemPrompt: coordinator.systemContext(includeFullDoc: includeFullDoc),
            config: AIConfig.current(settings, scene: .agent),
            maxSteps: settings.aiAgentMaxSteps
        )
        // 并发上限拒绝等场景已由 service toast，输入保留给用户重试
        guard started != nil else { return }
        convo.input = ""
        mentionTokens = []
        autoContextRemovedForTab = nil
        state.aiUI.quotedContext = nil
    }
}

// MARK: - Header button

private struct AIHeaderButton: View {
    let icon: String
    let help: String
    let theme: PreviewTheme
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.craftSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovered ? theme.craftHover : Color.clear))
                .overlay(Circle().strokeBorder(theme.separator.opacity(0.6), lineWidth: DS.Stroke.regular))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(DS.Motion.micro, value: hovered)
    }
}
