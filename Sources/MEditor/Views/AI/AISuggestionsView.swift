import SwiftUI

struct AISuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let titleKey: String
    let tint: Color
    var promptKey: String? = nil
}

// MARK: - Suggestions（空会话时的引导页）

extension AIAssistantPanel {
    static let primarySuggestions: [AISuggestion] = [
        .init(icon: "sparkles", titleKey: "ai.suggest.whatCanYouDo", tint: Color.appAccent, promptKey: "ai.prompt.whatCanYouDo"),
        .init(icon: "text.alignleft", titleKey: "ai.suggest.summarize", tint: AIBrand.blue, promptKey: "ai.prompt.summarize"),
        .init(icon: "lightbulb.fill", titleKey: "ai.suggest.improveClarity", tint: Color(hex: "F59E0B"), promptKey: "ai.prompt.improveClarity"),
        .init(icon: "checkmark.seal.fill", titleKey: "ai.suggest.fixGrammar", tint: Color(hex: "10B981"), promptKey: "ai.prompt.fixGrammar"),
        .init(icon: "globe", titleKey: "ai.suggest.translate", tint: Color(hex: "06B6D4"), promptKey: "ai.prompt.translate"),
        .init(icon: "paintbrush.fill", titleKey: "ai.suggest.styleDocument", tint: AIBrand.pink, promptKey: "ai.prompt.styleDocument")
    ]

    static let moreSuggestions: [AISuggestion] = [
        .init(icon: "list.bullet.rectangle.fill", titleKey: "ai.suggest.outline", tint: Color(hex: "3B82F6"), promptKey: "ai.prompt.outline"),
        .init(icon: "arrow.down.right.and.arrow.up.left", titleKey: "ai.suggest.shorten", tint: AIBrand.orange, promptKey: "ai.prompt.shorten"),
        .init(icon: "arrow.up.left.and.arrow.down.right", titleKey: "ai.suggest.expand", tint: Color(hex: "3B82F6"), promptKey: "ai.prompt.expand"),
        .init(icon: "tablecells.fill", titleKey: "ai.suggest.toTable", tint: Color(hex: "14B8A6"), promptKey: "ai.prompt.toTable")
    ]

    var suggestionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                greeting
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                // 首次使用时显示 @mention 能力卡片
                if showMentionTip {
                    mentionCapabilityCard
                        .padding(.bottom, 8)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
                        ))
                }

                sectionHeader("ai.section.suggestions")

                ForEach(Self.primarySuggestions) { s in
                    AISuggestionRow(suggestion: s, theme: theme) { apply(s) }
                }

                if convo.showAllSuggestions {
                    ForEach(Self.moreSuggestions) { s in
                        AISuggestionRow(suggestion: s, theme: theme) { apply(s) }
                    }
                } else {
                    showMoreRow
                }

                // @mention 快捷入口（始终显示）
                sectionHeader("ai.section.mention")
                    .padding(.top, 6)

                mentionShortcutRow(icon: "doc.text", label: "@current",
                                   hint: L("ai.mention.currentHint")) {
                    insertMentionTag("@current ")
                }
                mentionShortcutRow(icon: "folder", label: "@workspace",
                                   hint: L("ai.mention.workspaceHint")) {
                    insertMentionTag("@workspace ")
                }
                mentionShortcutRow(icon: "doc.badge.plus", label: L("ai.mention.file"),
                                   hint: L("ai.mention.fileHint")) {
                    // 激活 @输入模式
                    convo.input += "@"
                    inputFocused = true
                }

                sectionHeader("ai.section.yourPrompts")
                    .padding(.top, 6)
                AISuggestionRow(
                    suggestion: .init(icon: "plus.circle.fill", titleKey: "ai.createCustomPrompt", tint: theme.craftSecondary),
                    theme: theme
                ) {
                    inputFocused = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            DotGridBackground(opacity: theme.isDark ? 0.10 : 0.18)
                .allowsHitTesting(false)
        )
    }

    // MARK: - @mention 引导卡片

    private var mentionCapabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AIBrand.blue)
                Text(L("ai.mention.cardTitle"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.craftPrimary)
                Spacer()
                Button {
                    withAnimation(DS.Motion.fast) { showMentionTip = false }
                    hasSeenMentionHint = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.craftSecondary)
                }
                .buttonStyle(.plain)
            }

            Text(L("ai.mention.cardBody"))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.craftSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                mentionTagChip("@current", color: AIBrand.blue)
                mentionTagChip("@workspace", color: Color(hex: "10B981"))
                mentionTagChip(L("ai.mention.tagFileExample"), color: AIBrand.violet)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(AIBrand.blue.opacity(theme.isDark ? 0.12 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(AIBrand.blue.opacity(0.22), lineWidth: DS.Stroke.regular)
        )
        .padding(.horizontal, 8)
    }

    private func mentionTagChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func mentionShortcutRow(icon: String, label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(AIBrand.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .foregroundStyle(AIBrand.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.craftPrimary)
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.craftSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func insertMentionTag(_ tag: String) {
        convo.input += tag
        inputFocused = true
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            AIAssistantOrb(size: 44, glow: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ai.greeting"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.craftPrimary)
                Text(L("ai.greetingSub"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.craftSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var showMoreRow: some View {
        Button {
            withAnimation(DS.Motion.fast) { convo.showAllSuggestions = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(theme.craftSecondary)
                Text(L("ai.showMore", Self.moreSuggestions.count))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ suggestion: AISuggestion) {
        convo.input = L(suggestion.promptKey ?? suggestion.titleKey)
        inputFocused = true
    }

    private func sectionHeader(_ key: String) -> some View {
        Text(L(key).uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(theme.craftSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

// MARK: - Suggestion row

private struct AISuggestionRow: View {
    let suggestion: AISuggestion
    let theme: PreviewTheme
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(suggestion.tint.opacity(hovered ? 0.22 : 0.14))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: suggestion.icon)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(suggestion.tint)
                    )
                Text(L(suggestion.titleKey))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.craftSecondary.opacity(hovered ? 0.9 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovered ? theme.craftHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.micro, value: hovered)
    }
}
