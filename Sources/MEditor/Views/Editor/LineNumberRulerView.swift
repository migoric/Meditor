import AppKit

/// A vertical ruler that displays line numbers alongside an NSTextView.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// 行首偏移表共享自调度器（`EditorHighlightScheduler`）：击键时调度器按编辑
    /// delta 增量维护，这里重绘只做二分查找。此前本类另维护一份表，每击键后用
    /// 逐次 `range(of:)` 旧法 O(n) 重扫一遍（比调度器的分块快扫慢 ~17×）。
    private weak var highlighter: EditorHighlightScheduler?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let textColor = NSColor.tertiaryLabelColor

    /// Returns nil if textView is not yet embedded in a scroll view.
    /// Caller (NativeEditorView.makeNSView) creates this after the scrollView
    /// is set up, so in practice scrollView is always available.
    init?(textView: NSTextView, highlighter: EditorHighlightScheduler) {
        guard let scrollView = textView.enclosingScrollView else { return nil }
        self.textView = textView
        self.highlighter = highlighter
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.ruleThickness = 36
        self.clientView = textView

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func textDidChange(_ n: Notification) {
        needsDisplay = true
    }
    @objc private func boundsDidChange(_ n: Notification) { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        let text = textView.textStorage?.mutableString ?? ""
        let inset = textView.textContainerInset.height

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        // 可见区起点所在行的行号（含起点在某行中间的情况）；
        // 行偏移表由调度器维护（增量/全量 + 长度兜底），这里只二分
        var lineNumber = (highlighter?.lineIndex(
            forCharacterAt: min(visibleChars.location, max(0, text.length)),
            textLength: textView.textStorage?.length ?? 0
        ) ?? 0) + 1

        // Draw line numbers for visible lines
        var glyphIdx = visibleGlyphs.location
        while glyphIdx < NSMaxRange(visibleGlyphs) {
            let charRange = layoutManager.characterRange(forGlyphRange: NSRange(location: glyphIdx, length: 1), actualGlyphRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            lineRect.origin.y += inset - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: ruleThickness - strSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - strSize.height) / 2
            )
            numStr.draw(at: drawPoint, withAttributes: attrs)

            // Advance to next line
            let lineEnd = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            _ = lineEnd
            var nextGlyphIdx = NSMaxRange(layoutManager.glyphRange(forCharacterRange: NSRange(location: charRange.location, length: max(1, charRange.length)), actualCharacterRange: nil))
            // Find start of next visual line
            let rangeEnd = NSMaxRange(charRange)
            if rangeEnd < text.length {
                let nextLineRange = (text as NSString).lineRange(for: NSRange(location: rangeEnd, length: 0))
                nextGlyphIdx = layoutManager.glyphRange(forCharacterRange: nextLineRange, actualCharacterRange: nil).location
            } else {
                nextGlyphIdx = NSMaxRange(visibleGlyphs)
            }

            lineNumber += 1
            if nextGlyphIdx <= glyphIdx { break }
            glyphIdx = nextGlyphIdx
        }
    }
}
