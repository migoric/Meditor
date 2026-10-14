import SwiftUI

/// 悬浮在预览区右上角的操作按钮组（Craft 风格）
@MainActor
struct DocumentActionBar: View {
    @Environment(AppState.self) private var state

    @State private var hoveredAction: String? = nil
    @State private var isExpanded = true

    private var theme: PreviewTheme { state.themeStore.current }

    /// 美化按文件类型分流：Markdown 走本地规范化（同格式回写，diff 预览）；HTML 走 HTML 美化 Sheet。
    /// 均受内置「美化」技能开关控制。
    private func beautifyCurrent() {
        guard let tab = state.selectedTab else { return }
        guard state.pluginManager.isBuiltinEnabled(BuiltinSkills.ID.htmlBeautifier) else {
            state.showToast(L("beautify.disabledToast"), icon: "wand.and.stars")
            return
        }
        if tab.language == .markdown {
            let original  = tab.content
            let formatted = MarkdownFormatter.format(original)
            guard formatted != original else {
                state.showToast(L("beautify.alreadyClean"), icon: "checkmark.circle")
                return
            }
            let tabID = tab.id
            state.diffReview.present(
                original: original,
                modified: formatted,
                mode: .markdownVsMarkdown,
                onFinalize: { merged in
                    state.applyAIWriteBack(tabID, content: merged)
                }
            )
        } else {
            state.showingBeautifySheet = true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            } else {
                collapsedHandle
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 6, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(theme.isDark ? 0.12 : 0.07), lineWidth: DS.Stroke.hairline)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
    }

    /// 展开态：完整动作组 + 尾部收起手柄。
    private var expandedContent: some View {
        HStack(spacing: 0) {
            actionButton(
                id: "present",
                icon: "play.rectangle",
                label: L("action.present"),
                isDisabled: state.selectedTab == nil || state.selectedTab?.language != .markdown
            ) {
                state.startPresentation()
            }

            dividerSeparator

            actionButton(
                id: "beautify",
                icon: "wand.and.stars",
                label: L("beautify.label"),
                isDisabled: state.selectedTab == nil
            ) {
                beautifyCurrent()
            }

            dividerSeparator

            exportMenuButton()

            dividerSeparator

            shareMenuButton()

            dividerSeparator

            collapseHandle
        }
    }

