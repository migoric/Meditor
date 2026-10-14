import SwiftUI
import UniformTypeIdentifiers

// MARK: - Composer（输入区 + 引用选段卡片 + mention picker）

extension AIAssistantPanel {
    @ViewBuilder
    var mentionPickerPopoverContent: some View {
        AtMentionPickerView(
            query: mentionQuery,
            theme: state.themeStore.current,
            onSelect: { candidate in
                NotificationCenter.default.post(
                    name: .atMentionConfirmCandidate,
                    object: candidate
                )
                showMentionPicker = false
            },
            onDismiss: {
                showMentionPicker = false
            }
        )
        .environment(state)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var composerFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 引用选段卡片（来自「问 AI」带入的选区），可一键移除
            if let quoted = state.aiUI.quotedContext, !quoted.isEmpty {
                quotedContextCard(quoted)
            }

            // 待发送图片附件（粘贴/拖拽进入），缩略图 chips，可单个删除
            if !pendingImages.isEmpty {
                attachmentChipsRow
            }

            // Primary prompt area — @mention-aware rich composer
            AtMentionComposerWrapper(
                plainText: Binding(get: { convo.input }, set: { convo.input = $0 }),
                mentionTokens: $mentionTokens,
                // FocusState.Binding 不能隐式转 Binding<Bool>，包一层显式桥接
                isFocused: Binding(get: { inputFocused }, set: { inputFocused = $0 }),
                showMentionPicker: $showMentionPicker,
                mentionQuery: $mentionQuery,
                onSubmit: send,
                // Esc 归属：picker 未显示时 Esc 归面板关闭（与 hero overlay 的 onExitCommand 同一语义）。
                // NSTextView 会吞掉 Esc（cancelOperation:），必须由 composer 显式回调上来。
                onEscapeWithoutPicker: onClose,
                onImagesPasted: addPendingImages,
                theme: theme,
                pickerContent: { mentionPickerPopoverContent }
            )

            // Toolbar row: context chip + attach on the left, send on the right.
            HStack(spacing: 8) {
                // 自动附带只在首轮注入（第二轮起文档已在对话历史里，见
                // AIChatCoordinator 的 userTurnCount 判断）——之后的 chip 点了
                // 也没作用，退化为纯「当前文档」指示器
                let isFirstTurn = convo.messages.isEmpty
                if settings.aiAutoAttachContext, isFirstTurn, let tab = state.selectedTab {
                    // 自动附带 chip：本次可移除（点 ×），切 tab 跟随变化
                    let removed = autoContextRemovedForTab == tab.id
                    HStack(spacing: 5) {
                        Image(systemName: removed ? "doc.text" : "doc.text.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.craftSecondary)
                            .accessibilityHidden(true)
                        Text(L("ai.autoAttach", tab.name))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(removed ? theme.craftSecondary : theme.craftPrimary)
                            .lineLimit(1)
                        if !removed {
                            Button {
                                withAnimation(DS.Motion.fast) { autoContextRemovedForTab = tab.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help(L("ai.autoAttach.remove"))
                            .accessibilityLabel(L("ai.autoAttach.remove"))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(theme.craftHover))
                    .overlay(Capsule().strokeBorder(theme.separator.opacity(0.4), lineWidth: DS.Stroke.hairline))
                    .opacity(removed ? 0.6 : 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    // 总开关关闭或已过首轮：chip 退化为纯「当前文档」指示器（不涉及附带）
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.craftSecondary)
                            .accessibilityHidden(true)
                        Text(documentName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.craftPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(theme.craftHover))
                    .overlay(Capsule().strokeBorder(theme.separator.opacity(0.4), lineWidth: DS.Stroke.hairline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                // 「后台运行」：输入作为独立后台任务发起，不占用当前聊天会话
                //（达到并发上限时由 service toast 拒绝；带图片附件时不支持，禁用）
                let canSendBackground = !convo.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && pendingImages.isEmpty
                Button(action: sendInBackground) {
                    Image(systemName: "moon.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canSendBackground ? theme.craftSecondary : theme.craftSecondary.opacity(0.35))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.craftHover))
                        .overlay(Circle().strokeBorder(theme.separator.opacity(0.5), lineWidth: DS.Stroke.hairline))
                }
                .buttonStyle(.plain)
                .disabled(!canSendBackground)
                .help(L("ai.background.runHelp"))
                .accessibilityLabel(L("ai.background.runHelp"))

                // run 归属另一会话：不误显 Stop（点了会掐断别处的 run），禁用并说明
                let respondingElsewhere = convo.isResponding && !convo.isActiveSessionResponding
                // ⌘Return 冲突规避：确认条挂起期间把快捷键让给确认条的「允许执行」
                let shortcutEnabled = !respondingElsewhere
                    && convo.pendingCommand == nil && convo.pendingWrite == nil

                Button(action: { convo.isResponding ? convo.cancelStreaming() : send() }) {
                    HStack(spacing: 5) {
                        if respondingElsewhere {
                            Image(systemName: "hourglass")
                                .font(.system(size: 11, weight: .bold))
                            Text(L("ai.respondingElsewhere"))
                                .font(.system(size: 12.5, weight: .semibold))
                        } else if convo.isResponding {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(L("ai.stop"))
                                .font(.system(size: 12.5, weight: .semibold))
                        } else {
                            Text(L("ai.execute"))
                                .font(.system(size: 12.5, weight: .semibold))
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundStyle(convo.isResponding && !respondingElsewhere ? Color.white : (canSend ? accent.onFill(theme) : Color.white.opacity(0.9)))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(respondingElsewhere
                                  ? AnyShapeStyle(Color.gray.opacity(0.32))
                                  : convo.isResponding
                                  ? AnyShapeStyle(Color(hex: "EF4444"))
                                  : (canSend ? AnyShapeStyle(accent.fill(theme))
                                             : AnyShapeStyle(Color.gray.opacity(0.32))))
                    )
                    .shadow(color: accent.fill(theme).opacity(canSend && !convo.isResponding ? 0.28 : 0), radius: 7, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .applyCommandReturnShortcut(enabled: shortcutEnabled)
                .disabled(respondingElsewhere || (!canSend && !convo.isResponding))
                .animation(DS.Motion.fast, value: canSend)
                .animation(DS.Motion.fast, value: convo.isResponding)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // Solid white "glass" — visually equal to the prior material+tint
                // but far cheaper to composite while the hero panel scales.
                .fill(theme.isDark ? Color.white.opacity(0.08) : Color.white)
                // Thin top-lit glass hairline.
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: theme.isDark
                                    ? [Color.white.opacity(0.22), Color.white.opacity(0.05)]
                                    : [Color.white.opacity(0.85), Color.white.opacity(0.30)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: DS.Stroke.hairline
                        )
                        .blendMode(.plusLighter)
                )
                // Focus accent ring (thin).
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(accent.fill(theme).opacity(inputFocused ? 0.5 : 0), lineWidth: DS.Stroke.regular)
                )
                // Tight, soft shadow — no wide grey halo.
                .shadow(color: .black.opacity(theme.isDark ? 0.24 : 0.06), radius: 6, x: 0, y: 2)
        )
        .animation(DS.Motion.fast, value: inputFocused)
        // 拖拽图片文件进入输入区（截图粘贴走 MentionTextView.paste 链路）
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
            handleImageDrop(providers)
        }
        .padding(12)
        .background(composerTray)
    }

    /// Opaque strip the glass card floats on. It MUST be opaque so scrolling
    /// transcript content cannot bleed through behind the input (a translucent
    /// material here made the content look clipped/incomplete). The frosted-glass
    /// look lives on the input card itself, above this strip.
    private var composerTray: some View {
        theme.editorBackground
            .overlay(alignment: .top) {
                theme.separator.opacity(0.4).frame(height: 0.5)
            }
            .overlay(alignment: .top) {
                Color.white.opacity(theme.isDark ? 0.05 : 0.55)
                    .frame(height: 1)
                    // 半像素下移是有意的像素对齐：1pt 高光在 retina 上占 2 物理像素，
                    // 下移 0.5pt 让它落在半像素网格上，避免顶边出现 1 物理像素的暗缝。
                    // （DS.Stroke 管线宽；这类「位置微调」是另一回事，故就地注释而非抽 token。）
                    .padding(.top, 0.5)
                    .blendMode(.plusLighter)
            }
    }

    /// 「问 AI」带入的引用选段卡片：左侧竖线 + 选段摘要 + 移除按钮。
    private func quotedContextCard(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("ai.quotedSelection"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(theme.craftSecondary)
                Text(Self.previewText(text))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.craftPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(DS.Motion.fast) { state.aiUI.quotedContext = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L("ai.removeQuote"))
            .accessibilityLabel(L("ai.removeQuote"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)   // 锁成内容高度，杜绝被拉伸出空白
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.craftHover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // 左侧 accent 竖线用 overlay 绘制，不参与 HStack 高度计算（greedy shape 会撑高）
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.appAccent.opacity(0.7))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.separator.opacity(0.35), lineWidth: DS.Stroke.hairline)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 折叠引用文本里的多余空白/换行，供卡片单段紧凑预览（不影响发送时的原文）。
    private static func previewText(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var documentName: String {
        state.selectedTab?.name ?? L("ai.currentDocument")
    }

    private var canSend: Bool {
        // 允许纯图片发送（文本为空时 content parts 只含图片块）
        (!convo.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || !pendingImages.isEmpty) && !convo.isResponding
    }

    // MARK: - 图片附件（粘贴 / 拖拽）

    /// 粘贴/拖拽进来的图片追加到待发送列表；超过上限（4 张）的部分拒收。
    func addPendingImages(_ new: [AIImageAttachment]) {
        let result = AIImageProcessor.appending(new, to: pendingImages)
        withAnimation(DS.Motion.fast) { pendingImages = result.merged }
        if result.rejected > 0 {
            AppLog.session.info("AI 输入图片附件超限：拒收 \(result.rejected) 张")
        }
    }

    func removePendingImage(_ id: UUID) {
        withAnimation(DS.Motion.fast) { pendingImages.removeAll { $0.id == id } }
    }

    /// 输入区缩略图 chips 行：横向排列，单个可删。
    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.vertical, 2)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func attachmentChip(_ attachment: AIImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
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
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.separator.opacity(0.5), lineWidth: DS.Stroke.hairline)
            )

            Button { removePendingImage(attachment.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftSecondary)
                    .background(Circle().fill(theme.editorBackground))
            }
            .buttonStyle(.plain)
            .help(L("ai.images.remove"))
            .accessibilityLabel(L("ai.images.remove"))
            .offset(x: 4, y: -4)
        }
        .padding(4)   // 给右上角 × 留出出血空间
    }

    /// 拖拽图片进入：文件 URL 优先，其次 NSImage（Photos 等直接拖位图）。
    /// 与编辑器拖图落盘不同，这里只走内存附件（AIImageProcessor）。
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    // fileURL flavor 可能是 URL 或 file bookmark Data
                    var url = item as? URL
                    if url == nil, let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    }
                    guard let url,
                          let attachment = AIImageProcessor.makeAttachment(fromFileURL: url) else { return }
                    Task { @MainActor in self.addPendingImages([attachment]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let attachment = AIImageProcessor.makeAttachment(from: image) else { return }
                    Task { @MainActor in self.addPendingImages([attachment]) }
                }
            }
        }
        return accepted
    }
}

// MARK: - Conditional ⌘Return

private extension View {
    /// 条件挂载 ⌘Return 快捷键：确认条挂起 / run 归属其他会话时让给对应的界面语义。
    @ViewBuilder
    func applyCommandReturnShortcut(enabled: Bool) -> some View {
        if enabled {
            self.keyboardShortcut(.return, modifiers: [.command])
        } else {
            self
        }
    }
}
