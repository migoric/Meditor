import XCTest
@testable import MEditor

/// 行偏移表（`EditorHighlightScheduler.lineOffsets`）的两类约束：
///
/// 1. **正确性**——换行扫描换了实现（`NSString.range(of:)` 逐次查找 → 分块
///    `getCharacters` 后逐 UTF16 单元比较），输出必须与旧算法逐项相等，
///    含 CRLF、代理对、块边界、无尾换行、空串等边界。
/// 2. **失效语义**——表落后于文本时必须自动重建。此前的 `lineOffsetsDirty`
///    只读不写，`ensureLineOffsets` 实际是空操作，旧表会静默留在原处，
///    于是 `lineIndex(for:)` / 滚动同步会按旧文本的行结构定位。
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
}
