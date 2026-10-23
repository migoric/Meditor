import AppKit

/// Core coordinator for NativeEditorView. Handles NSTextViewDelegate, scroll sync,
/// AI text insertion, and drag & drop. Slash command logic delegates to SlashCommandHandler;
/// markdown shortcuts live in EditorMarkdownShortcuts.swift.
/// @MainActor：NSTextViewDelegate 回调、滚动同步、自检任务都在主线程；
/// 标注后 self 成为 Sendable，可安全在 @Sendable 回调（DispatchQueue/PasteHTMLConverter）中捕获。
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    var onContentChange: (String) -> Void
    var onCursorChange: ((Int, Int) -> Void)?
    var onVisibleTopLineChange: ((Int) -> Void)?
    var onSelectionChange: ((String) -> Void)?
    var onRangeChange: ((NSRange) -> Void)?
    var lastAcknowledgedContent: String = ""
    var lastAcknowledgedRevision: Int = 0
    var lastReplaceNonce: Int = 0
    var lastWriteBackNonce: Int = 0

    weak var textView: NSTextView? {
        didSet {
            highlighter.textView = textView
            slashHandler.textView = textView
        }
    }

    // deinit 是 nonisolated，访问 Timer/NSObjectProtocol/SlashCommandHandler 这类
    // 非 Sendable 的主 actor 属性在 Swift 6 下会报错；它们在主线程创建/使用、
    // 且在 deinit（唯一引用）中清理，标注 unsafe 即可。
    nonisolated(unsafe) var scrollObserver: NSObjectProtocol?
    var lastAppliedTargetLine: Int = -1
    var lastAppliedRequestID: Int = -1
    var lastInsertRequestID: Int = 0
    var localRevisionPredictionActive = false
    var isProgrammaticChange = false

    let highlighter: EditorHighlightScheduler
    let scrollSync: EditorScrollSyncHandler
    nonisolated(unsafe) let slashHandler = SlashCommandHandler()

    // MARK: - Image paste / drop context

    /// 当前文档 URL（图片落盘位置与相对路径的基准），由 NativeEditorView 同步。
    var documentURL: URL?
    /// 工作区根目录（判断拖入文件是否已在工作区内），由 NativeEditorView 同步。
    var workspaceRoot: URL?
    /// 图片落盘失败时上报错误（toast）。
    var onImageError: ((String) -> Void)?
    let imageAssetService = ImageAssetService()

    /// Slash AI 命令回调：由 NativeEditorView 在 makeCoordinator 后设置。
    var onSlashAIAction: ((SlashAIAction, String, NSRange) -> Void)? {
        get { slashHandler.onAIAction }
        set { slashHandler.onAIAction = newValue }
    }

    nonisolated(unsafe) private var debounceTimer: Timer?
    private var pendingAutoClose: Character?
    private static let autoPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}",
        "\"": "\"", "'": "'", "`": "`"
    ]

    init(onContentChange: @escaping (String) -> Void,
         onCursorChange: ((Int, Int) -> Void)?,
         onVisibleTopLineChange: ((Int) -> Void)?) {
        let hs = EditorHighlightScheduler()
        self.highlighter = hs
        self.scrollSync = EditorScrollSyncHandler(highlighter: hs)
        self.onContentChange = onContentChange
        self.onCursorChange = onCursorChange
        self.onVisibleTopLineChange = onVisibleTopLineChange
    }

    deinit {
        debounceTimer?.invalidate()
        slashHandler.closeMenu()
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Scroll the editor so the given 0-based source line is at the top (preview→editor sync).
    /// select = true 时（全局搜索跳转）额外把光标放到目标行行首，并用系统 Find 指示器
    /// 闪烁高亮整行——一次性视觉提示，不留持久选区。
    func scrollToLine(_ line: Int, select: Bool = false) {
        guard line >= 0,
              let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }
        let sid = PerformanceTracer.begin("EditorScrollToLine", log: PerformanceTracer.editor)
        highlighter.ensureLineOffsets(for: textView.string)
        let safeLine = min(line, max(0, highlighter.lineOffsets.count - 1))
        let charIndex = highlighter.lineOffsets[safeLine]
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: charIndex, length: 0),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let targetY = rect.origin.y + textView.textContainerInset.height
        scrollSync.isProgrammaticScroll = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if select {
            let nsString = textView.string as NSString
            let lineEnd = safeLine + 1 < highlighter.lineOffsets.count
                ? highlighter.lineOffsets[safeLine + 1]
                : nsString.length
            let lineRange = NSRange(location: charIndex, length: max(0, lineEnd - charIndex))
            textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            textView.showFindIndicator(for: lineRange)
        }
        PerformanceTracer.end("EditorScrollToLine", log: PerformanceTracer.editor, id: sid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.scrollSync.isProgrammaticScroll = false
        }
    }

    // MARK: - NSTextViewDelegate

    /// AI 写回前冲刷在途击键：击键后的预览防抖 Timer 捕获的是当时的旧文本，
    /// 若写回落在防抖窗口内，Timer 触发会把「不含写回」的旧文本回推给
    /// updateTabContent（两边 revision 恰好相等，updateNSView 不纠正），
    /// 导致 tab.content 回退、AI 改写静默丢失。这里作废旧 Timer 并回滚
    /// revision 预测增量——击键内容已在 textView 里，由写回自己的
    /// onContentChange 一并携带，不会丢。
    func flushPendingKeystroke() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        if localRevisionPredictionActive {
            localRevisionPredictionActive = false
            lastAcknowledgedRevision &-= 1
        }
    }

    /// 换文档（tab 切换/外部重载）前的冲刷：防抖窗口内的在途击键立即回推给
    /// 当前（旧）tab 的 onContentChange。必须在 updateNSView 替换 onContentChange
    /// 闭包之前调用——防抖 Timer 触发时读的是「那一刻」的闭包，若先替换闭包，
    /// pending 文本会通过新 tab 的闭包写进新 tab；若直接丢弃，pending 击键会随
    /// textView 全量替换而丢失（textView 跨 tab 复用）。
    func flushPendingKeystrokeForDocumentSwitch() {
        // localRevisionPredictionActive 为 true 才说明存在未回推的在途击键
        //（textDidChange 置位，Timer 触发或 flush 后复位）
        guard localRevisionPredictionActive else { return }
        let pending = textView?.string ?? lastAcknowledgedContent
        flushPendingKeystroke()   // 作废旧 Timer 并回滚预测增量
        lastAcknowledgedContent = pending
        // 与防抖 Timer 触发路径一致：回推后模型侧 contentRevision +1，这里同步预测值
        lastAcknowledgedRevision &+= 1
        onContentChange(pending)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard !isProgrammaticChange else { return true }
        if slashHandler.isApplyingCommand { return true }

        if let text, (text == " " || text == "\n"), range.length == 0 {
            if slashHandler.isMenuVisible {
                // 带参数命令（/ask、/polish 等）的空格是参数分隔符（「/ask 问题」），
                // 放行插入不提交命令；Enter 提交路径不变
                if text == " ", slashHandler.isArgumentContext(in: textView, at: range.location) {
                    return true
                }
                return !slashHandler.commitSelection()
            }
            if slashHandler.applyIfNeeded(in: textView, at: range.location) {
                return false
            }
        }

        guard let text, text.count == 1,
              let char = text.first,
              let close = Self.autoPairs[char] else { return true }
        // Skip auto-close for symmetric pairs when preceded by an alphanumeric
        // (avoids inserting a closing quote/backtick when the user is finishing a word).
        if char == close {
            // 只取前一个字符：textStorage.mutableString 不拷全串（textView.string 会拷）
            let ns = textView.textStorage?.mutableString
            if range.location > 0, let prev = ns?.character(at: range.location - 1) {
                if let scalar = Unicode.Scalar(prev), CharacterSet.alphanumerics.contains(scalar) {
                    return true
                }
            }
        }
        if range.length == 0 { pendingAutoClose = close }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = textView, !isProgrammaticChange else { return }

        if let close = pendingAutoClose {
            pendingAutoClose = nil
            let pos = textView.selectedRange().location
            isProgrammaticChange = true
            textView.insertText(String(close), replacementRange: NSRange(location: pos, length: 0))
            textView.setSelectedRange(NSRange(location: pos, length: 0))
            isProgrammaticChange = false
        }

        let newContent = textView.string
        lastAcknowledgedContent = newContent
        if !localRevisionPredictionActive {
            lastAcknowledgedRevision &+= 1
            localRevisionPredictionActive = true
        }
        highlighter.rebuildLineOffsets(for: newContent)

        debounceTimer?.invalidate()
        let delay = Self.previewUpdateDebounce(for: newContent)
        debounceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.localRevisionPredictionActive = false
                self.onContentChange(newContent)
            }
        }

        highlighter.scheduleHighlight(after: 0.3)
        slashHandler.updateMenu(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        onRangeChange?(range)
        if let onCursorChange = onCursorChange {
            let lineIdx = highlighter.lineIndex(
                forCharacterAt: range.location,
                textLength: textView.textStorage?.length ?? 0
            )
            let lineStart = highlighter.lineOffsets[safe: lineIdx] ?? 0
            let column = max(1, range.location - lineStart + 1)
            onCursorChange(lineIdx + 1, column)
        }
        if let onSelectionChange = onSelectionChange {
            // 选区内容从 textStorage 的 live 字符串取，避免为截取选区拷全串
            let text = range.length > 0
                ? (textView.textStorage?.mutableString.substring(with: range)) ?? ""
                : ""
            onSelectionChange(text)
        }
        slashHandler.updateMenu(in: textView)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if slashHandler.isMenuVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                slashHandler.moveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                slashHandler.moveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertTab(_:)):
                return slashHandler.commitSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                slashHandler.closeMenu()
                return true
            default:
                return false
            }
        }
        // Esc：有选区时收起选区（光标落到选区末尾），选区浮动操作条随之关闭；
        // 焦点保持在编辑器，无需额外关条 UI。IME 组合态（hasMarkedText）放行，
        // 让 Esc 归输入法取消候选，不收选区。
        if commandSelector == #selector(NSResponder.cancelOperation(_:)),
           !textView.hasMarkedText(),
           textView.selectedRange().length > 0 {
            textView.setSelectedRange(NSRange(location: NSMaxRange(textView.selectedRange()), length: 0))
            return true
        }
        return false
    }

    // MARK: - AI programmatic edits

    /// AI 插入/替换的共用执行路径，与 writeBack 走同一套 revision 协议：
    /// 先冲刷在途击键（否则防抖 Timer 会把编辑前的旧文本回推给 tab.content），
    /// 编辑过程用 isProgrammaticChange 包裹（避免 textDidChange 再走一遍防抖/
    /// 预测而产生多余的回推），结束后同步 lastAcknowledged* 再回推
    /// onContentChange——否则下一次 updateNSView 会把刚写入的内容误判为外部
    /// 变更而整文重置（光标/滚动丢失）。
    /// requestedRange 是保存时刻的旧区间，AI 流式期间文档可能变短：先 clamp 到
    /// 当前文本长度；起点已越界（无法修正）则跳过本次编辑，避免 NSRangeException。
    func applyProgrammaticReplacement(_ replacement: String, range requestedRange: NSRange, in textView: NSTextView) {
        guard let range = Self.clampedRange(requestedRange, textLength: textView.string.utf16.count) else { return }
        flushPendingKeystroke()
        isProgrammaticChange = true
        // shouldChangeText 被拒时不按成功路径上报（revision 不递增、不回推）
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            isProgrammaticChange = false
            return
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        isProgrammaticChange = false

        let newCaret = range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        let newContent = textView.string
        lastAcknowledgedContent = newContent
        // 与 onContentChange → updateTabContent 的 contentRevision 递增保持同步，
        // 避免紧接着的 updateNSView 把刚写入的内容再整体替换一遍
        lastAcknowledgedRevision &+= 1
        highlighter.rebuildLineOffsets(for: newContent)
        onContentChange(newContent)
        highlighter.scheduleHighlight()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// clamp 替换区间到当前文本范围；起点越界（NSNotFound/负数/超出文本长度）
    /// 时无法修正，返回 nil 表示跳过本次编辑。
    static func clampedRange(_ range: NSRange, textLength: Int) -> NSRange? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location <= textLength else { return nil }
        let length = min(max(range.length, 0), textLength - range.location)
        return NSRange(location: range.location, length: length)
    }

    // MARK: - Image paste

    /// ⌘V 入口（MEditorTextView.paste 调用）：粘贴板含图片时落盘并在光标处插入
    /// Markdown 引用。返回 false = 未处理（无图片 / 无文档上下文 / 落盘失败），
    /// 调用方回退系统默认粘贴。insertText 走 textView 常规编辑路径，自动注册 undo。
    @discardableResult
    func pasteImageFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let textView, let documentURL else { return false }

        // 1) file URL 优先（Finder ⌘C / Photos 等组合 flavor 源）：走
        //    referenceForDroppedFile 的工作区判定——工作区内直接引用原文件，
        //    避免把已有文件落盘重编码一份
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = urls.filter { ImageAssetService.imageExtensions.contains($0.pathExtension.lowercased()) }
        if !images.isEmpty,
           insertDroppedImages(images, in: textView, at: textView.selectedRange().location) {
            return true
        }

        // 2) 粘贴板直接携带的图片数据兜底（截图等无文件来源的场景）
        if let (data, ext) = Self.imageData(from: pasteboard) {
            do {
                let result = try imageAssetService.savePastedImage(
                    data: data, fileExtension: ext, documentURL: documentURL
                )
                insertMarkdownReference(result.markdown, in: textView,
                                        at: textView.selectedRange().location)
                return true
            } catch {
                onImageError?(error.localizedDescription)
                return false
            }
        }

        return false
    }

    /// 从粘贴板提取图片数据：优先 PNG，其次 TIFF（统一转 PNG 落盘）。
    static func imageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        if let data = pasteboard.data(forType: .png) { return (data, "png") }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    // MARK: - Rich text paste (HTML → Markdown)

    /// ⌘V 入口（MEditorTextView.paste 调用，图片之后）：粘贴板含 HTML 时异步
    /// 转成 Markdown 插入光标处。返回 false = 未处理（非 Markdown 文档 / 无
    /// HTML flavor / HTML 无实际标签），调用方回退系统默认粘贴。
    /// insertText 走 textView 常规编辑路径，自动注册 undo。
    /// 要粘贴原始纯文本可用系统「粘贴并匹配样式」（⌥⇧⌘V）。
    @discardableResult
    func pasteRichTextFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let textView else { return false }
        // 只在 Markdown 文档里做转换——HTML/代码文件里粘贴 HTML 应保留原文
        guard highlighter.language == .markdown else { return false }
        guard let html = pasteboard.string(forType: .html),
              Self.containsMarkup(html) else { return false }

        // 转换是异步的（离屏 WebView），先捕获粘贴时刻的选区与文档；
        // 失败时回退插入纯文本 flavor
        let insertionRange = textView.selectedRange()
        let pasteDocumentURL = documentURL
        let plainFallback = pasteboard.string(forType: .string)
        Task { @MainActor [weak self, weak textView] in
            // 端侧清理开关在粘贴时刻快照（默认关；见 AISettingsTab 端侧智能分区）。
            // AppSettings 是 @MainActor，读取必须在此闭包内。
            let onDeviceCleanupEnabled = AppSettings.shared.aiOnDevicePasteCleanup
            PasteHTMLConverter.shared.convert(html: html) { markdown in
                guard let self, let textView else { return }
                // textView 跨 tab 复用：转换期间用户可能已切换 tab，
                // 此时插入会把旧文档的粘贴内容写进新文档——放弃本次插入
                guard self.documentURL == pasteDocumentURL else { return }
                guard let text = (markdown?.isEmpty == false ? markdown : plainFallback),
                      !text.isEmpty else { return }
                // 转换完成后、insertText 之前：开关开启且端侧可用时过一次端侧清理。
                // 关闭（默认）时走原始同步路径，行为与功能不存在时完全一致。
                guard onDeviceCleanupEnabled,
                      FoundationModelService.shared.availability.isAvailable else {
                    self.insertPastedText(text, at: insertionRange, in: textView)
                    return
                }
                Task { @MainActor [weak self, weak textView] in
                    // 清理失败/超时/输出为空时 cleanPastedMarkdown 原样返回原文
                    //（静默回退，不提示），插入路径与正常粘贴一致。
                    let cleaned = await FoundationModelService.shared
                        .cleanPastedMarkdown(text, enabled: true)
                    guard let self, let textView else { return }
                    // 清理（最长 3s）期间用户可能已切换 tab——再次校验，避免把
                    // 旧文档的粘贴内容写进新文档
                    guard self.documentURL == pasteDocumentURL else { return }
                    self.insertPastedText(cleaned, at: insertionRange, in: textView)
                }
            }
        }
        return true
    }

    /// 粘贴插入的共用落点：清理期间用户可能又动了光标/内容，
    /// clamp 捕获的选区到当前文本范围。insertText 走常规编辑路径，自动注册 undo。
    private func insertPastedText(_ text: String, at capturedRange: NSRange, in textView: NSTextView) {
        let textLength = textView.string.utf16.count
        let location = min(capturedRange.location, textLength)
        let length = min(capturedRange.length, textLength - location)
        textView.insertText(text, replacementRange: NSRange(location: location, length: length))
    }

    /// 判断 HTML 字符串是否含有真实标签。Safari 等来源复制纯文本也会带一个
    /// 无标签的 HTML flavor，那种内容走默认粘贴即可，不值得拉起 WebView。
    static func containsMarkup(_ html: String) -> Bool {
        html.range(of: "<[a-zA-Z][^>]*>", options: .regularExpression) != nil
    }

    // MARK: - Image drag & drop

    func textView(_ textView: NSTextView, performDragOperation draggingInfo: NSDraggingInfo) -> Bool {
        guard let items = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }

        let images = items.filter { ImageAssetService.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return false }

        let dropPoint = textView.convert(draggingInfo.draggingLocation, from: nil)
        let charIndex = textView.characterIndexForInsertion(at: dropPoint)
        return insertDroppedImages(images, in: textView, at: charIndex)
    }

    /// 拖入/粘贴文件引用的共用路径：工作区内直接引用（不复制），否则复制进 assets/。
    /// 部分失败时插入成功项并 toast 失败数；全部失败返回 false（回退默认行为）。
    private func insertDroppedImages(_ images: [URL], in textView: NSTextView, at charIndex: Int) -> Bool {
        guard let documentURL else { return false }
        var insertionText = ""
        var failed = 0
        for url in images {
            do {
                let result = try imageAssetService.referenceForDroppedFile(
                    url, documentURL: documentURL, workspaceRoot: workspaceRoot
                )
                insertionText += result.markdown + "\n"
            } catch {
                failed += 1
            }
        }
        if failed > 0 { onImageError?(L("image.dropFailed", failed)) }
        guard !insertionText.isEmpty else { return false }
        insertMarkdownReference(insertionText, in: textView, at: charIndex)
        return true
    }

    /// insertText 走 NSTextView 常规编辑路径：触发 delegate、注册 undo。
    private func insertMarkdownReference(_ markdown: String, in textView: NSTextView, at charIndex: Int) {
        textView.insertText(markdown, replacementRange: NSRange(location: charIndex, length: 0))
    }

    private static func previewUpdateDebounce(for content: String) -> TimeInterval {
        let bytes = content.utf8.count
        switch bytes {
        case 0..<16 * 1024:         return 0.02
        case 16 * 1024..<64 * 1024: return 0.03
        case 64 * 1024..<256 * 1024: return 0.05
        default:                     return 0.08
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
