import SwiftUI
import AppKit
import os

// MARK: - EditorViewProtocol
// NativeEditorView 是 EditorViewProtocol 的 macOS 实现。
// 所有对外暴露的属性/回调均与 Protocols/EditorViewProtocol.swift 中的定义保持一致。
// 注意：NSViewRepresentable 与 protocol EditorViewProtocol: View 存在关联类型冲突，
// 无法在运行时做类型擦除，因此 NativeEditorView 以文档契约方式符合协议，
// 不做 Swift 静态 conformance 声明。未来 iOS/visionOS 实现请对照协议补齐全部成员。

/// A native NSTextView-based code editor with basic syntax highlighting.
/// Avoids WKWebView/CDN/JS bridge complexity.
struct NativeEditorView: NSViewRepresentable {
    /// Files larger than this threshold skip regex highlighting entirely.
    static let syntaxHighlightThreshold = 150 * 1024

    typealias Coordinator = EditorCoordinator

    let content: String
    let contentRevision: Int
    let language: EditorLanguage
    let onContentChange: (String) -> Void
    let onCursorChange: ((Int, Int) -> Void)?
    /// Reports the 0-based line index visible at the top of the editor.
    /// Used to drive editor→preview scroll sync.
    let onVisibleTopLineChange: ((Int) -> Void)?
    /// Target line to scroll the editor to (preview→editor sync). -1 = none.
    let scrollToLine: Int
    /// Monotonic token so the same target line can be requested more than once.
    let scrollRequestID: Int
    /// true = 滚动后光标落到目标行并闪烁高亮（全局搜索跳转）；false = 纯滚动。
    var scrollSelectsLine: Bool = false
    /// Reports the currently selected text (empty when nothing is selected).
    var onSelectionChange: ((String) -> Void)? = nil
    /// Reports the current NSRange selection (used to save range before sheet opens).
    var onRangeChange: ((NSRange) -> Void)? = nil
    /// Slash AI 命令回调，由 EditorView 封装 AppState 操作。
    var onSlashAIAction: ((SlashAIAction, String, NSRange) -> Void)? = nil
    /// Text to insert at the caret / over the selection (driven by the AI panel).
    var insertText: String = ""
    /// Monotonic token so the same insert can be requested more than once.
    var insertRequestID: Int = 0
    /// Text to replace a saved NSRange (driven by InlineEdit accept).
    var replaceText: String = ""
    /// Monotonic token so the same replace can be requested more than once.
    var replaceRequestID: Int = 0
    /// The saved NSRange to replace (nil = use current selection).
    var pendingReplaceRange: NSRange? = nil
    /// AI diff 审阅接受后的整文写回内容（最小化可撤销替换，保留滚动/光标/undo）。
    var writeBackContent: String = ""
    /// Monotonic token so the same write-back can be requested more than once.
    var writeBackNonce: Int = 0
    /// Theme drives the text view's background and foreground colors so the
    /// editor pane visually matches the rest of the app.
    var theme: PreviewTheme = .github
    /// Editor font size in points. Defaults to the shared AppSettings value.
    /// Default 14pt (同 AppSettings 默认值)。父视图（@MainActor）可在初始化时传入实际值。
    var editorFontSize: Int = 14
    /// 编辑器正文字体（对应 AppSettings.editorFontName）。默认跟随系统字体。
    var editorFont: EditorFont = .system

    /// 当前文档 URL：图片粘贴/拖拽落盘的基准目录，由 EditorView 传入。
    var documentURL: URL? = nil
    /// 工作区根目录：拖入的工作区内图片直接引用不复制。
    var workspaceRoot: URL? = nil
    /// 图片落盘失败的错误上报（toast）。
    var onImageError: ((String) -> Void)? = nil

