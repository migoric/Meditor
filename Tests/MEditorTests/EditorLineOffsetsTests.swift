import XCTest
@testable import MEditor

/// 行偏移表（`EditorHighlightScheduler.lineOffsets`）的三类约束：
///
/// 1. **正确性**——换行扫描换了实现（`NSString.range(of:)` 逐次查找 → 分块
///    `getCharacters` 后逐 UTF16 单元比较），输出必须与旧算法逐项相等，
///    含 CRLF、代理对、块边界、无尾换行、空串等边界。
/// 2. **失效语义**——表落后于文本时必须自动重建。此前的 `lineOffsetsDirty`
///    只读不写，`ensureLineOffsets` 实际是空操作，旧表会静默留在原处，
///    于是 `lineIndex(for:)` / 滚动同步会按旧文本的行结构定位。
/// 3. **增量维护**——`applyEdit` 按编辑 delta 平移/增删行首，结果必须与
///    全量重扫逐位一致（固定种子随机编辑序列差分，含代理对切割 / CRLF /
///    首尾编辑 / 多行替换）；校验失败必须拒绝并回退全量。
final class EditorLineOffsetsTests: XCTestCase {

    /// 参照实现：与改动前同一算法（逐次 `NSString.range(of:)`）。
    /// 被测实现可以换，输出不能变。
    private func referenceOffsets(_ text: String) -> [Int] {
        let ns = text as NSString
        var offsets = [0]
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(of: "\n", range: NSRange(location: searchStart, length: ns.length - searchStart))
            if found.location == NSNotFound { break }
            offsets.append(found.location + 1)
            searchStart = found.location + 1
        }
        return offsets
    }

    /// 覆盖：空串 / 无换行 / 纯换行 / 尾换行 / CRLF / 代理对 / 零宽与 BOM / 中文。
    private let corpus: [String] = [
        "",
        "no newline at all",
        "\n",
        "\n\n\n",
        "trailing\n",
        "a\nb\nc",
        "a\r\nb\r\nc",
        "emoji 😀\n第二行 🎉🎉\n",
        "零宽零宽\u{200B}前\n后\u{FEFF}",
        "🧑‍🚀\n👨‍👩‍👧‍👦\n",
        "\u{1F600}\n\u{1F600}\n",
        "abc\n\ndef\n\n",
    ]

    func test_rebuildLineOffsets_matchesReferenceOnEdgeCases() {
        for (index, text) in corpus.enumerated() {
            let scheduler = EditorHighlightScheduler()
            scheduler.rebuildLineOffsets(for: text)
            XCTAssertEqual(
                scheduler.lineOffsets,
                referenceOffsets(text),
                "语料 #\(index) 与参照实现不一致：\(text.debugDescription)"
            )
        }
    }

    func test_rebuildLineOffsets_crossesChunkBoundaries() {
        // 分块读取 UTF16 单元时，换行可能落在块首/块尾/跨块，逐一点位验证。
        for prefixLength in [4094, 4095, 4096, 4097, 8190, 8191, 8192, 8193] {
            let text = String(repeating: "a", count: prefixLength) + "\n" + "b\n"
            let scheduler = EditorHighlightScheduler()
            scheduler.rebuildLineOffsets(for: text)
            XCTAssertEqual(
                scheduler.lineOffsets,
                [0, prefixLength + 1, prefixLength + 3],
                "前缀长度 \(prefixLength) 时换行位置错"
            )
        }
    }

    func test_rebuildLineOffsets_lineCountMatchesNewlineCount() {
        // 行数不变量：换行数 + 1（文本非空时；空文本只有一行起点 0）。
        for text in corpus {
            let scheduler = EditorHighlightScheduler()
            scheduler.rebuildLineOffsets(for: text)
            let newlines = text.unicodeScalars.filter { $0 == "\n" }.count
            XCTAssertEqual(scheduler.lineOffsets.count, newlines + 1, "文本 \(text.debugDescription)")
        }
    }

    // MARK: - 失效语义

    func test_lineIndex_reflectsContentShrunkWithoutExplicitRebuild() {
        let scheduler = EditorHighlightScheduler()
        scheduler.rebuildLineOffsets(for: "ab\ncd")     // 表：两行，第 2 行始于下标 3
        // 文本被程序化替换成更短的单行内容，调用方没有显式 rebuild。
        XCTAssertEqual(
            scheduler.lineIndex(for: 4, in: "abcdef"),
            0,
            "旧表（两行）被当成了新文本的行索引——下标 4 在单行文本里属于第 1 行"
        )
    }

    func test_lineIndex_reflectsContentGrownWithoutExplicitRebuild() {
        let scheduler = EditorHighlightScheduler()
        scheduler.rebuildLineOffsets(for: "abc")        // 表：只有一行
        XCTAssertEqual(
            scheduler.lineIndex(for: 3, in: "ab\ncd"),
            1,
            "文本新增换行后下标 3 属于第 2 行，旧表只有一行"
        )
    }

    func test_lineIndex_staysCorrectAcrossRepeatedEdits() {
        // 模拟连续击键：每次 textDidChange 都会显式 rebuild，穿插不 rebuild 的查询。
        let scheduler = EditorHighlightScheduler()
        var text = ""
        for line in 0..<40 {
            text += "第 \(line) 行\n"
            scheduler.rebuildLineOffsets(for: text)
            let probe = text.unicodeScalars.count - 2   // 落在最后一行内部
            XCTAssertEqual(scheduler.lineIndex(for: probe, in: text), line, "第 \(line) 行定位错")
        }
    }

    // MARK: - 性能语义（缓存必须真的命中）

    /// 文本没变时，`lineIndex` 不能触发重建。
    ///
    /// 这是「O(1) 兜底校验」这个**性能主张本身**：删掉 `indexedLength = length`
    /// 之后每次调用都会重建（`computeVisibleTopLine` 每个滚动 tick 都要调它，
    /// 等于退回 O(n) 全文扫描），但文本正确性用例全绿 —— 光看偏移值抓不到。
    func test_lineIndex_doesNotRebuildWhenTextUnchanged() {
        let scheduler = EditorHighlightScheduler()
        let text = "第一行\n第二行\n第三行"
        scheduler.rebuildLineOffsets(for: text)
        let baseline = scheduler.rebuildCount

        for _ in 0..<50 { _ = scheduler.lineIndex(for: 8, in: text) }

        XCTAssertEqual(baseline, 1, "显式 rebuild 一次后计数应为 1")
        XCTAssertEqual(
            scheduler.rebuildCount, baseline,
            "文本没变却重建了 \(scheduler.rebuildCount - baseline) 次 —— 兜底校验形同虚设"
        )
    }

    /// 长度变化必须重建（否则上一轮改成「永不重建」也能过）。
    func test_lineIndex_rebuildsWhenLengthChanges() {
        let scheduler = EditorHighlightScheduler()
        scheduler.rebuildLineOffsets(for: "abc")
        _ = scheduler.lineIndex(for: 0, in: "abcdef")
        XCTAssertEqual(scheduler.rebuildCount, 2, "长度变了却未重建")
    }

    // MARK: - 增量维护（applyEdit）：确定性边界用例

    /// 参照实现的 NSString 版：直接逐单元找 0x0A。差分测试里编辑可能切开
    /// 代理对产生非法 UTF-16，NSString 能容纳而 String 会被桥接修复，
    /// 所以随机序列全程在 NSString 层面操作与验证。
    private func referenceOffsetsNSString(_ text: NSString) -> [Int] {
        var offsets = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A {
            offsets.append(i + 1)
        }
        return offsets
    }

    private func assertApplyEdit(
        _ scheduler: EditorHighlightScheduler,
        original: String, editedRange: NSRange, replacement: String,
        expected: [Int], file: StaticString = #filePath, line: UInt = #line
    ) {
        let newText = NSMutableString(string: original)
        newText.replaceCharacters(in: editedRange, with: replacement)
        scheduler.rebuildLineOffsets(for: original)
        XCTAssertTrue(
            scheduler.applyEdit(editedRange: editedRange, replacement: replacement,
                                newLength: newText.length),
            "合法 delta 被拒绝", file: file, line: line
        )
        XCTAssertEqual(scheduler.lineOffsets, expected, file: file, line: line)
        XCTAssertEqual(scheduler.lineOffsets, referenceOffsetsNSString(newText),
                       "与全量重扫不一致", file: file, line: line)
        XCTAssertEqual(scheduler.indexedLength, newText.length, file: file, line: line)
    }

    func test_applyEdit_insertNewlineAtStartMiddleEnd() {
        let scheduler = EditorHighlightScheduler()
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 0, length: 0), replacement: "\n",
                        expected: [0, 1, 5])
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 2, length: 0), replacement: "\n",
                        expected: [0, 3, 5])
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 7, length: 0), replacement: "\n",
                        expected: [0, 4, 8])
        // 纯插入不换行：尾部行首平移，行数不变
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 1, length: 0), replacement: "XY",
                        expected: [0, 6])
        // 文末插普通字符：无任何行首变化
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 7, length: 0), replacement: "Z",
                        expected: [0, 4])
    }

    func test_applyEdit_deleteNewlineJoinsLines() {
        let scheduler = EditorHighlightScheduler()
        // 删掉唯一的换行：两行并一行
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 3, length: 1), replacement: "",
                        expected: [0])
        // 删除跨行区间 "c\nd"：合并首尾两段
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 2, length: 3), replacement: "",
                        expected: [0])
        // 删到文本末尾
        assertApplyEdit(scheduler, original: "abc\ndef",
                        editedRange: NSRange(location: 3, length: 4), replacement: "",
                        expected: [0])
    }

    func test_applyEdit_replaceAcrossMultipleLines() {
        let scheduler = EditorHighlightScheduler()
        // 单行片段换成三行
        assertApplyEdit(scheduler, original: "abcdef",
                        editedRange: NSRange(location: 1, length: 4), replacement: "x\ny\nz",
                        expected: [0, 3, 5])
        // 跨两行替换为含换行文本："a" + "l1\nl2" + "f"
        assertApplyEdit(scheduler, original: "ab\ncdef",
                        editedRange: NSRange(location: 1, length: 6), replacement: "l1\nl2",
                        expected: [0, 4])
    }

    func test_applyEdit_crlfAndSurrogateBoundary() {
        let scheduler = EditorHighlightScheduler()
        // CRLF → 两个 LF：\r 不是行首依据，替换后多出一条行首
        assertApplyEdit(scheduler, original: "a\r\nb",
                        editedRange: NSRange(location: 1, length: 2), replacement: "\n\n",
                        expected: [0, 2, 3])
        // 在代理对中间插入（合法 delta：边界切开代理对不影响 0x0A 算术）
        let scheduler2 = EditorHighlightScheduler()
        let original = "😀\nx" as NSString   // lead trail \n x → [0, 3]
        let newText = NSMutableString(string: original)
        newText.replaceCharacters(in: NSRange(location: 1, length: 0), with: "y")
        scheduler2.rebuildLineOffsets(for: original as String)
        XCTAssertTrue(scheduler2.applyEdit(editedRange: NSRange(location: 1, length: 0),
                                           replacement: "y", newLength: newText.length))
        XCTAssertEqual(scheduler2.lineOffsets, [0, 4])
        XCTAssertEqual(scheduler2.lineOffsets, referenceOffsetsNSString(newText))
    }

    func test_applyEdit_rejectsInvalidDelta() {
        // 表未建（indexedLength = -1）
        XCTAssertFalse(EditorHighlightScheduler().applyEdit(
            editedRange: NSRange(location: 0, length: 0), replacement: "x", newLength: 1))

        let scheduler = EditorHighlightScheduler()
        scheduler.rebuildLineOffsets(for: "abc")   // len 3
        let baseline = (scheduler.lineOffsets, scheduler.rebuildCount, scheduler.incrementalApplyCount)

        // NSNotFound / 越界 / 长度不符一律拒绝，且不改任何状态
        XCTAssertFalse(scheduler.applyEdit(editedRange: NSRange(location: NSNotFound, length: 0),
                                           replacement: "x", newLength: 4))
        XCTAssertFalse(scheduler.applyEdit(editedRange: NSRange(location: 2, length: 5),
                                           replacement: "x", newLength: 0))
        XCTAssertFalse(scheduler.applyEdit(editedRange: NSRange(location: -1, length: 0),
                                           replacement: "x", newLength: 4))
        XCTAssertFalse(scheduler.applyEdit(editedRange: NSRange(location: 0, length: 0),
                                           replacement: "x", newLength: 99))
        XCTAssertEqual(scheduler.lineOffsets, baseline.0)
        XCTAssertEqual(scheduler.rebuildCount, baseline.1)
        XCTAssertEqual(scheduler.incrementalApplyCount, baseline.2)
    }

    /// 计数语义：applyEdit 不算全量 rebuild；applyEdit 后 indexedLength 已同步，
    /// 随后的 lineIndex 查询不得触发兜底重建。
    func test_applyEdit_countsAndKeepsEnsureCheap() {
        let scheduler = EditorHighlightScheduler()
        let text = "第一行\n第二行\n第三行"
        scheduler.rebuildLineOffsets(for: text)
        XCTAssertEqual(scheduler.rebuildCount, 1)

        let newText = NSMutableString(string: text)
        newText.replaceCharacters(in: NSRange(location: 0, length: 0), with: "第零行\n")
        XCTAssertTrue(scheduler.applyEdit(editedRange: NSRange(location: 0, length: 0),
                                          replacement: "第零行\n", newLength: newText.length))
        XCTAssertEqual(scheduler.incrementalApplyCount, 1)
        XCTAssertEqual(scheduler.rebuildCount, 1, "增量维护不得计入全量重建")

        for _ in 0..<50 { _ = scheduler.lineIndex(for: 5, in: newText as String) }
        XCTAssertEqual(scheduler.rebuildCount, 1, "applyEdit 后长度已同步，查询不该重建")
    }

    // MARK: - 增量维护（applyEdit）：固定种子随机编辑差分

    /// 确定性 RNG：随机编辑序列必须可复现，失败时能原样重放。
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// 每轮随机删一段 + 插一段（片段池含换行 / CRLF / 代理对 emoji / 组合序列 /
    /// 零宽 / CJK），编辑边界**刻意允许切开代理对**（非法 UTF-16 全程只在
    /// NSString 层面存在）。每轮后 applyEdit 结果与全量重扫逐位一致。
    func test_applyEdit_matchesFullScan_randomEditSequences() {
        let pieces = ["a", "b ", "\n", "\r\n", "😀", "🧑‍🚀", "第二行", "\u{200B}",
                      "# 标题\n\n", "- 列表项\n", "```\n", "**粗**", "长行长行长行长行长行"]
        var totalSurrogateSplits = 0
        var totalNewlineEdits = 0
        for seed: UInt64 in [1, 2, 3] {
            var rng = SplitMix64(seed: seed &* 0x9E3779B97F4A7C15)
            let text = NSMutableString()
            for _ in 0..<60 { text.append(pieces[Int.random(in: 0..<pieces.count, using: &rng)]) }
            let scheduler = EditorHighlightScheduler()
            scheduler.rebuildLineOffsets(for: text as String)

            for round in 0..<400 {
                let len = text.length
                let location = Int.random(in: 0...len, using: &rng)
                let delLen = Int.random(in: 0...min(len - location, 24), using: &rng)
                var replacement = ""
                for _ in 0...Int.random(in: 0...5, using: &rng) {
                    replacement += pieces[Int.random(in: 0..<pieces.count, using: &rng)]
                }

                // 覆盖率统计：边界是否切开代理对、编辑是否触及换行
                func splitsPair(_ pos: Int) -> Bool {
                    guard pos > 0, pos < text.length else { return false }
                    return UTF16.isLeadSurrogate(text.character(at: pos - 1))
                        && UTF16.isTrailSurrogate(text.character(at: pos))
                }
                if splitsPair(location) || splitsPair(location + delLen) {
                    totalSurrogateSplits += 1
                }
                var touchesNewline = replacement.contains("\n")
                if !touchesNewline, delLen > 0 {
                    for i in location..<(location + delLen) where text.character(at: i) == 0x0A {
                        touchesNewline = true
                        break
                    }
                }
                if touchesNewline { totalNewlineEdits += 1 }

                let editedRange = NSRange(location: location, length: delLen)
                text.replaceCharacters(in: editedRange, with: replacement)
                XCTAssertTrue(
                    scheduler.applyEdit(editedRange: editedRange, replacement: replacement,
                                        newLength: text.length),
                    "seed \(seed) 第 \(round) 轮：合法 delta 被拒绝"
                )
                XCTAssertEqual(
                    scheduler.lineOffsets, referenceOffsetsNSString(text),
                    "seed \(seed) 第 \(round) 轮：增量与全量重扫不一致"
                )
                XCTAssertEqual(scheduler.indexedLength, text.length)
            }
            XCTAssertEqual(scheduler.rebuildCount, 1, "差分序列应全程走增量")
            XCTAssertEqual(scheduler.incrementalApplyCount, 400)
        }
        // 序列必须真的覆盖到代理对切割与换行编辑，否则覆盖声明是空的
        XCTAssertGreaterThan(totalSurrogateSplits, 0, "随机序列没切到代理对")
        XCTAssertGreaterThan(totalNewlineEdits, 0, "随机序列没碰到换行")
    }
}