    /// 收起态：单个圆钮，点击展开。
    private var collapsedHandle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isExpanded = true }
        } label: {
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hoveredAction == "expand" ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(hoveredAction == "expand" ? Color.primary.opacity(0.07) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("actionbar.expand"))
        .onHover { hoveredAction = $0 ? "expand" : nil }
        .animation(DS.Motion.micro, value: hoveredAction)
    }

    /// 展开态尾部的收起手柄。
    private var collapseHandle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isExpanded = false }
        } label: {
            Image(systemName: "chevron.right")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hoveredAction == "collapse" ? Color.primary.opacity(0.85) : Color.primary.opacity(0.45))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(hoveredAction == "collapse" ? Color.primary.opacity(0.07) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("actionbar.collapse"))
        .onHover { hoveredAction = $0 ? "collapse" : nil }
        .animation(DS.Motion.micro, value: hoveredAction)
    }

    @ViewBuilder
    private func actionButton(
        id: String,
        icon: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDisabled
                ? Color.primary.opacity(0.25)
                : hoveredAction == id ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(hoveredAction == id ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        // 防止 HStack 压缩时首个文本被截断成省略号（导出/分享菜单已有 fixedSize）
        .fixedSize()
        .disabled(isDisabled)
        .onHover { hoveredAction = $0 ? id : nil }
        .animation(DS.Motion.micro, value: hoveredAction)
    }

    private var dividerSeparator: some View {
        Divider()
            .frame(width: 0.5, height: 16)
            .opacity(0.25)
            .padding(.horizontal, 2)
    }

    // MARK: - 导出菜单

    @ViewBuilder
    private func exportMenuButton() -> some View {
        let isDisabled = !state.previewExporter.isExportAvailable
        let isHTML = state.previewMode == .html
        let items: [(title: String, format: PreviewExporter.ExportFormat)] = isHTML
            ? [(L("export.markdown"), .markdown), (L("export.pdf"), .pdf), (L("export.image"), .image)]
            : [(L("export.html"), .html), (L("export.pdf"), .pdf), (L("export.image"), .image)]

        Menu {
            Button(L("action.copyRichText")) { state.copyRichTextToPasteboard() }
            Divider()
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.title) { performExport(item.format) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .medium))
                Text(L("action.export"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDisabled
                ? Color.primary.opacity(0.25)
                : hoveredAction == "export" ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(hoveredAction == "export" ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isDisabled)
        .onHover { hoveredAction = $0 ? "export" : nil }
        .animation(DS.Motion.micro, value: hoveredAction)
        .fixedSize()
    }

    private func performExport(_ format: PreviewExporter.ExportFormat) {
        state.requestExport(format)
    }

    // MARK: - 分享菜单

    @ViewBuilder
    private func shareMenuButton() -> some View {
        let isActive = state.shareServer.isRunning
            || state.githubGistManager.lastResultURL != nil

        Menu {
            // 局域网分享
            if state.shareServer.isRunning {
                if let tab = state.selectedTab,
                   let url = state.shareServer.shareURLForFile(tab.url) {
                    Button(L("tab.copyShareURL")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        state.showToast(url, icon: "doc.on.doc")
                    }
                }
                Button(L("tab.stopSharing"), role: .destructive) {
                    state.shareServer.stop()
                    state.showToast(L("share.stopped"), icon: "wifi.slash")
                }
            } else {
                Button(L("tab.shareViaLAN")) {
                    state.shareServer.start(
                        rootURL: state.rootURL,
                        openTabs: state.openTabs,
                        preferredPort: AppSettings.shared.sharePort
                    )
                    // 稍等 listener 就绪后再读 URL
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let tab = state.selectedTab,
                           let url = state.shareServer.shareURLForFile(tab.url) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            state.showToast(L("share.startedCopied"), icon: "wifi")
                        } else {
                            state.showToast(L("share.started"), icon: "wifi")
                        }
                    }
                }
                .disabled(state.openTabs.isEmpty)
            }

            // GitHub Gist
            if state.githubGistManager.isConfigured {
                Divider()
                if let gistURL = state.githubGistManager.lastResultURL {
                    Button(L("github.gist.copyLink")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(gistURL, forType: .string)
                    }
                    Button(L("github.gist.openInBrowser")) {
                        if let url = URL(string: gistURL) { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                }
                Button(state.githubGistManager.isPublishing
                    ? L("github.gist.publishing")
                    : (state.githubGistManager.lastResultURL != nil
                        ? L("github.gist.republish")
                        : L("tab.publishToGitHub"))
                ) {
                    if let tab = state.selectedTab {
                        Task { await state.githubGistManager.publish(tab: tab) }
                    }
                }
                .disabled(state.selectedTab == nil || state.githubGistManager.isPublishing)
            }

            // 在线分享链接（自建 Worker）
            if state.shareLinkPublisher.isConfigured {
                Divider()
                if let linkURL = state.shareLinkPublisher.lastResultURL {
                    Button(L("sharelink.copyLink")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(linkURL, forType: .string)
                    }
                    Button(L("sharelink.openInBrowser")) {
                        if let url = URL(string: linkURL) { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                }
                Button(state.shareLinkPublisher.isPublishing
                    ? L("sharelink.publishing")
                    : (state.shareLinkPublisher.lastResultURL != nil
                        ? L("sharelink.republish")
                        : L("sharelink.publish"))
                ) {
                    if let tab = state.selectedTab {
                        Task {
                            await state.shareLinkPublisher.publish(tab: tab)
                            if let error = state.shareLinkPublisher.lastError {
                                state.setError(error)
                            } else if let url = state.shareLinkPublisher.lastResultURL {
                                state.showToast(L("sharelink.publish") + " · " + url, icon: "globe")
                            }
                        }
                    }
                }
                .disabled(state.selectedTab == nil || state.shareLinkPublisher.isPublishing)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "square.and.arrow.up.fill" : "square.and.arrow.up")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .medium))
                Text(L("action.share"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(
                isActive ? Color.appAccent.opacity(0.85)
                : hoveredAction == "share" ? Color.primary.opacity(0.85)
                : Color.primary.opacity(0.55)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(hoveredAction == "share" ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hoveredAction = $0 ? "share" : nil }
        .animation(DS.Motion.micro, value: hoveredAction)
        .fixedSize()
    }
}
