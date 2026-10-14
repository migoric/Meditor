import SwiftUI

/// Floating action strip shown at the bottom of the preview when text is selected.
/// Triggers AI inline edit then opens the diff-review overlay instead of a sheet.
@MainActor
struct PreviewInlineEditBar: View {
    @Environment(AppState.self)    private var state
    @Environment(AppSettings.self) private var settings

    let selectedText: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            // 内容感知：按选中内容类型只显示最相关的 3-4 个操作（与编辑器内联栏一致）
            ForEach(contextualActions) { action in
                actionButton(action)
            }

            // 问 AI 入口（预览栏此前缺失）
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 4)
            askAIButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: DS.Stroke.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.bottom, 12)
    }

    // MARK: - 内容感知动作列表

    /// 根据选中内容类型返回最相关的 AI 操作，最多 4 个。
    /// 分类规则收敛在 InlineEditBarPlan（surface: .preview）：预览圈选不支持
    /// 转表格（映射回源文不可靠），也无「更多」收纳。
    private var contextualActions: [InlineEditAction] {
        InlineEditBarPlan.actions(for: selectedText, surface: .preview).primary
    }

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

    /// 把选中文本带入 AI 面板，开启对话。
    private var askAIButton: some View {
        Button {
            guard !selectedText.isEmpty else { return }
            state.openAssistantWithSelection(selectedText)
            onDismiss?()
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

    // MARK: - Action

    private func triggerAction(_ action: InlineEditAction) {
        guard !selectedText.isEmpty else { return }
        guard state.pluginManager.isBuiltinEnabled(BuiltinSkills.ID.inlineEditor) else {
            state.showToast(L("ai.error.notConfigured"), icon: "exclamationmark.triangle")
            return
        }
        let fullContent = state.selectedTab?.content ?? selectedText
        // 渲染选区映射回源码范围（剥掉 **、##、- 等语法后匹配，
        // 命中时向两侧吞掉紧邻的行内标记）。映射失败不乱改文档：
        // 提示用户从编辑器圈选，而不是拿 AI 结果整篇替换。
        guard let sourceRange = SourceTextMapper.sourceRange(
            ofPlainSelection: selectedText, in: fullContent
        ) else {
            state.showToast(L("ai.inline.mapFailed"), icon: "exclamationmark.triangle")
            onDismiss?()
            return
        }

        // 系统 prompt = 内置 inlineEditor skill + 用户插件附加（与编辑器链路一致）
        var systemPrompt = BuiltinSkills.inlineEditor.content
        let extra = state.pluginManager.userSkillsPrompt()
        if !extra.isEmpty { systemPrompt += "\n\n---\n\n# 附加技能\n\n" + extra }
        let userMsg = action.userInstruction(for: selectedText, document: fullContent)

        let splice: (String) -> String = { fullContent.replacingCharacters(in: sourceRange, with: $0) }
        let flash = Self.flashChange(state: state, fullContent: fullContent, sourceRange: sourceRange)

        // 流式执行管线与编辑器侧共享（InlineEditSession）；写回后闪示改动位置
        InlineEditSession.run(
            state: state, settings: settings,
            systemPrompt: systemPrompt, userMessage: userMsg,
            fullContent: fullContent, actionLabel: action.displayName,
            splice: splice,
            onFinalize: flash
        )

        // 连续微调入口：对最近一次生成结果按自由指令迭代（"再短一点"…）。
        // beginStreaming（在 InlineEditSession.run 内）会清空该入口，故在调用后重新注入。
        InlineEditSession.installRefinement(
            state: state, settings: settings,
            fullContent: fullContent, splice: splice, onFinalize: flash
        )
        onDismiss?()
    }

    /// 写回后闪示改动位置（改哪亮哪）。首轮编辑与连续微调共用。
    private static func flashChange(
        state: AppState,
        fullContent: String,
        sourceRange: Range<String.Index>
    ) -> (String, String) -> Void {
        // sourceRange 基于触发时的快照字符串；重定位合并后 merged 已是另一个
        // 字符串，过期索引用上去是越界风险。改为在 merged 中按 AI 生成文本
        // 重新定位闪示锚点：优先取离原选区起点最近的一处匹配（文档里存在
        // 相同段落时避免闪错位置），找不到则放弃本次闪示。
        let anchorOffset = fullContent.distance(from: fullContent.startIndex, to: sourceRange.lowerBound)
        return { merged, finalText in
            let anchor = merged.index(merged.startIndex, offsetBy: min(anchorOffset, merged.count))
            if let flashRange = merged.literalRange(of: finalText, nearestTo: anchor) {
                state.flashPreviewChange(sourceRange: flashRange, in: merged)
            }
        }
    }
}
