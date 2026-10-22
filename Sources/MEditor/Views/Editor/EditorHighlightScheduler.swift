import AppKit

/// Owns syntax highlighting timers and the line-offset index.
/// Decoupled from Coordinator so scroll sync can query offsets independently.
final class EditorHighlightScheduler {
    weak var textView: NSTextView?
    var theme: PreviewTheme = .github
    var language: EditorLanguage = .markdown
    /// 正文基础字体（跟随设置页编辑器字体/字号），粗体/斜体/等宽都由此派生。
    var baseFont: NSFont = NSFont.systemFont(ofSize: 14)

    /// Cached line offset table: lineOffsets[i] = UTF16 index of line i's start.
    ///
    /// 不变量：`lineOffsets` 描述的是**长度为 `indexedLength` 的那份文本**。
    /// 调用方（`EditorCoordinator.textDidChange` 等）在文本变化后显式 rebuild，
    /// `ensureLineOffsets` 只按长度兜底——长度对不上说明表已过期，代价 O(1)。
    var lineOffsets: [Int] = [0]
    private(set) var indexedLength: Int = -1

    private var highlightTimer: Timer?
    private var visibleHighlightTimer: Timer?

    deinit {
        highlightTimer?.invalidate()
        visibleHighlightTimer?.invalidate()
    }

    /// Rebuild the line offset cache from the current text content.
    ///
    /// 逐 UTF16 单元扫 `0x0A`，分块读进栈外的固定缓冲区（4,096 单元 = 8KB），
    /// 避免逐次 `NSString.range(of:)` 的搜索上下文开销。实测（M1，`-O`）：
    /// 218KB 3.82→0.33ms、2.2MB 37.0→3.4ms、5.5MB 92.7→8.7ms，约 **10.7–11.7×**，
    /// 12 例语料（CRLF / 代理对 / 零宽 / 尾换行）与旧实现输出逐项一致。
    ///
    /// 正确性前提：`0x0A` 不会出现在任何多单元编码里（UTF-16 代理对的高位是
    /// 0xD800–0xDBFF、低位 0xDC00–0xDFFF），所以按单元比较不会切坏字符。
    func rebuildLineOffsets(for text: String) {
        let sid = PerformanceTracer.begin("RebuildLineOffsets", log: PerformanceTracer.editor)
        let ns = text as NSString
        let length = ns.length

        var offsets: [Int] = [0]
        offsets.reserveCapacity(length / 40 + 1)

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var position = 0
        buffer.withUnsafeMutableBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            while position < length {
                let count = min(chunkSize, length - position)
                ns.getCharacters(base, range: NSRange(location: position, length: count))
                for i in 0..<count where base[i] == 0x0A {
                    offsets.append(position + i + 1)
                }
                position += count
            }
        }

        lineOffsets = offsets
        indexedLength = length
        PerformanceTracer.end("RebuildLineOffsets", log: PerformanceTracer.editor, id: sid)
    }

    /// 表与文本长度不一致时重建（O(1) 判断）。
    ///
    /// 主路径不依赖这里：`textDidChange` 每次都会显式 rebuild。这里是兜底——
    /// 程序化替换文本、或外部直接改 `NSTextStorage` 而未走 textDidChange 时，
    /// 旧表不会静默留下，否则 `lineIndex(for:)` 与滚动同步会按旧行结构定位。
    func ensureLineOffsets(for text: String) {
        if (text as NSString).length != indexedLength { rebuildLineOffsets(for: text) }
    }

    func lineIndex(for characterIndex: Int, in text: String) -> Int {
        ensureLineOffsets(for: text)
        var lo = 0
        var hi = lineOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineOffsets[mid] <= characterIndex { lo = mid + 1 }
            else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Schedule syntax highlighting after `delay` seconds.
    /// Invalidates any previously pending highlight so keystrokes only
    /// trigger one pass after the user stops typing.
    func scheduleHighlight(after delay: TimeInterval = 0.0) {
        highlightTimer?.invalidate()
        highlightTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let textView = self.textView else { return }
            self.applyHighlight(to: textView)
        }
    }

    /// Re-highlight after scrolling settles so newly visible text receives
    /// syntax colors without repainting on every scroll tick.
    func scheduleVisibleRangeHighlight() {
        visibleHighlightTimer?.invalidate()
        visibleHighlightTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self, let textView = self.textView else { return }
            self.applyHighlight(to: textView)
        }
    }

    func applyHighlight(to textView: NSTextView) {
        let text = textView.string
        guard !text.isEmpty else { return }

        if text.utf8.count > NativeEditorView.syntaxHighlightThreshold {
            PerformanceTracer.event("HighlightSkipped_LargeFile", log: PerformanceTracer.editor)
            return
        }

        let sid = PerformanceTracer.begin("ApplyHighlighting", log: PerformanceTracer.editor)

        guard let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            PerformanceTracer.end("ApplyHighlighting", log: PerformanceTracer.editor, id: sid)
            return
        }

        let nsText = text as NSString
        let fullLength = nsText.length

        // Compute visible character range + buffer (2000 chars above/below).
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let bufferChars = 2000
        let rangeStart = max(0, visibleCharRange.location - bufferChars)
        let rangeEnd = min(fullLength, visibleCharRange.location + visibleCharRange.length + bufferChars)
        let highlightRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        let baseColor = theme.foregroundNSColor
        let baseFont = self.baseFont

        storage.beginEditing()
        // Reset only the highlight range
        storage.removeAttribute(.foregroundColor, range: highlightRange)
        storage.removeAttribute(.font, range: highlightRange)
        storage.removeAttribute(.backgroundColor, range: highlightRange)
        storage.removeAttribute(.paragraphStyle, range: highlightRange)
        storage.addAttribute(.foregroundColor, value: baseColor, range: highlightRange)
        storage.addAttribute(.font, value: baseFont, range: highlightRange)

        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.18
        para.paragraphSpacing = 4
        storage.addAttribute(.paragraphStyle, value: para, range: highlightRange)

        guard let engine = HighlightService.shared.engine(for: language) else {
            storage.endEditing()
            PerformanceTracer.end("ApplyHighlighting", log: PerformanceTracer.editor, id: sid)
            return
        }
        engine.highlight(text: text, into: storage, range: highlightRange, baseFont: baseFont)
        storage.endEditing()
        PerformanceTracer.end("ApplyHighlighting", log: PerformanceTracer.editor, id: sid)
    }
}
