import SwiftUI

@MainActor
struct EditorView: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let tab = state.selectedTab {
            VStack(spacing: 0) {
                DocumentHeader(tab: tab, theme: state.themeStore.current)

                state.themeStore.current.separator
                    .opacity(state.themeStore.current.isDark ? 0.28 : 0.18)
                    .frame(height: 1)

                ZStack(alignment: .bottom) {
                    if tab.awaitingInitialContent {
                        // Content not yet loaded — show skeleton to avoid empty→content flash
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                    EditorViewContent(
                        tabID: tab.id,
                        content: tab.content,
                        contentRevision: tab.contentRevision,
                        language: tab.language,
                        scrollToLine: state.editorScrollCommand.line,
                        scrollRequestID: state.editorScrollCommand.nonce,
                        scrollSelectsLine: state.editorScrollCommand.selectLine,
                        insertText: state.editorInsertText,
                        insertRequestID: state.editorInsertNonce,
                        replaceText: state.editorReplaceText,
                        replaceRequestID: state.editorReplaceNonce,
                        pendingReplaceRange: state.pendingReplaceRange,
                        writeBackContent: state.editorWriteBackContent,
                        writeBackNonce: state.editorWriteBackNonce,
                        theme: state.themeStore.current,
                        editorFontSize: settings.editorFontSize,
                        editorFont: EditorFont(rawValue: settings.editorFontName) ?? .system,
                        documentURL: tab.url,
                        workspaceRoot: state.rootURL
                    )
                    .equatable()
                    .onAppear  { state.isEditorMounted = true  }
                    .onDisappear { state.isEditorMounted = false }

                    // 空文档占位提示（居中显示，不拦截点击）
                    if tab.content.isEmpty {
                        Text(L("editor.placeholder"))
                            .font(.system(size: 17))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    }

                    // 选区浮动操作条：过短（<2 字符）或纯空行选区不出条
                    if InlineEditBarPlan.shouldShow(for: state.editorSelectedText) {
                        InlineEditBar(selectedText: state.editorSelectedText)
                            .environment(state)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .animation(.easeInOut(duration: 0.18), value: state.editorSelectedText.isEmpty)
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Text(L("editor.selectFile"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("⌘P quick open")
                    Text("·")
                    Text("⌘O open file")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DotGridBackground())
        }
    }
}

@MainActor
private struct DocumentHeader: View {
    let tab: EditorTab
    let theme: PreviewTheme

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileTypeConfiguration.shared.icon(for: tab.url.pathExtension))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: FileTypeConfiguration.shared.color(for: tab.url.pathExtension)).opacity(0.82))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.craftPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if tab.isModified {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                    }
                }

                Text(relativePath)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.craftSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(languageLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.craftSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.craftHover)
                )
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(theme.editorBackground)
    }

    private var relativePath: String {
        FilePathFormatter.relativePath(for: tab.url, rootURL: state.rootURL)
    }

    private var languageLabel: String {
        FileTypeConfiguration.shared
            .editorLanguage(for: tab.url.pathExtension.lowercased())?.rawValue
            .capitalized ?? "Text"
    }
}

/// Inner view that conforms to Equatable — SwiftUI uses this to skip
/// re-evaluation when nothing meaningful changed. The key insight: we
/// compare only `tabID` + `scrollRequestID` + `theme`, NOT the full
/// `content` string. The NSViewRepresentable's `updateNSView` already
/// has its own `lastAcknowledgedContent` gate so it handles content
/// diffs cheaply on its own terms.
/// `@preconcurrency` conformance：View 协议带主 actor 隔离，`==` 被推断为主 actor，
/// 与 Equatable 的 nonisolated 要求冲突。Swift 6.2 可用 isolated conformance
/// （`@MainActor Equatable`），但 iOS CI 的 Xcode 16 不支持；`@preconcurrency`
/// 在两者上都能编译，且 SwiftUI 只在主线程做 equatable 比较。
private struct EditorViewContent: View, @preconcurrency Equatable {
    let tabID: UUID
    let content: String
    let contentRevision: Int
    let language: EditorLanguage
    let scrollToLine: Int
    let scrollRequestID: Int
    let scrollSelectsLine: Bool
    let insertText: String
    let insertRequestID: Int
    let replaceText: String
    let replaceRequestID: Int
    let pendingReplaceRange: NSRange?
    let writeBackContent: String
    let writeBackNonce: Int
    let theme: PreviewTheme
    let editorFontSize: Int
    let editorFont: EditorFont
    let documentURL: URL?
    let workspaceRoot: URL?

    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings

    static func == (lhs: EditorViewContent, rhs: EditorViewContent) -> Bool {
        // Skip content string comparison — O(1) instead of O(n).
        // `contentRevision` preserves correctness for async file loads,
        // external reloads, and model-side content updates.
        lhs.tabID == rhs.tabID &&
        lhs.contentRevision == rhs.contentRevision &&
        lhs.scrollRequestID == rhs.scrollRequestID &&
        lhs.insertRequestID == rhs.insertRequestID &&
        lhs.replaceRequestID == rhs.replaceRequestID &&
        lhs.writeBackNonce == rhs.writeBackNonce &&
        lhs.theme == rhs.theme &&
        lhs.language == rhs.language &&
        lhs.editorFontSize == rhs.editorFontSize &&
        lhs.editorFont == rhs.editorFont &&
        lhs.documentURL == rhs.documentURL &&
        lhs.workspaceRoot == rhs.workspaceRoot
    }

    var body: some View {
        NativeEditorView(
            content: content,
            contentRevision: contentRevision,
            language: language,
            onContentChange: { [tabID] content in
                state.updateTabContent(tabID, content: content)
            },
            onCursorChange: { line, col in
                state.updateCursorPosition(line: line, column: col)
            },
            onVisibleTopLineChange: { line in
                state.editorVisibleLine = line
            },
            scrollToLine: scrollToLine,
            scrollRequestID: scrollRequestID,
            scrollSelectsLine: scrollSelectsLine,
            onSelectionChange: { text in
                state.editorSelectedText = text
            },
            onRangeChange: { range in
                state.editorSelectedRange = range
            },
            onSlashAIAction: { action, documentText, insertionRange in
                guard case .command(let command, let argument) = action else { return }
                SlashAICommandExecutor.run(
                    command: command,
                    argument: argument,
                    documentText: documentText,
                    insertionLocation: insertionRange.location,
                    state: state,
                    settings: settings
                )
            },
            insertText: insertText,
            insertRequestID: insertRequestID,
            replaceText: replaceText,
            replaceRequestID: replaceRequestID,
            pendingReplaceRange: pendingReplaceRange,
            writeBackContent: writeBackContent,
            writeBackNonce: writeBackNonce,
            theme: theme,
            editorFontSize: editorFontSize,
            editorFont: editorFont,
            documentURL: documentURL,
            workspaceRoot: workspaceRoot,
            onImageError: { message in
                state.showToast(message, icon: "exclamationmark.triangle")
            }
        )
    }
}



