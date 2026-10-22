import Foundation

// MARK: - ParagraphDiffer

enum ParagraphDiffer {

    // MARK: Public API

    /// Splits `content` into paragraph blocks (separated by blank lines).
    static func splitParagraphs(_ content: String) -> [String] {
        content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns only the changed paragraphs between `original` and `modified`.
    /// Uses index-aligned comparison for paragraphs at the same position,
    /// then LCS for remainder, merging adjacent delete+add pairs into substitutions.
    static func diff(original: String, modified: String) -> [ParagraphDiff] {
        let origBlocks = splitParagraphs(original)
        let modfBlocks = splitParagraphs(modified)

        guard !origBlocks.isEmpty || !modfBlocks.isEmpty else { return [] }

        let edits = lcsEdits(origBlocks, modfBlocks)
        return buildDiffs(edits: edits, orig: origBlocks, modf: modfBlocks)
    }

    // MARK: LCS

    /// 内可见（非 `private`）只为让测试直接对比编辑序列——见
    /// `ParagraphDifferTests` 里「剥前后缀后与整表回溯逐条一致」的差分验证。
    struct Edit: Equatable {
        enum Kind: Equatable { case unchanged, deleted, inserted }
        let kind: Kind
        let origIndex: Int   // -1 if inserted
        let modfIndex: Int   // -1 if deleted
    }

    /// 调试计数：实际填了多少个 DP 格。测试读增量前先置 0。
    ///
    /// 「剥前后缀省掉了工作量」这个主张无法用产物正确性证明（省了也输出一样），
    /// 所以用计数守，而不是耗时。仅 DEBUG 累加，release 里不参与编译。
    #if DEBUG
    nonisolated(unsafe) static var dpCellCount = 0
    #endif

    /// 编辑序列。
    ///
    /// 先用**公共前后缀**收缩再跑 LCS。AI 改文、本地历史对比这类场景里绝大多数
    /// 段落没动，先剥掉它们能把 DP 从 `m × n` 降到近常数（改一段 ⇒ 中段只剩一两段）。
    ///
    /// 两种收缩的**等价性论证不同**，别混为一谈：
    ///
    /// * **后缀**无条件剥。改前的回溯从 `(m, n)` 出发、`a[i-1] == b[j-1]` 时必走
    ///   对角线，所以尾部连续全等的部分在任何输入上都必然被逐对匹配——先剥掉它，
    ///   剩下的子矩阵 DP 值与整表完全一致（`dp[i][j]` 只依赖 `a[0..<i)`、`b[0..<j)`），
    ///   回溯路径逐条相同。
    /// * **前缀**只有在该段落**两边都唯一**时才剥。若 `a[0] == b[0]` 但同一段落
    ///   在后面还出现过，LCS 多解：改前的回溯可能把 `a[0]` 让给别人、改成匹配后面
    ///   那个重复段落。实测（`ParagraphDifferTests` 的差分测试）`["A","A","B"]` 这类
    ///   输入会因此改变「哪一段算改过」。唯一时不成立——该对一定属于**每一个**
    ///   最优解（否则加上它就能更长），对齐被钉死，剥掉安全。
    ///
    /// 中段内仍是同一套回溯规则（`dp[i][j-1] >= dp[i-1][j]` 优先插入），
    /// 多解时的取舍与改前一致——由差分测试逐条对比 `Edit` 钉死。
    static func lcsEdits(_ a: [String], _ b: [String]) -> [Edit] {
        let m = a.count, n = b.count

        // 后缀：无条件
        var tail = 0
        while tail < m, tail < n, a[m - 1 - tail] == b[n - 1 - tail] { tail += 1 }

        let headLimit = min(m - tail, n - tail)
        var head = 0
        if headLimit > 0, a[0] == b[0] {
            // 计数表必须覆盖**整篇**（不是只数头部）：唯一性要按「剩下还没比的范围」
            // 判，头部之后再出现一次就说明不唯一，那时剥掉就会改变对齐。
            // 代价是一次 O(总字节) 的哈希（534KB ≈ 0.5ms），且只在首段相等时才付。
            let countA = occurrenceCounts(a)
            let countB = occurrenceCounts(b)
            while head < headLimit,
                  a[head] == b[head],
                  countA[a[head]] == 1, countB[a[head]] == 1 {
                head += 1
            }
        }

        var edits: [Edit] = []
        edits.reserveCapacity(max(m, n))
        for k in 0..<head {
            edits.append(Edit(kind: .unchanged, origIndex: k, modfIndex: k))
        }
        edits.append(contentsOf: lcsCore(
            a[head..<(m - tail)],
            b[head..<(n - tail)],
            origOffset: head,
            modfOffset: head
        ))
        for k in 0..<tail {
            edits.append(Edit(kind: .unchanged, origIndex: m - tail + k, modfIndex: n - tail + k))
        }
        return edits
    }

    private static func occurrenceCounts(_ items: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(items.count)
        for item in items { counts[item, default: 0] += 1 }
        return counts
    }

    /// 中段的 LCS：一维 `Int32` 缓冲当 `(m+1) × (n+1)` 表用。
    ///
    /// 改前的 `[[Int]]` 在 4,000 段规模下是 16M 个 `Int`（128MB）——内存是这里的一半
    /// 就能装下（`Int32` 够用：LCS 长度 ≤ min(m, n) 远低于 2³¹），访问也连续。
    /// 但**节奏点不在表，在逐格的 `String ==`**：`-O` 下换表布局只快 10%，
    /// 先比预计算哈希才把 16M 格从 ~380ms 压到 ~85ms（823KB / 4,000 段）。
    private static func lcsCore(
        _ a: ArraySlice<String>,
        _ b: ArraySlice<String>,
        origOffset: Int,
        modfOffset: Int
    ) -> [Edit] {
        let m = a.count, n = b.count

        // 一侧为空：全删或全增（`stride(from:through:)` 在 1...0 会崩，也不能建宽 0 的表）
        if m == 0 || n == 0 {
            var edits: [Edit] = []
            for i in 0..<m { edits.append(Edit(kind: .deleted, origIndex: origOffset + i, modfIndex: -1)) }
            for j in 0..<n { edits.append(Edit(kind: .inserted, origIndex: -1, modfIndex: modfOffset + j)) }
            return edits
        }

        // ArraySlice → Array 只是复制引用（String 不复制内容），换来内层循环能走
        // UnsafeBufferPointer，省掉每次下标的 startIndex 加法与边界检查。
        let rows = Array(a), cols = Array(b)
        // 哈希用来**提前排除**：不相等就绝不相等，相等仍要再比一次（碰撞时结果不能变）。
        // 不用 `String.hashValue`：它每进程随机加盐，跨进程不可复现，调试时对不上账。
        let rowHashes = rows.map(fnv1a), colHashes = cols.map(fnv1a)
        let width = n + 1
        #if DEBUG
        dpCellCount += m * n
        #endif
        var dp = [Int32](repeating: 0, count: (m + 1) * width)

        var edits: [Edit] = []
        edits.reserveCapacity(m + n)

        rows.withUnsafeBufferPointer { aRow in
            cols.withUnsafeBufferPointer { bRow in
                dp.withUnsafeMutableBufferPointer { table in
                    for i in 1...m {
                        let row = i * width
                        let prev = row - width
                        let aRowI = aRow[i - 1]
                        let aHashI = rowHashes[i - 1]
                        for j in 1...n {
                            if aHashI == colHashes[j - 1], aRowI == bRow[j - 1] {
                                table[row + j] = table[prev + j - 1] + 1
                            } else {
                                let up = table[prev + j]
                                let left = table[row + j - 1]
                                table[row + j] = up > left ? up : left
                            }
                        }
                    }

                    // Backtrack（规则与改前逐字一致：并列时优先「插入」）
                    var i = m, j = n
                    while i > 0 || j > 0 {
                        if i > 0, j > 0, aRow[i - 1] == bRow[j - 1] {
                            edits.append(Edit(
                                kind: .unchanged,
                                origIndex: origOffset + i - 1,
                                modfIndex: modfOffset + j - 1
                            ))
                            i -= 1; j -= 1
                        } else if j > 0, i == 0 || table[i * width + j - 1] >= table[(i - 1) * width + j] {
                            edits.append(Edit(kind: .inserted, origIndex: -1, modfIndex: modfOffset + j - 1))
                            j -= 1
                        } else {
                            edits.append(Edit(kind: .deleted, origIndex: origOffset + i - 1, modfIndex: -1))
                            i -= 1
                        }
                    }
                }
            }
        }
        return edits.reversed()
    }

    /// FNV-1a over UTF-8。只用于「提前排除」，碰撞不影响正确性（还会再比一次字符串）。
    private static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func buildDiffs(edits: [Edit], orig: [String], modf: [String]) -> [ParagraphDiff] {
        var result: [ParagraphDiff] = []
        var pendingDel: Edit? = nil

        for edit in edits {
            switch edit.kind {
            case .unchanged:
                if let del = pendingDel {
                    // Orphan deletion — no adjacent insertion to pair with
                    result.append(ParagraphDiff(
                        id: UUID(),
                        originalIndex: del.origIndex,
                        modifiedIndex: -1,
                        original: orig[del.origIndex],
                        modified: "",
                        status: .pending
                    ))
                    pendingDel = nil
                }

            case .deleted:
                if let del = pendingDel {
                    result.append(ParagraphDiff(
                        id: UUID(),
                        originalIndex: del.origIndex,
                        modifiedIndex: -1,
                        original: orig[del.origIndex],
                        modified: "",
                        status: .pending
                    ))
                }
                pendingDel = edit

            case .inserted:
                if let del = pendingDel {
                    // Pair deletion + insertion → substitution
                    result.append(ParagraphDiff(
                        id: UUID(),
                        originalIndex: del.origIndex,
                        modifiedIndex: edit.modfIndex,
                        original: orig[del.origIndex],
                        modified: modf[edit.modfIndex],
                        status: .pending
                    ))
                    pendingDel = nil
                } else {
                    result.append(ParagraphDiff(
                        id: UUID(),
                        originalIndex: -1,
                        modifiedIndex: edit.modfIndex,
                        original: "",
                        modified: modf[edit.modfIndex],
                        status: .pending
                    ))
                }
            }
        }

        // Flush trailing deletion
        if let del = pendingDel {
            result.append(ParagraphDiff(
                id: UUID(),
                originalIndex: del.origIndex,
                modifiedIndex: -1,
                original: orig[del.origIndex],
                modified: "",
                status: .pending
            ))
        }

        return result
    }
}
