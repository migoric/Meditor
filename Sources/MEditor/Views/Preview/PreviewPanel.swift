import AppKit
import SwiftUI
import Combine

@MainActor
struct PreviewPanel: View {
    @Environment(AppState.self) private var state
    @Environment(WorkspaceUIState.self) private var workspaceUI
    @State private var fontSize: Int = AppSettings.shared.previewFontSize
    @State private var tocItems: [TOCItem] = []
    @State private var activeTOCIndex: Int = -1
    @State private var scrollSync = ScrollSyncState()

    private let tocWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            // 仅在有标题条目时展示 TOC，避免空白占位区域。
            if showsMarkdown && !tocItems.isEmpty {
                TOCOutlineView(
                    items: tocItems,
                    theme: state.themeStore.current,
                    activeLineIndex: activeTOCIndex,
                    isLoading: isLoadingMarkdown,
                    onSelect: { item in
                        guard item.line >= 0 else { return }
                        if let idx = tocItems.firstIndex(where: { $0.id == item.id }) {
                            activeTOCIndex = idx
                        }
                        scrollSync.registerTOCNavigation()
                        state.requestEditorScroll(to: item.line)
                        state.requestPreviewScroll(to: item.line)
                    }
                )
                .frame(width: tocWidth)
                // 与预览同底色：detail 列左上角系统圆角处不会再显出一块
                // 对比强烈的灰色（用户误以为 tab 圆角的那个色块）
                .background(state.themeStore.current.editorBackground)

                state.themeStore.current.separator
                    .opacity(state.themeStore.current.isDark ? 0.32 : 0.22)
                    .frame(width: 1)
            }

            ZStack {
                if showsMarkdown {
                    MarkdownWebPreview(
                        content: state.previewContent,
                        contentRevision: state.previewContentRevision,
                        theme: state.themeStore.current,
                        scrollToLine: state.previewScrollCommand.line,
                        scrollRequestID: state.previewScrollCommand.nonce,
                        onVisibleLineChange: { line in
                            state.previewVisibleLine = line
                            let shouldPropagate = scrollSync.shouldPropagatePreviewScroll()
                            if shouldPropagate {
                                state.requestEditorScroll(to: line)
                            }
                            updateActiveTOC(visibleLine: line)
                        },
                        onTOCUpdate: { items in
                            tocItems = items
                            updateActiveTOC(visibleLine: state.previewVisibleLine)
                        },
                        exporter: state.previewExporter,
                        sourceURL: state.selectedTab?.url,
                        fontSize: fontSize,
                        findController: state.previewFindController,
                        onSelectionChange: { text, rect in
                            withAnimation(DS.Motion.fast) {
                                state.previewSelectedText = text
                                state.previewSelectedRect = rect
                            }
                        },
                        onAddTodo: { text in
                            state.appendTodoToCurrentFile(text)
                        }
                    )
                    .overlay {
                        inlineEditBarOverlay
                    }
                } else if showsHTML {
                    if isLoadingHTML {
                        // 内容还没读进来（恢复会话/大文件异步读）。此时建 WKWebView 只会
                        // 先 loadHTMLString 一个空页，等文件读完再导航一次——两次解析，
                        // 中间还是一片白。等内容到了再建，只导航一次。
                        // 编辑器侧对 awaitingInitialContent 也是同样的处理（EditorView）。
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WebPreviewView(
                            fileURL: state.previewHTMLFileURL,
                            reloadToken: state.previewReloadToken,
                            content: state.previewContent,
                            exporter: state.previewExporter,
                            rootURL: state.rootURL,
                            findController: state.previewFindController,
                            onSelectionChange: { text, rect in
                                withAnimation(DS.Motion.fast) {
                                    state.previewSelectedText = text
                                    state.previewSelectedRect = rect
                                }
                            },
                            onAddTodo: { text in
                                state.appendTodoToCurrentFile(text)
                            }
                        )
                        .overlay {
                            inlineEditBarOverlay
                        }
                    }
                } else {
                    emptyState
                        .background(Color(nsColor: .textBackgroundColor))
                }

                if isShowingLoadingOverlay {
                    loadingOverlay
                }

                if state.previewFindController.isPresented && state.previewMode != .empty {
                    VStack {
                        HStack {
                            Spacer()
                            PreviewFindBar(
                                controller: state.previewFindController,
                                theme: state.themeStore.current
                            )
                        }
                        Spacer()
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if state.previewMode != .empty && !state.previewFindController.isPresented
                    && !workspaceUI.isFocusMode {
                    DocumentActionBar()
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            state.previewFindController.activeMode = state.previewMode
        }
        .onChange(of: state.selectedTabID) { _, _ in
            resetTOCIfNeeded()
        }
        .onChange(of: state.previewMode) { _, newMode in
            if newMode != .markdown {
                tocItems = []
                activeTOCIndex = -1
            }
        }
        .onChange(of: state.editorVisibleLine) { _, newLine in
            if scrollSync.shouldPropagateEditorScroll() {
                // Editor scroll drives preview scroll (normal editor↔preview sync)
                state.requestPreviewScroll(to: newLine)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewFontSizeChanged)) { _ in
            fontSize = AppSettings.shared.previewFontSize
        }
    }

    private var showsMarkdown: Bool { state.previewMode == .markdown }
    private var showsHTML: Bool { state.previewMode == .html }

    /// 选中文档的内容还没读进来（恢复会话或大文件异步读取）。
    private var isAwaitingInitialContent: Bool {
        state.selectedTab?.awaitingInitialContent ?? false
    }
    private var isLoadingMarkdown: Bool { showsMarkdown && isAwaitingInitialContent }
    private var isLoadingHTML: Bool { showsHTML && isAwaitingInitialContent }

    /// 加载指示器：Markdown 与 HTML 都要有——HTML 此前没有任何反馈，白屏期间
    /// 用户只能看到一片空白，分不清是在加载还是卡死。
    private var isShowingLoadingOverlay: Bool { isLoadingMarkdown || isLoadingHTML }

    /// 圈选操作浮动条：跟随选区位置摆放（选区下方，贴底时翻到上方；
    /// 无位置信息时回退到底部居中）。
    private var inlineEditBarOverlay: some View {
        GeometryReader { geo in
            if !state.previewSelectedText.isEmpty {
                let r = state.previewSelectedRect
                let hasRect = r != .zero
                let x = hasRect
                    ? min(max(r.midX, 90), max(90, geo.size.width - 90))
                    : geo.size.width / 2
                let belowY = r.maxY + 30
                let y = !hasRect
                    ? geo.size.height - 30
                    : (belowY > geo.size.height - 34 ? r.minY - 30 : belowY)
                PreviewInlineEditBar(
                    selectedText: state.previewSelectedText,
                    onDismiss: { state.previewSelectedText = "" }
                )
                .position(x: x, y: y)
                .transition(.opacity)
            }
        }
    }

    private func updateActiveTOC(visibleLine: Int) {
        guard !tocItems.isEmpty else { activeTOCIndex = -1; return }
        var best = -1
        for (idx, item) in tocItems.enumerated() {
            if item.line <= visibleLine { best = idx }
            else { break }
        }
        activeTOCIndex = best
    }

    private func resetTOCIfNeeded() {
        // Do NOT clear tocItems immediately — keeping stale items prevents the
        // TOC panel from collapsing and re-expanding (which causes layout jank).
        // The items will be replaced by onTOCUpdate when the new content renders.
        guard state.selectedTab?.language == .markdown else {
            tocItems = []
            activeTOCIndex = -1
            return
        }
        activeTOCIndex = -1
    }

    private var emptyState: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DotGridBackground())
    }

