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
    /// 不变量：`lineOffsets` 描述的是**最后一次 rebuild / applyEdit 时那份文本**，
    /// 长度记在 `indexedLength`。主路径：`textDidChange` 拿到 `shouldChangeTextIn`
    /// 记录的编辑 delta 走 `applyEdit` 增量维护，对不上（程序化改存储、undo 绕过
    /// delegate 等）则全量 rebuild；`ensureLineOffsets` 只按长度兜底，代价 O(1)。
    /// ⚠️ 只比长度意味着**等长改写不会触发兜底**（例如 `"ab\ncd"` → `"abcde"`），
    /// 此时表是过期的。当前调用点都在改动后显式 apply/rebuild，所以不可达；
    /// 要更强的一致性得比对内容哈希，代价是每次 `lineIndex` 都 O(n)，不可接受。
    var lineOffsets: [Int] = [0]
    private(set) var indexedLength: Int = -1

    /// 全量 rebuild 次数。只为让测试能断言「文本没变时不该重建」——
    /// 这是性能主张本身，光看偏移值正确性是抓不到的。
    private(set) var rebuildCount: Int = 0

    /// 增量 apply 成功的次数。与 `rebuildCount` 配合钉住「击键走增量、
    /// 对不上才全量」的性能语义。
    private(set) var incrementalApplyCount: Int = 0

    private var highlightTimer: Timer?
    private var visibleHighlightTimer: Timer?

    deinit {
        highlightTimer?.invalidate()
        visibleHighlightTimer?.invalidate()
    }

    /// Rebuild the line offset cache from the current text content.
    /// 扫描实现在 `LineOffsetScanner`（行号尺共用一份，消除「同一份文本每击键
    /// 扫两遍、第二遍还是旧慢法」）；实测数据见扫描器的注释。
    func rebuildLineOffsets(for text: String) {
        let sid = PerformanceTracer.begin("RebuildLineOffsets", log: PerformanceTracer.editor)
        lineOffsets = LineOffsetScanner.build(for: text as NSString)
        indexedLength = (text as NSString).length
        rebuildCount += 1
        PerformanceTracer.end("RebuildLineOffsets", log: PerformanceTracer.editor, id: sid)
    }

    /// 长度兜底版：调用方只有长度时不必为判断而拷全串（滚动回调每帧都走这里）。
    /// 需要重建时仍从 textView 取原文。
    func ensureLineOffsets(length: Int) {
        if length != indexedLength, let textView {
            rebuildLineOffsets(for: textView.string)
        }
    }

    /// 增量应用一次编辑（NSTextView `shouldChangeTextIn` 语义，编辑**已生效**后调用）：
    /// `editedRange` 是编辑前文本中的被替换区间（UTF-16 单元），`replacement` 是替换
    /// 字符串，`newLength` 是编辑后文本的 UTF-16 长度（用于一致性校验）。
    ///
    /// 规则：行首 ≤ 编辑起点的不动；行首落在 (a, b]（a=location, b=NSMaxRange）的
    /// 随被删换行一起消失；replacement 里每个 0x0A 生成一个新行首 a+k+1；行首 > b 的
    /// 整体平移 delta。0x0A 不出现在任何代理对里，所以编辑切开代理对也不影响结果——
    /// 表项是纯 UTF-16 下标算术，与全量重扫逐位一致。
    ///
    /// 校验失败（表未建 / 区间越界 / 长度对不上，说明 delta 与实际编辑不符）返回 false，
    /// 调用方必须回退 `rebuildLineOffsets`。代价 O(编辑点之后的行数 + replacement 长度)，
    /// 典型击键是 O(1) 分摊，最坏（文首编辑）是一次尾部平移 memmove。
    @discardableResult
    func applyEdit(editedRange: NSRange, replacement: String, newLength: Int) -> Bool {
        guard indexedLength >= 0,
              editedRange.location != NSNotFound,
              editedRange.location >= 0,
              editedRange.length >= 0,
              NSMaxRange(editedRange) <= indexedLength else { return false }
        let replNS = replacement as NSString
        let replLen = replNS.length
        let delta = replLen - editedRange.length
        guard indexedLength + delta == newLength else { return false }

        let a = editedRange.location
        let b = NSMaxRange(editedRange)

        // lo = 首个 > a 的行首下标（[0, lo) 保留）；hi = 首个 > b 的行首下标（[hi, end) 平移）
        func firstIndexGreater(than value: Int) -> Int {
            var low = 0, high = lineOffsets.count
            while low < high {
                let mid = (low + high) / 2
                if lineOffsets[mid] > value { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let lo = firstIndexGreater(than: a)
        let hi = firstIndexGreater(than: b)

        // replacement 内的新行首（与 rebuildLineOffsets 同款分块扫 0x0A）
        var middle: [Int] = []
        if replLen > 0 {
            middle.reserveCapacity(replLen / 40 + 1)
            let chunkSize = 4096
            var buffer = [unichar](repeating: 0, count: chunkSize)
            var position = 0
            buffer.withUnsafeMutableBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                while position < replLen {
                    let count = min(chunkSize, replLen - position)
                    replNS.getCharacters(base, range: NSRange(location: position, length: count))
                    for i in 0..<count where base[i] == 0x0A {
                        middle.append(a + position + i + 1)
                    }
                    position += count
                }
            }
        }

        lineOffsets.replaceSubrange(lo..<hi, with: middle)
        if delta != 0 {
            for i in (lo + middle.count)..<lineOffsets.count {
                lineOffsets[i] += delta
            }
        }
        indexedLength = newLength
        incrementalApplyCount += 1
        return true
    }

    /// 表与文本长度不一致时重建（O(1) 判断）。
    ///
    /// 主路径不依赖这里：`textDidChange` 每次都会显式 rebuild。这里是兜底——程序化
    /// 替换文本、或外部直接改 `NSTextStorage` 而未走 textDidChange 时，避免按旧行
    /// 结构定位。
    /// ⚠️ **只防长度变化**：等长改写不会重建（见 `lineOffsets` 的说明）。
    func ensureLineOffsets(for text: String) {
        if (text as NSString).length != indexedLength { rebuildLineOffsets(for: text) }
    }

    func lineIndex(for characterIndex: Int, in text: String) -> Int {
        ensureLineOffsets(for: text)
        return lineIndexInCachedOffsets(for: characterIndex)
    }

    /// 不取文本的版本：表由 textDidChange 显式维护，这里只做 O(1) 长度兜底——
    /// 光标移动每次都会走，为判长度而拷全串不划算。
    func lineIndex(forCharacterAt characterIndex: Int, textLength: Int) -> Int {
        ensureLineOffsets(length: textLength)
        return lineIndexInCachedOffsets(for: characterIndex)
    }

    private func lineIndexInCachedOffsets(for characterIndex: Int) -> Int {
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
