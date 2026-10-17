import SwiftUI

/// Floating action strip shown at the editor's bottom when text is selected.
/// Tapping an action triggers AI processing and morphs the content area into
/// an inline split diff view — no sheet, no modal.
@MainActor
struct InlineEditBar: View {
    @Environment(AppState.self)    private var state
    @Environment(AppSettings.self) private var settings

    let selectedText: String

    @State private var isLoading:    Bool   = false
    @State private var loadingLabel: String = ""
    @State private var showAgentPanel = false
    @State private var agentRunner    = AgentRunner()

    /// Plugin skill commands from enabled manual skills
    private var pluginCommands: [(skill: PluginSkill, command: SkillCommand)] {
        state.pluginManager.skills
            .filter { $0.isEnabled && $0.source == .manual && !$0.commands.isEmpty }
            .flatMap { skill in skill.commands.map { (skill, $0) } }
    }

    var body: some View {
        HStack(spacing: 2) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(L("ai.inline.working", loadingLabel))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button {
                        state.diffReview.dismiss()
                        isLoading    = false
                        loadingLabel = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("common.cancel"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            } else {
                // 快速内联操作（根据内容类型动态调整，主行最多 4 个）
                ForEach(primaryActions) { action in
                    actionButton(action)
                }

                // 放不下的动作收进「更多」
                if !overflowActions.isEmpty {
                    moreMenu
                }

                // Plugin command buttons (from enabled Skill.md with commands:)
                if !pluginCommands.isEmpty {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 4)
                    ForEach(pluginCommands, id: \.command.id) { (skill, cmd) in
                        pluginCommandButton(skill: skill, command: cmd)
                    }
                }

                // 问 AI 分隔线 + 按钮
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 4)

                askAIButton
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: DS.Stroke.hairline))
        .dsElevation(.floatingBar)
        .overlay(alignment: .bottom) {
            if showAgentPanel {
                AgentResultPanel(runner: agentRunner) {
                    showAgentPanel = false
                }
                .environment(state)
                .frame(width: 480)
                .offset(y: -60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showAgentPanel)
    }

    // MARK: - 内容感知动作列表

    /// 主行动作（最多 4 个），规则见 InlineEditBarPlan。
    private var primaryActions: [InlineEditAction] {
        InlineEditBarPlan.actions(for: selectedText).primary
    }

    /// 「更多」收纳的次优先动作。
    private var overflowActions: [InlineEditAction] {
        InlineEditBarPlan.actions(for: selectedText).overflow
    }

    /// 「更多」下拉：放不下主行的动作，触发链路与主行按钮一致。
    private var moreMenu: some View {
        Menu {
            ForEach(overflowActions) { action in
                Button { triggerAction(action) } label: {
                    Label(action.displayName, systemImage: action.icon)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(L("ai.inline.more"))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("ai.inline.more"))
    }

    // MARK: - Ask AI button

    /// 把选中文本带入 AI 面板，开启对话。
    private var askAIButton: some View {
        Button {
            guard !selectedText.isEmpty else { return }
            state.openAssistantWithSelection(selectedText)
        } label: {
            HStack(spacing: 4) {
                AIAssistantOrb(size: 12)
                Text(L("ai.askAI"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(AIBrand.blue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AIBrand.blue.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L("ai.askAIHint"))
    }

    // MARK: - Action button

    private func actionButton(_ action: InlineEditAction) -> some View {
        Button { triggerAction(action) } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(action.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(action.displayName)
    }

    // MARK: - Trigger

    // MARK: - Plugin command button

    private func pluginCommandButton(skill: PluginSkill, command: SkillCommand) -> some View {
        Button { triggerPluginCommand(skill: skill, command: command) } label: {
            HStack(spacing: 4) {
                Image(systemName: command.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(command.trigger)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.appAccent.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(command.description.isEmpty ? command.trigger : command.description)
    }

    private func triggerPluginCommand(skill: PluginSkill, command: SkillCommand) {
        guard !selectedText.isEmpty else { return }
        guard let skillContent = try? String(contentsOf: skill.skillPath, encoding: .utf8) else { return }

        // Determine which tools are available
        let allTools: [any AgentTool] = BuiltinAgentTools.all
        let tools: [any AgentTool] = command.allowedTools.isEmpty
            ? allTools
            : allTools.filter { command.allowedTools.contains($0.spec.name) }

        let config  = AIConfig.current(settings, scene: .inline)   // plugin 命令也属于内联编辑场景
        let context = AgentContext.make(appState: state)
        // 将 Skill command 声明的 shell 白名单注入上下文，使 RunCommandTool 能够执行白名单检查
        context.setAllowedCommandPatterns(command.allowedCommands.isEmpty ? nil : command.allowedCommands)

        // 全文上下文 8K 门控（与聊天面板 systemContext 的 8000 字符策略一致），
        // 大文档不再整篇内联进 prompt（成本审计 8.2 #2）
        let fullDoc = state.selectedTab?.content ?? ""
        let docContext = fullDoc.count > 8000
            ? String(fullDoc.prefix(8000)) + "\n…（文档过长已截断，可用 read_document 的 start_line/end_line 按需读取）"
            : fullDoc
        let userMsg = "Selected text:\n\n\(selectedText)\n\nFull document:\n\n\(docContext)"

        agentRunner = AgentRunner()
        showAgentPanel = true

        agentRunner.run(
            systemPrompt: skillContent,
            userMessage: userMsg,
            tools: tools,
            config: config,
            context: context
        )
    }

    private func triggerAction(_ action: InlineEditAction) {
        guard !selectedText.isEmpty else { return }
        guard state.pluginManager.isBuiltinEnabled(BuiltinSkills.ID.inlineEditor) else {
            state.showToast(L("ai.error.notConfigured"), icon: "exclamationmark.triangle")
            return
        }

        // 保留选区位置
        let savedRange  = state.editorSelectedRange
        state.pendingReplaceRange = savedRange

        let fullContent = state.selectedTab?.content ?? selectedText

        // 定位选区：优先精确的 NSRange → String.Index 转换；失败（选区与文档内容
        // 已不同步）时仅当选中文本在全文唯一出现才按该位置替换；否则无法安全定位——
        // 绝不做全局替换（会把文档里所有相同文本都改掉），提示用户重新圈选。
        let targetRange: Range<String.Index>
        if let swiftRange = Range(savedRange, in: fullContent) {
            targetRange = swiftRange
        } else if let unique = fullContent.uniqueLiteralRange(of: selectedText) {
            targetRange = unique
        } else {
            state.showToast(L("ai.inline.selectionLost"), icon: "exclamationmark.triangle")
            return
        }

        isLoading    = true
        loadingLabel = action.displayName

        // 系统 prompt = 内置 inlineEditor skill + 用户插件附加
        var systemPrompt = BuiltinSkills.inlineEditor.content
        let extra = state.pluginManager.userSkillsPrompt()
        if !extra.isEmpty { systemPrompt += "\n\n---\n\n# 附加技能\n\n" + extra }

        let userMsg = action.userInstruction(for: selectedText,
                                              document: state.selectedTab?.content)

        let splice: (String) -> String = { replacement in
            fullContent.replacingCharacters(in: targetRange, with: replacement)
        }

        // 流式执行管线与预览侧共享（InlineEditSession）
        InlineEditSession.run(
            state: state, settings: settings,
            systemPrompt: systemPrompt, userMessage: userMsg,
            fullContent: fullContent, actionLabel: action.displayName,
            splice: splice,
            onSettled: {
                isLoading    = false
                loadingLabel = ""
            }
        )

        // 连续微调入口：改写完成后 diff 顶栏出现「继续调整」输入框，对最近一次
        // 生成结果按自由指令多轮迭代（与预览侧共用同一实现，行为对齐）。
        // beginStreaming（在 InlineEditSession.run 内）会清空该入口，故在调用后注入。
        InlineEditSession.installRefinement(
            state: state, settings: settings,
            fullContent: fullContent, splice: splice
        )
    }
}