    private var loadingOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 64, height: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(state.themeStore.current.chromeBackground.opacity(state.themeStore.current.isDark ? 0.94 : 0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(state.themeStore.current.separator.opacity(state.themeStore.current.isDark ? 0.5 : 0.24), lineWidth: DS.Stroke.regular)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .dsElevation(.toast)
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }
}

private struct PreviewFindBar: View {
    @Bindable var controller: PreviewFindController
    let theme: PreviewTheme

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .medium))

            PreviewFindTextField(
                placeholder: L("preview.findPlaceholder"),
                text: Binding(
                    get: { controller.query },
                    set: { controller.updateQuery($0) }
                ),
                isFocused: fieldFocused,
                onSubmit: {
                    controller.findNext()
                },
                onShiftSubmit: {
                    controller.findPrevious()
                }
            )
            .frame(width: 180)
            .focused($fieldFocused)

            if controller.matchCount > 0 {
                Text("\(controller.currentMatchIndex)/\(controller.matchCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            } else if !controller.hasMatch && !controller.query.isEmpty {
                Text(L("preview.findNoResults"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                controller.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("menu.findPrevious"))

            Button {
                controller.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("menu.findNext"))

            Button {
                controller.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.chromeBackground.opacity(theme.isDark ? 0.96 : 0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.separator.opacity(theme.isDark ? 0.9 : 0.6), lineWidth: DS.Stroke.regular)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dsElevation(.toast)
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: controller.focusToken) { _, _ in
            fieldFocused = true
        }
    }
}

private struct PreviewFindTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onShiftSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onShiftSubmit: onShiftSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onShiftSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onShiftSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
            self.onShiftSubmit = onShiftSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if modifiers.contains(.shift) {
                    onShiftSubmit()
                } else {
                    onSubmit()
                }
                return true
            default:
                return false
            }
        }
    }
}
