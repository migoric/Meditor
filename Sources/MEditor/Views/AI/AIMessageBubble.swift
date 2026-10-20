import SwiftUI

// MARK: - Message bubble

extension AIAssistantPanel {
    func bubble(_ message: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if message.role == .user {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        // 图片附件缩略图（当前会话内可点开大图预览）
                        HStack(spacing: 6) {
                            ForEach(message.images) { attachment in
                                Button { previewImage = attachment } label: {
                                    Group {
                                        if let image = attachment.nsImage {
                                            Image(nsImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Image(systemName: "photo")
                                                .foregroundStyle(theme.craftSecondary)
                                        }
                                    }
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(theme.separator.opacity(0.5), lineWidth: DS.Stroke.hairline)
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(L("ai.images.preview"))
                            }
                        }
                    } else if message.imageCount > 0 {
                        // 会话重启后图片数据不进持久化（省体积），只显示占位说明
                        Label(L("ai.images.historyPlaceholder", message.imageCount), systemImage: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(accent.onFill(theme).opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(accent.fill(theme).opacity(0.75))
                            )
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(accent.onFill(theme))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.fill(theme))
                            )
                    }
                }
            } else {
                AIAssistantOrb(size: 20, glow: true).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    // 正在流式增长的 reply（最后一条 assistant 消息）
                    let isStreamingReply = convo.isResponding && message.id == convo.messages.last?.id
                    Group {
                        if isStreamingReply {
                            // 流式期间也走 Markdown 渲染，但节流重解析（每 400ms），
                            // 兼顾成本与观感：相比「流式纯文本 → 完成瞬间切 Markdown」，
                            // 不再有整段重排的布局跳动（这是此前纯文本降级的代价）。
                            ThrottledMarkdownText(
                                text: message.text,
                                textColor: theme.craftPrimary,
                                secondaryColor: theme.craftSecondary,
                                codeBackground: theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045),
                                accent: Color.appAccent
                            )
                        } else {
                            MarkdownText(
                                markdown: message.text,
                                textColor: theme.craftPrimary,
                                secondaryColor: theme.craftSecondary,
                                codeBackground: theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045),
                                accent: Color.appAccent
                            )
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(theme.isDark ? Color.white.opacity(0.03) : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.separator.opacity(theme.isDark ? 0.5 : 0.7), lineWidth: DS.Stroke.regular)
                    )
                    .dsElevation(.floatingBar)

                    if !isStreamingReply {
                        HStack(spacing: 12) {
                            AIMessageAction(icon: "doc.on.doc", title: L("ai.copy"), theme: theme) {
                                Pasteboard.copy(message.text)
                            }
                            AIMessageAction(icon: "text.insert", title: L("ai.insertToDoc"), theme: theme) {
                                state.insertIntoEditor(message.text)
                            }
                            Spacer()
                        }
                        .padding(.leading, 2)
                    }
                }
            }
        }
    }
}

// MARK: - Bubble action button

private struct AIMessageAction: View {
    let icon: String
    let title: String
    let theme: PreviewTheme
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hovered ? theme.craftPrimary : theme.craftSecondary)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
    }
}

// MARK: - Throttled markdown (streaming)

/// 流式期间的节流 Markdown 渲染：chunk 以约 50ms 频率到达，全量重解析太贵，
/// 这里每 400ms 才同步一次最新文本给 MarkdownText。流式结束后外层立刻切回
/// 非节流渲染，最终内容无延迟。
private struct ThrottledMarkdownText: View {
    let text: String
    let textColor: Color
    let secondaryColor: Color
    let codeBackground: Color
    let accent: Color

    private let interval: TimeInterval = 0.4
    @State private var rendered: String = ""
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        MarkdownText(
            markdown: rendered,
            textColor: textColor,
            secondaryColor: secondaryColor,
            codeBackground: codeBackground,
            accent: accent
        )
        .onAppear { rendered = text }
        .onChange(of: text) { _, newValue in
            syncTask?.cancel()
            syncTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                rendered = newValue
            }
        }
        .onDisappear { syncTask?.cancel() }
    }
}
