import AppKit

/// Tracks scroll position and computes visible top line for editor→preview sync.
final class EditorScrollSyncHandler {
    var lastReportedLine: Int = -1
    var isProgrammaticScroll = false
    private weak var highlighter: EditorHighlightScheduler?

    init(highlighter: EditorHighlightScheduler) {
        self.highlighter = highlighter
    }

    /// Compute the 0-based line index of the first visible character at
    /// the top of the editor's viewport. Uses cached line offsets for O(log n).
    func computeVisibleTopLine(textView: NSTextView) -> Int {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 0 }

        // 只判长度就够（表由 textDidChange 显式维护），不必为读长度拷全串
        highlighter?.ensureLineOffsets(length: textView.textStorage?.length ?? 0)
        let lineOffsets = highlighter?.lineOffsets ?? [0]

        let visibleRect = scrollView.contentView.bounds
        let pointInTextContainer = NSPoint(
            x: 0,
            y: visibleRect.origin.y - textView.textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: pointInTextContainer, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        // Binary search on cached line offsets: O(log n) instead of O(n).
        var lo = 0, hi = lineOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineOffsets[mid] <= charIndex { lo = mid + 1 }
            else { hi = mid }
        }
        return max(0, lo - 1)
    }
}