    /// 按当前设置解析正文基础字体。
    private var resolvedBaseFont: NSFont {
        editorFont.nsFont(size: CGFloat(editorFontSize))
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            onContentChange: onContentChange,
            onCursorChange: onCursorChange,
            onVisibleTopLineChange: onVisibleTopLineChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 自建 text view（MEditorTextView 子类，拦截图片粘贴）替代
        // NSTextView.scrollablePlainDocumentContentTextView() 工厂；
        // 下列 min/maxSize、resizable、container 配置与工厂方法一致。
        let textView = MEditorTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        // 与工厂方法一致：⌘F 走内联 find bar，而不是旧式浮动 Find Panel
        textView.usesFindBar = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.documentView = textView

        textView.imagePasteHandler = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.pasteImageFromPasteboard(pasteboard) ?? false
        }
        textView.richPasteHandler = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.pasteRichTextFromPasteboard(pasteboard) ?? false
        }

        textView.isRichText = false
        textView.allowsUndo = true
        // Generous insets give the content room to breathe — code editors
        // can feel cramped when text starts at the very edge.
        textView.textContainerInset = NSSize(width: 24, height: 20)
        // 字体跟随设置页（编辑器字体/字号）。默认系统 UI 字体（非等宽）：渲染中日韩
        // 字符时字形宽度正确，避免等宽 + CJK 回退产生的行间空隙。
        // Code spans / fenced blocks switch to monospaced via the highlighter.
        textView.font = resolvedBaseFont
        context.coordinator.highlighter.baseFont = resolvedBaseFont

        // Comfortable line height + a touch of paragraph spacing for prose feel.
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = 1.18
        baseParagraph.paragraphSpacing = 4
        textView.defaultParagraphStyle = baseParagraph
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textColor = theme.foregroundNSColor
        textView.backgroundColor = theme.editorBackgroundNSColor
        textView.drawsBackground = true
        textView.insertionPointColor = theme.foregroundNSColor

        // Performance: enable non-contiguous layout so the text system only
        // lays out visible glyphs eagerly. Crucial for opening large markdown
        // files without a multi-second hang.
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Turn off scrollView border
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        // Line number gutter
        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        if let ruler = LineNumberRulerView(textView: textView, highlighter: context.coordinator.highlighter) {
            scrollView.verticalRulerView = ruler
        }

        // Accept image file drops
        textView.registerForDraggedTypes([.fileURL])

        // Observe scroll position changes for preview sync
        let center = NotificationCenter.default
        context.coordinator.scrollObserver = center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            guard let coordinator = coordinator,
                  let textView = coordinator.textView else { return }
            guard !coordinator.scrollSync.isProgrammaticScroll else { return }
            let line = coordinator.scrollSync.computeVisibleTopLine(textView: textView)
            // Throttle: only emit on line changes, not every pixel scroll.
            guard line != coordinator.scrollSync.lastReportedLine else { return }
            coordinator.scrollSync.lastReportedLine = line
            coordinator.onVisibleTopLineChange?(line)
            coordinator.highlighter.scheduleVisibleRangeHighlight()
        }

        if !content.isEmpty {
            textView.string = content
            context.coordinator.lastAcknowledgedContent = content
            context.coordinator.lastAcknowledgedRevision = contentRevision
            context.coordinator.highlighter.rebuildLineOffsets(for: content)
            context.coordinator.highlighter.scheduleHighlight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 换文档（tab 切换/外部重载，即下面的 revision 分支将全量替换内容）时，
        // 先把防抖窗口内的在途击键回推给旧 tab 的闭包——必须发生在替换
        // onContentChange 之前：防抖 Timer 触发时读的是「那一刻」的闭包，
        // 先替换会把旧 tab 的 pending 文本通过新 tab 的闭包写进新 tab（数据损坏）。
        if context.coordinator.lastAcknowledgedRevision != contentRevision {
            context.coordinator.flushPendingKeystrokeForDocumentSwitch()
        }
        context.coordinator.onContentChange = onContentChange
        context.coordinator.onCursorChange = onCursorChange
        context.coordinator.onVisibleTopLineChange = onVisibleTopLineChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onRangeChange = onRangeChange
        context.coordinator.onSlashAIAction = onSlashAIAction
        context.coordinator.documentURL = documentURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onImageError = onImageError
        context.coordinator.highlighter.language = language

        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Apply theme colors when theme changes.
        if context.coordinator.highlighter.theme != theme {
            context.coordinator.highlighter.theme = theme
            textView.backgroundColor = theme.editorBackgroundNSColor
            textView.textColor = theme.foregroundNSColor
            textView.insertionPointColor = theme.foregroundNSColor
            // Re-highlight to refresh attribute colors that depend on theme.
            context.coordinator.highlighter.scheduleHighlight()
        }

        // 设置页字体/字号变化时实时跟随：更新 textView 与高亮器基础字体后重新高亮
        //（高亮器会重写 .font 属性，只改 textView.font 对已排版文本不生效）。
        let newBaseFont = resolvedBaseFont
        if context.coordinator.highlighter.baseFont != newBaseFont {
            context.coordinator.highlighter.baseFont = newBaseFont
            textView.font = newBaseFont
            context.coordinator.highlighter.scheduleHighlight()
        }

        // Only push content to the editor if it changed externally (e.g., tab switch).
        // Highlighting is deferred to the next runloop tick so the user sees plain
        // text instantly, with syntax colors fading in shortly after.
        if context.coordinator.lastAcknowledgedRevision != contentRevision {
            context.coordinator.localRevisionPredictionActive = false
            context.coordinator.lastAcknowledgedRevision = contentRevision
            context.coordinator.isProgrammaticChange = true
            // 全量替换即「换文档」语义：清空 UndoManager，否则 ⌘Z 会把旧文档的
            // 编辑记录按旧 range 应用到新文档。performUndoableWriteBack 路径是
            // 故意保留 undo 的（AI 写回可撤销），不要在那里清。
            textView.undoManager?.removeAllActions()
            textView.string = content
            context.coordinator.lastAcknowledgedContent = content
            context.coordinator.highlighter.rebuildLineOffsets(for: content)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.highlighter.scheduleHighlight()
        }

        // Sync editor scroll position from preview using source line.
        if scrollToLine >= 0 && scrollRequestID != context.coordinator.lastAppliedRequestID {
            context.coordinator.lastAppliedTargetLine = scrollToLine
            context.coordinator.lastAppliedRequestID = scrollRequestID
            context.coordinator.scrollToLine(scrollToLine, select: scrollSelectsLine)
        }

        // Insert text from the AI panel at the caret (replacing any selection).
        if insertRequestID != context.coordinator.lastInsertRequestID {
            context.coordinator.lastInsertRequestID = insertRequestID
            if insertRequestID > 0, !insertText.isEmpty {
                // 与 writeBack 同一套 revision 协议：flush 在途击键、
                // isProgrammaticChange 包裹、同步 lastAcknowledged*
                context.coordinator.applyProgrammaticReplacement(
                    insertText, range: textView.selectedRange(), in: textView
                )
            }
        }

        // Replace a saved selection range (driven by InlineEdit accept).
        if replaceRequestID != context.coordinator.lastReplaceNonce {
            context.coordinator.lastReplaceNonce = replaceRequestID
            if replaceRequestID > 0, !replaceText.isEmpty {
                // pendingReplaceRange 是保存时刻的旧区间，AI 流式期间文档可能
                // 变短——applyProgrammaticReplacement 内会 clamp，越界则跳过
                let range = pendingReplaceRange ?? textView.selectedRange()
                context.coordinator.applyProgrammaticReplacement(
                    replaceText, range: range, in: textView
                )
            }
        }

        // AI diff 审阅接受后的整文写回：公共前后缀最小化替换，走
        // shouldChangeText/didChangeText 注册 undo（AI 改写可 ⌘Z 一步撤回），
        // 并保留写回前的光标与滚动位置——不做 textView.string 整体替换。
        if writeBackNonce != context.coordinator.lastWriteBackNonce {
            context.coordinator.lastWriteBackNonce = writeBackNonce
            if writeBackNonce > 0 {
                performUndoableWriteBack(textView, scrollView: scrollView,
                                         newContent: writeBackContent, context: context)
            }
        }
    }

    /// 整文写回的最小化可撤销实现：只替换公共前后缀之间的差异区间。
    private func performUndoableWriteBack(_ textView: NSTextView, scrollView: NSScrollView,
                                          newContent merged: String, context: Context) {
        let current = textView.string
        guard merged != current else { return }

        let curNS = current as NSString
        let newNS = merged as NSString
        var prefix = 0
        let maxPrefix = min(curNS.length, newNS.length)
        while prefix < maxPrefix, curNS.character(at: prefix) == newNS.character(at: prefix) { prefix += 1 }
        var suffix = 0
        let maxSuffix = min(curNS.length - prefix, newNS.length - prefix)
        while suffix < maxSuffix,
              curNS.character(at: curNS.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix) { suffix += 1 }
        // 边界不能劈开 surrogate pair（emoji 等），否则 replaceCharacters 会产出非法串
        if prefix > 0, prefix < maxPrefix,
           UTF16.isLeadSurrogate(curNS.character(at: prefix - 1)),
           UTF16.isTrailSurrogate(curNS.character(at: prefix)) { prefix -= 1 }
        let suffixBoundary = curNS.length - suffix
        if suffix > 0, suffixBoundary > 0, suffixBoundary < curNS.length,
           UTF16.isLeadSurrogate(curNS.character(at: suffixBoundary - 1)),
           UTF16.isTrailSurrogate(curNS.character(at: suffixBoundary)) { suffix -= 1 }

        let range = NSRange(location: prefix, length: curNS.length - prefix - suffix)
        let replacement = newNS.substring(with: NSRange(location: prefix, length: newNS.length - prefix - suffix))

        let oldCaret = textView.selectedRange().location
        let savedOrigin = scrollView.contentView.bounds.origin

        // 冲刷在途击键的防抖 Timer：否则它会把写回前的旧文本回推给 tab.content
        context.coordinator.flushPendingKeystroke()

        context.coordinator.isProgrammaticChange = true
        // shouldChangeText 被拒时不消费本次写回：直接返回，不按成功路径上报
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            context.coordinator.isProgrammaticChange = false
            return
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        context.coordinator.isProgrammaticChange = false

        let newText = textView.string
        // 光标：替换区间之前的保持不动，之后的平移，区间内的落到替换文本末尾
        let delta = (replacement as NSString).length - range.length
        let caret: Int
        if oldCaret <= range.location {
            caret = oldCaret
        } else if oldCaret >= NSMaxRange(range) {
            caret = oldCaret + delta
        } else {
            caret = range.location + (replacement as NSString).length
        }
        textView.setSelectedRange(NSRange(location: min(caret, (newText as NSString).length), length: 0))

        // 滚动：写回前视口原样保留（AppKit 自动夹取到有效范围）
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.lastAcknowledgedContent = newText
        // 与 onContentChange → updateTabContent 的 contentRevision 递增保持同步，
        // 避免紧接着的 updateNSView 把刚写入的内容再整体替换一遍
        context.coordinator.lastAcknowledgedRevision &+= 1
        context.coordinator.highlighter.rebuildLineOffsets(for: newText)
        context.coordinator.onContentChange(newText)
        context.coordinator.highlighter.scheduleHighlight()
    }
}

extension NSFont {
    var isBold: Bool {
        fontDescriptor.symbolicTraits.contains(.bold)
    }
}

extension EditorFont {
    /// 解析为指定字号的 NSFont，候选字体不可用时回退到系统字体。
    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size)
        case .sfMono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .newYork:
            // New York 是系统衬线字体，通过 serif design descriptor 获取最可靠。
            let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return serif.flatMap { NSFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size)
        case .pingFang:
            return NSFont(name: "PingFang SC", size: size)
                ?? .systemFont(ofSize: size)
        }
    }
}
