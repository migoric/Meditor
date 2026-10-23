import AppKit

/// A vertical ruler that displays line numbers alongside an NSTextView.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let textColor = NSColor.tertiaryLabelColor

    /// 每行行首的 UTF-16 偏移缓存。击键/文本变化时失效，滚动重绘时只做二分查找——
    /// 此前每次 drawHashMarksAndLabels 都从文档头扫到可见区（大文件滚动每帧 O(n)）。
    private var lineStartOffsets: [Int] = [0]
    private var lineOffsetsValid = false

    /// Returns nil if textView is not yet embedded in a scroll view.
    /// Caller (NativeEditorView.makeNSView) creates this after the scrollView
    /// is set up, so in practice scrollView is always available.
    init?(textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView else { return nil }
        self.textView = textView
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
        lineOffsetsValid = false
        needsDisplay = true
    }
    @objc private func boundsDidChange(_ n: Notification) { needsDisplay = true }

    /// 重建行首偏移表（每次文本变化只做一次，O(n)）。
    /// 走 `LineOffsetScanner` 的分块快扫——此前这里用逐行 `NSString.range` 的旧法，
    /// 与调度器各扫一遍，同一份文本每击键付两次、这份还慢 16.7×。
    private func ensureLineOffsets(_ text: NSString) {
        guard !lineOffsetsValid else { return }
        lineStartOffsets = LineOffsetScanner.build(for: text)
        lineOffsetsValid = true
    }

    /// 二分查找包含 `charIndex` 的行下标（0-based）。
    private func lineIndex(forCharacterAt charIndex: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= charIndex {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        let text = textView.string as NSString
        ensureLineOffsets(text)
        let inset = textView.textContainerInset.height

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        // 可见区起点所在行的行号（含起点在某行中间的情况）
        var lineNumber = lineIndex(forCharacterAt: min(visibleChars.location, max(0, text.length))) + 1

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
