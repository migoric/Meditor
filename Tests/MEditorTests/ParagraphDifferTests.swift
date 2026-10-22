import XCTest
@testable import MEditor

/// `ParagraphDiffer` 的行为与 LCS 代价。
///
/// 重点不是「结果看着对」，而是**优化前后逐条一致**：`lcsEdits` 现在先剥公共
/// 前后缀、再用一维 `Int32` 缓冲跑 DP，这两步都可能悄悄改变多解时的对齐
/// （LCS 不唯一，回溯顺序决定哪个段落被标成「改过」）。所以这里把改前的整表
/// 实现原样搬一份当**参照实现**，用随机语料逐条比 `Edit` 序列。
final class ParagraphDifferTests: XCTestCase {

    // MARK: 行为

    func testNoChangeYieldsNoDiffs() {
        let text = "第一段\n\n第二段\n\n第三段"
        XCTAssertTrue(ParagraphDiffer.diff(original: text, modified: text).isEmpty)
    }

    func testSubstitutionPairsDeletionWithInsertion() {
        let diffs = ParagraphDiffer.diff(original: "A\n\nB\n\nC", modified: "A\n\nB2\n\nC")
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].original, "B")
        XCTAssertEqual(diffs[0].modified, "B2")
        XCTAssertEqual(diffs[0].originalIndex, 1)
        XCTAssertEqual(diffs[0].modifiedIndex, 1)
    }

    func testPureInsertionHasNoOriginalIndex() {
        let diffs = ParagraphDiffer.diff(original: "A\n\nC", modified: "A\n\nB\n\nC")
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].originalIndex, -1)
        XCTAssertEqual(diffs[0].modified, "B")
    }

    func testPureDeletionHasNoModifiedIndex() {
        let diffs = ParagraphDiffer.diff(original: "A\n\nB\n\nC", modified: "A\n\nC")
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].modifiedIndex, -1)
        XCTAssertEqual(diffs[0].original, "B")
    }

    func testWhitespaceOnlyDifferenceIsIgnored() {
        XCTAssertTrue(ParagraphDiffer.diff(original: "A\n\nB", modified: "\n\nA  \n\n\nB\n\n").isEmpty)
    }

    func testBothEmptyYieldsNoDiffs() {
        XCTAssertTrue(ParagraphDiffer.diff(original: "", modified: "").isEmpty)
    }

    // MARK: 与改前实现逐条对齐（差分测试）

    /// 重复段落多、公共前后缀几乎剥不掉：覆盖「不剥」的一侧，
    /// 也是唯一能把多解对齐差异暴露出来的语料（段落唯一时对齐被钉死）。
    func testLCSMatchesLegacyOnDuplicateHeavyInput() {
        var rng = SplitMix64(seed: 0x5EED_1234)
        // 取值域故意做得很小（4 种）、长度 ≤ 8，让重复元素大量出现
        let alphabet = ["A", "B", "C", "D"]

        for _ in 0..<400 {
            let orig = (0..<Int(rng.next() % 9)).map { _ in alphabet[Int(rng.next() % 4)] }
            let modf = (0..<Int(rng.next() % 9)).map { _ in alphabet[Int(rng.next() % 4)] }

            XCTAssertEqual(
                ParagraphDiffer.lcsEdits(orig, modf),
                legacyLCS(orig, modf),
                "编辑序列与改前实现不一致：orig=\(orig) modf=\(modf)"
            )
        }
    }

    /// 段落全唯一、只改几处：这是真实「AI 改文」的形状，主路径就是剥前后缀。
    /// 同时断言剥除真的发生了——否则这条测试会退化成「什么都没测」。
    func testLCSMatchesLegacyOnUniqueHeavyInput() throws {
        #if DEBUG
        var rng = SplitMix64(seed: 0xBEEF_0042)
        var bestCells = Int.max
        var bestFull = 0

        for _ in 0..<300 {
            let orig = (0..<30).map { "第 \($0) 段的正文内容" }
            let tailKeep = Int(rng.next() % 4)            // 尾部留几段不动
            let headKeep = Int(rng.next() % 4)            // 头部留几段不动
            var modf = orig
            let mutStart = headKeep
            let mutEnd = max(mutStart + 1, orig.count - tailKeep)
            modf.removeSubrange(mutStart..<mutEnd)
            modf.insert("插入的一段 \(rng.next() % 7)", at: mutStart)

            ParagraphDiffer.dpCellCount = 0
            let edits = ParagraphDiffer.lcsEdits(orig, modf)
            let cells = ParagraphDiffer.dpCellCount
            if cells < bestCells { bestCells = cells; bestFull = orig.count * modf.count }

            XCTAssertEqual(edits, legacyLCS(orig, modf), "orig=\(orig)\nmodf=\(modf)")
        }

        XCTAssertGreaterThan(bestFull, 0)
        XCTAssertLessThan(
            bestCells, bestFull / 4,
            "唯一段落 + 只改中段的情况下仍然填了 \(bestCells)/\(bestFull) 个格 ⇒ 前后缀没被剥掉"
        )
        #else
        throw XCTSkip("DP 计数只在 DEBUG 编译")
        #endif
    }

    func testLCSMatchesLegacyOnTailHeavyEdits() {
        // 前后缀剥完之后只剩很小中段的形状：最容易在边界上算错索引
        let base = (0..<40).map { "P\($0)" }
        var rng = SplitMix64(seed: 0xC0FFEE)

        for _ in 0..<120 {
            var orig = base
            var modf = base

            // 随机删掉一段、插入一段、改一段
            let cutStart = Int(rng.next() % 35)
            let cutLen = Int(rng.next() % 5)
            modf.removeSubrange(cutStart..<min(cutStart + cutLen, modf.count))
            let insAt = Int(rng.next() % UInt64(modf.count))
            modf.insert(contentsOf: ["X\(rng.next() % 3)", "Y"], at: insAt)
            orig.swapAt(3, 4)

            XCTAssertEqual(
                ParagraphDiffer.lcsEdits(orig, modf),
                legacyLCS(orig, modf),
                "orig=\(orig)\nmodf=\(modf)"
            )
        }
    }

    // MARK: 代价（用计数，不用耗时）

    func testSingleParagraphEditDoesNotFillFullTable() throws {
        let paragraphs = (0..<1_200).map { "段落 \($0) 的正文" }
        var edited = paragraphs
        edited[600] = "改过的一段"

        #if DEBUG
        ParagraphDiffer.dpCellCount = 0
        let diffs = ParagraphDiffer.diff(
            original: paragraphs.joined(separator: "\n\n"),
            modified: edited.joined(separator: "\n\n")
        )
        XCTAssertEqual(diffs.count, 1, "只改了一段，应当只有一条待审阅差异")

        // 整表是 1,200 × 1,200 ≈ 1.44M 格；剥掉前后缀后中段只剩 1×1。
        // 留 100 格余量给「改一段」两侧的错位（删 1 增 1 之类的邻接情形）。
        XCTAssertLessThan(
            ParagraphDiffer.dpCellCount, 100,
            "改一段仍填了大量 DP 格 ⇒ 公共前后缀没被剥掉（实际 \(ParagraphDiffer.dpCellCount) 格）"
        )
        #else
        throw XCTSkip("DP 计数只在 DEBUG 编译")
        #endif
    }

    func testScatteredEditsStayWithinACeiling() throws {
        // 每 100 段改一段 ⇒ 前后缀都只剥掉几十段，中段仍是整篇：这条路径剥不掉，
        // 只能靠「扁平 Int32 表 + 哈希预筛」撑住。断言的是**天花板**（-O 实测 ~21ms，
        // 这里留两个数量级余量），定位是「退回嵌套 [[Int]] 或删掉哈希预筛会撞上的
        // 挂死探测器」，不是性能主张——CI 机器慢也不会误报。
        var edited: [String] = []
        let paragraphs = (0..<2_000).map { "段落 \($0)" }
        for (i, p) in paragraphs.enumerated() {
            edited.append(i % 100 == 0 ? p + "（改）" : p)
        }
        let origText = paragraphs.joined(separator: "\n\n")
        let modfText = edited.joined(separator: "\n\n")

        let start = Date()
        let diffs = ParagraphDiffer.diff(original: origText, modified: modfText)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(diffs.count, 20, "20 段被改，应产出 20 条差异")
        XCTAssertLessThan(elapsed, 10.0, "2,000 × 2,000 的 DP 超过 10 秒 ⇒ 缓冲布局或哈希预筛退化了")
    }

    // MARK: 参照实现（改前的整表回溯，原样搬运）

    private func legacyLCS(
        _ a: [String],
        _ b: [String]
    ) -> [ParagraphDiffer.Edit] {
        let m = a.count, n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0, n > 0 {
            for i in stride(from: 1, through: m, by: 1) {
                for j in stride(from: 1, through: n, by: 1) {
                    dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1
                                                  : max(dp[i-1][j], dp[i][j-1])
                }
            }
        }
        var edits: [ParagraphDiffer.Edit] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i-1] == b[j-1] {
                edits.append(.init(kind: .unchanged, origIndex: i-1, modfIndex: j-1))
                i -= 1; j -= 1
            } else if j > 0, i == 0 || dp[i][j-1] >= dp[i-1][j] {
                edits.append(.init(kind: .inserted, origIndex: -1, modfIndex: j-1))
                j -= 1
            } else {
                edits.append(.init(kind: .deleted, origIndex: i-1, modfIndex: -1))
                i -= 1
            }
        }
        return edits.reversed()
    }
}

/// 确定性随机源（不用 `Int.random`：失败时要能原样重跑）。
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
