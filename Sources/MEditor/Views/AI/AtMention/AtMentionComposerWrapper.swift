import SwiftUI

// MARK: - AtMentionComposerWrapper

@MainActor
struct AtMentionComposerWrapper<Picker: View>: View {

    @Environment(AppState.self) private var state

    @Binding var plainText: String
    @Binding var mentionTokens: [AtMentionToken]
    // 必须是真正的 Binding（而非值拷贝）：内部 Coordinator 在
    // textDidBegin/EndEditing 写回焦点状态，父层用它驱动焦点光环等 UI
    @Binding var isFocused: Bool
    @Binding var showMentionPicker: Bool
    @Binding var mentionQuery: String
    var onSubmit: () -> Void
    /// picker 未显示时按下 Esc 的回调（透传给 AtMentionComposerView，用于关闭 AI 面板）
    var onEscapeWithoutPicker: (() -> Void)? = nil
    /// ⌘V 粘贴到图片时回调（透传给 AtMentionComposerView）
    var onImagesPasted: (([AIImageAttachment]) -> Void)? = nil
    var theme: PreviewTheme
    @ViewBuilder var pickerContent: () -> Picker

    var body: some View {
        ZStack(alignment: .topLeading) {
            if plainText.isEmpty {
                Text(L("ai.inputPlaceholder"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftSecondary.opacity(0.5))
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }

            AtMentionComposerView(
                plainText: $plainText,
                mentionTokens: $mentionTokens,
                isFocused: $isFocused,
                onSubmit: onSubmit,
                onEscapeWithoutPicker: onEscapeWithoutPicker,
                onImagesPasted: onImagesPasted,
                theme: theme,
                fontSize: 13.5
            )
            .frame(minHeight: 22, maxHeight: 110)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        // ── 监听 @ 触发 ──────────────────────────────────────────────────
        .onReceive(NotificationCenter.default.publisher(for: .atMentionQueryChanged)) { notif in
            guard let coord = notif.object as? AtMentionComposerView.Coordinator else { return }
            if let q = coord.activeQuery {
                mentionQuery = q
                if !showMentionPicker {
                    // 确保全量索引就绪（与 QuickOpen 共用同一索引，如已就绪则无开销）
                    if let root = state.rootURL {
                        state.fileTreeManager.ensureIndexReady(rootURL: root)
                    }
                    showMentionPicker = true
                }
            } else {
                showMentionPicker = false
            }
        }
    }
}
