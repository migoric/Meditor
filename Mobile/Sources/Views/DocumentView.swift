import SwiftUI
import UniformTypeIdentifiers

/// 文档视图：编辑（TextEditor）与预览（Markdown 原生渲染 / HTML WebView）切换。
struct DocumentView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(ReaderSettings.self) private var reader
    @Environment(ChatModel.self) private var chatModel
    @Environment(AIHeroState.self) private var aiHero

    @State private var showingFilePicker = false
    @State private var showingOpenError = false
    /// 字数统计文案。
    private var wordCount: String {
        let c = store.text.count
        if c < 1000 { return "\(c) 字" }
        return "\(c / 1000).\((c / 100) % 10)k 字"
    }
    /// 保存状态指示颜色：最近 3s 内保存过 → 绿，否则 → 次级文字色。
    private var saveIndicatorColor: Color {
        Date().timeIntervalSince(store.lastSavedAt) < 3 ? .green : PaperTheme.inkSecondary
    }
    /// 发布在线链接的结果弹窗（成功=链接已复制 / 失败=错误信息）。
    @State private var publishAlert: (message: String, url: String?)? = nil
    /// 预览滚动越顶：导航栏从透明过渡到纸底 + 发丝分隔。
    @State private var contentScrolled = false
    /// 空态入场动画开关。
    @State private var emptyStateVisible = false
    /// 空态印章「盖下」动画开关。
    @State private var sealStamped = false

    /// 可导入的文件类型：Markdown / HTML / 纯文本。
    private static let importableTypes: [UTType] = [
        .plainText, .html,
        UTType(filenameExtension: "md"),
        UTType(filenameExtension: "markdown"),
    ].compactMap { $0 }

    /// 顶部是否透明：空态、或预览未滚动时透明；滚动 / 编辑态回到纸底。
    private var transparentHeader: Bool {
        store.hasDocument ? (store.showPreview && !contentScrolled) : true
    }

    var body: some View {
        Group {
            if store.hasDocument {
                content
                    .id(store.showPreview)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)).combined(with: .offset(y: 8)),
                        removal: .opacity
                    ))
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(PaperTheme.Motion.standard, value: store.showPreview)
        // 底栏悬浮在内容之上（safearea 透底），不占布局高度
        .overlay(alignment: .bottom) { DocActionBar() }
        .background(PaperTheme.paperBackground)
        .navigationTitle(store.hasDocument ? store.fileName : "MEditor")
        .navigationBarTitleDisplayMode(.inline)
        // 透明 ↔ 纸底的过渡随滚动状态缓动
        .toolbarBackground(transparentHeader ? .hidden : .visible, for: .navigationBar)
        .animation(PaperTheme.Motion.gentle, value: transparentHeader)
        .onPreferenceChange(PreviewScrollOffsetKey.self) { minY in
            contentScrolled = minY < -8
        }
        .toolbar {
            // 标题自绘：文档文件名 / 品牌字保留衬线（UI chrome 其余部分是无衬线）。
            // 操作动作全部沉到底部动作条，头部只留标题和 ⋯ 菜单。
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(store.hasDocument ? store.fileName : "MEditor")
                        .font(.system(.headline, design: .serif, weight: .semibold))
                        .foregroundStyle(PaperTheme.ink)
                        .lineLimit(1)
                    if store.hasDocument && !store.showPreview {
                        HStack(spacing: 4) {
                            Text(wordCount)
                                .font(.caption2)
                                .foregroundStyle(PaperTheme.inkSecondary)
                            Circle()
                                .fill(saveIndicatorColor)
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
            if store.hasDocument {
                ToolbarItem(placement: .topBarTrailing) {
                    documentMenu
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.openIncoming(url)
            }
        }
        // 打开失败：无论空态还是已有文档，都明确弹窗告知（真机权限/iCloud 问题全靠它暴露）
        .onChange(of: store.lastError) { _, newValue in
            showingOpenError = newValue != nil
        }
        .alert("无法打开文件", isPresented: $showingOpenError) {
            Button("好", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        // 发布结果：成功显示链接已复制（可打开），失败显示原因
        .alert("在线分享", isPresented: Binding(
            get: { publishAlert != nil },
            set: { if !$0 { publishAlert = nil } }
        )) {
            if let url = publishAlert?.url, let link = URL(string: url) {
                Button("打开链接") { UIApplication.shared.open(link) }
            }
            Button("好", role: .cancel) { publishAlert = nil }
        } message: {
            Text(publishAlert?.message ?? "")
        }
    }

    // MARK: - 底部栏

    /// 导航栏「⋯」菜单：阅读设置 / 分享 / 复制等文档级操作的归宿。
    private var documentMenu: some View {
        Menu {
            Menu {
                Section("字号") {
                    ForEach(ReaderSettings.FontScale.allCases) { scale in
                        Button {
                            reader.fontScale = scale
                        } label: {
                            if reader.fontScale == scale {
                                Label(scale.displayName, systemImage: "checkmark")
                            } else {
                                Text(scale.displayName)
                            }
                        }
                    }
                }
                Section("行距") {
                    ForEach(ReaderSettings.LineSpacing.allCases) { spacing in
                        Button {
                            reader.lineSpacing = spacing
                        } label: {
                            if reader.lineSpacing == spacing {
                                Label(spacing.displayName, systemImage: "checkmark")
                            } else {
                                Text(spacing.displayName)
                            }
                        }
                    }
                }
            } label: {
                Label("阅读设置", systemImage: "textformat.size")
            }
            ShareLink(item: store.text, subject: Text(store.fileName)) {
                Label("分享全文", systemImage: "square.and.arrow.up")
            }
            if store.kind == .markdown {
                Button {
                    publishOnline()
                } label: {
                    if ShareLinkPublisher.shared.isPublishing {
                        Label("正在发布…", systemImage: "globe")
                    } else {
                        Label("发布在线链接", systemImage: "globe")
                    }
                }
                .disabled(ShareLinkPublisher.shared.isPublishing)
            }
            Button {
                Pasteboard.copy(store.text)
            } label: {
                Label("复制全文", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PaperTheme.inkSecondary)
        }
    }

    /// 模板按钮：引导用户从空白文档开始。
    private func templateButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(PaperTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(PaperTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: PaperTheme.cardShadow, radius: 6, y: 2)
        }
        .buttonStyle(.pressable)
    }

    /// 用模板内容填充新文档并推入编辑态。
    private func fillTemplate(_ text: String) {
        store.createDocument()
        store.applyManualEdit(text)
        store.showPreview = false
    }

    /// 发布当前 Markdown 文档为在线链接；结果经弹窗反馈。
    private func publishOnline() {
        let publisher = ShareLinkPublisher.shared
        publisher.refreshTokenStatus()
        guard publisher.isConfigured else {
            publishAlert = (message: "请先在 设置 → 在线分享 中配置 Token", url: nil)
            return
        }
        Task {
            await publisher.publish(
                fileName: store.fileName,
                markdown: store.text,
                baseDirectory: store.sandboxURL?.deletingLastPathComponent()
            )
            if let url = publisher.lastResultURL {
                publishAlert = (message: "链接已复制到剪贴板：\n\(url)", url: url)
            } else {
                publishAlert = (message: publisher.lastError ?? "发布失败", url: nil)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.showPreview {
            switch store.kind {
            case .html:
                HTMLPreviewView(html: store.text)
            case .markdown:
                MarkdownPreviewView(source: store.text)
            case .other:
                ScrollView {
                    Text(store.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(PaperTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PaperTheme.Spacing.page)
                        .padding(.vertical, 18)
                }
            }
        } else {
            // 手动编辑经 applyManualEdit 进 store：触发防抖自动保存，进程退出不丢内容。
            // UITextView 封装：拿得到光标，挂 Markdown 键盘工具条。
            MarkdownTextEditor(
                text: Binding(
                    get: { store.text },
                    set: { store.applyManualEdit($0) }
                ),
                fontScale: reader.scaleFactor,
                onAIRefine: { selected in
                    chatModel.setPendingReplace(original: selected)
                    chatModel.input = "帮我优化这段文字：\n\n\(selected)"
                    aiHero.isOpen = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        chatModel.send()
                    }
                }
            )
        }
    }

    /// 空态：品牌标识 + 打开文件入口（轻微入场：fade + 上移）。
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: PaperTheme.Radius.xlarge, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaperTheme.Radius.xlarge, style: .continuous)
                        .strokeBorder(PaperTheme.hairline, lineWidth: PaperTheme.Stroke.hairline)
                }
                .shadow(color: PaperTheme.cardShadow, radius: 12, y: 4)

            HStack(alignment: .center, spacing: 10) {
                Text("MEditor")
                    .font(PaperTheme.Typography.brandTitle())
                    .foregroundStyle(PaperTheme.ink)
                // 印章「盖下」：放大淡入后弹落到名旁，像真章落纸
                SealStamp(size: 28)
                    .offset(y: 4)
                    .scaleEffect(sealStamped ? 1 : 1.8)
                    .opacity(sealStamped ? 1 : 0)
                    .rotationEffect(.degrees(sealStamped ? 0 : 12))
            }
            .padding(.top, 26)

            Text("纸墨之间，从容书写。")
                .font(PaperTheme.Typography.uiTitle3())
                .foregroundStyle(PaperTheme.inkSecondary)
                .padding(.top, 8)

            Text("从文件 App 选择 .md / .html 打开，或在微信等 App 中选择「用其他应用打开」发送到 MEditor。")
                .font(.subheadline)
                .foregroundStyle(PaperTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 300)
                .padding(.top, 16)

            Button {
                showingFilePicker = true
            } label: {
                Label("打开文件", systemImage: "folder")
            }
            .buttonStyle(.paperPrimary)
            .padding(.top, 26)

            // 快速模板
            HStack(spacing: 12) {
                templateButton(icon: "doc.text", title: "写日记") {
                    fillTemplate("# 日记\n\n**\(Date.now.formatted(date: .long, time: .omitted))**\n\n今天\n\n")
                }
                templateButton(icon: "checklist", title: "待办列表") {
                    fillTemplate("# 待办\n\n- [ ] 任务 1\n- [ ] 任务 2\n- [ ] 任务 3\n")
                }
            }
            .padding(.top, 16)

            Spacer()
        }
        .padding(.horizontal, PaperTheme.Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(emptyStateVisible ? 1 : 0)
        .offset(y: emptyStateVisible ? 0 : 14)
        .onAppear {
            withAnimation(PaperTheme.Motion.gentle) { emptyStateVisible = true }
            // 印章晚半拍盖下，等名字先落纸
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62).delay(0.4)) {
                sealStamped = true
            }
        }
    }
}

// MARK: - 文档底栏（独立 struct，隔离 HeroState/Store 观察范围）

/// 文档页的底部动作栏：编辑/预览切换 + AI/新建。独立 struct 避免父视图状态变化时重建。
private struct DocActionBar: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.heroNamespace) private var heroNS

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { store.showPreview.toggle() } label: {
                    Image(systemName: store.showPreview ? "pencil" : "doc.richtext")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(store.showPreview ? PaperTheme.inkSecondary : PaperTheme.accent)
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .frame(width: 52)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(store.showPreview ? "编辑" : "预览")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(GlassCapsuleBackground())

            Spacer()

            HStack(spacing: 8) {
                BarAIButton(context: "doc")
                BarPlusButton(context: "doc")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(GlassCapsuleBackground())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
