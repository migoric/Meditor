import Foundation

/// 一次检索的结果。
struct MemorySelection: Sendable, Equatable {
    /// `## 约定` 段的原文（人写的，原样注入，只受预算截断）。
    var conventionText: String = ""
    /// 被选中的条目：pinned 在前，其余按分数降序。
    var records: [MemoryRecord] = []
    /// 因预算或低分被放弃的条目数（面板用来回答「为什么它没被用上」）。
    var droppedCount: Int = 0
    /// 这段注入本身的估算 token（含约定段）。
    var estimatedTokens: Int = 0

    var isEmpty: Bool { conventionText.isEmpty && records.isEmpty }
}

/// 记忆的检索 / 去重 / 巩固 / 遗忘判定。
///
/// 全部是纯函数：没有 I/O、不读时间。`now` 一律由调用方传入 —— 否则「90 天老化」
/// 这类判据在测试里根本没法验。
///
/// ## 为什么不用向量检索
///
/// 工作区级记忆量级是几十到几百条，关键词 + 中文 2-gram 足够区分；
/// 引入 embedding 会打破仓根的「零运行时依赖」，并撞 `product-roadmap-prd.zh.md` §9
/// 对「笔记双链系统」的非目标设定。这条取舍写在 `docs/ai-memory-design.md` §4.3。
enum MemorySelector {

    /// 注入预算（token）。一条记忆约 20–60 token，800 约合 15–30 条。
    /// 这个值不动 system prompt 里其他段的预算，是**额外**的。
    static let defaultBudgetTokens = 800

    /// pinned 条目上限。pin 是用户的显式意图，但也不能无限——否则预算全被它吃掉。
    static let pinnedLimit = 20

    /// 多久没用过就可以归档。
    static let staleDays = 90

    /// 判定「同一条」的相似度阈值。捕获去重与巩固合并共用，避免两套口径。
    static let sameEntrySimilarity = 0.8

    /// 单次 run 允许新增的条数。防提示注入刷屏，也防模型把对话流水账全记下来。
    static let newEntriesPerRunLimit = 8

    // MARK: - 打分

    /// 关键词命中率：命中 token 数 / 查询 token 数。
    ///
    /// 用比率而不是绝对命中数：长查询天然命中多，绝对数会让长查询压住精准的短查询。
    static func keywordScore(entryText: String, queryTokens: Set<String>) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let entryTokens = MemoryTokens.tokenize(entryText)
        guard !entryTokens.isEmpty else { return 0 }
        return Double(queryTokens.intersection(entryTokens).count) / Double(queryTokens.count)
    }

    /// 单条打分。各分量都能单独解释——面板要能回答「它凭什么被选中」。
    static func score(_ record: MemoryRecord, queryTokens: Set<String>, now: Date) -> Double {
        // 覆盖率取平方根再乘权重：命中一个关键词就已经说明这条相关，命中更多是加分，
        // 但不是线性必需。线性的话「五个查询词里中一个」只能拿 0.6，会被一条新鲜的
        // 无关条目（种类 0.8 + 新鲜度 1.0）压过去 —— 实测就是这么输的。
        let coverage = keywordScore(entryText: record.entry.text, queryTokens: queryTokens)
        let keyword = 3 * coverage.squareRoot()
        let kind = record.entry.kind.weight

        // 新鲜度：90 天半衰。用 updatedAt 而不是 createdAt——被修订过的条目应该回春。
        let stamp = record.counter.updatedAt ?? record.counter.createdAt ?? now
        let ageDays = max(0, now.timeIntervalSince(stamp)) / 86_400
        let recency = exp(-ageDays / Double(staleDays))

        // 使用频次：被反复检索到的条目更可能是真约定。log 压缩，避免老条目一家独大。
        let usage = log1p(Double(record.counter.useCount)) * 0.3

        return keyword + kind + recency + usage
    }

    // MARK: - 检索

    /// 选出这次要注入的条目。
    ///
    /// 顺序规则：约定段吃预算 → pinned → 检索条目。pinned 先于检索，因为它是用户的显式意图，
    /// 不该被一场和它无关的对话挤掉。
    static func select(
        _ records: [MemoryRecord],
        query: String,
        conventionText: String = "",
        budgetTokens: Int = defaultBudgetTokens,
        now: Date
    ) -> MemorySelection {
        var result = MemorySelection()

        // 约定段：原文注入，超预算就截断（它比任何条目都重要，所以先吃预算）。
        let conventionTokens = AIConversation.estimateTokens(conventionText)
        if conventionTokens > budgetTokens {
            let ratio = Double(budgetTokens) / Double(max(conventionTokens, 1))
            let keep = Int(Double(conventionText.count) * ratio)
            result.conventionText = String(conventionText.prefix(max(keep, 0)))
            result.estimatedTokens = budgetTokens
            result.droppedCount = records.count
            return result
        }
        result.conventionText = conventionText
        var remaining = budgetTokens - conventionTokens

        // pinned：按最近使用排序，受 pinned 条数与预算双重约束。
        let pinned = records
            .filter { $0.counter.pinned }
            .sorted { ($0.counter.lastUsedAt ?? .distantPast) > ($1.counter.lastUsedAt ?? .distantPast) }
            .prefix(pinnedLimit)
        for record in pinned {
            let cost = entryTokens(record)
            guard cost <= remaining else { continue }
            remaining -= cost
            result.records.append(record)
            result.estimatedTokens += cost
        }

        // 检索条目。
        // 打分拆成显式步骤而不是一条长链：整链写在一起会让类型检查器超时
        // （实测 "unable to type-check this expression in reasonable time"）。
        let queryTokens = MemoryTokens.tokenize(query)
        let unpinned: [MemoryRecord] = records.filter { !$0.counter.pinned }
        var scored: [(record: MemoryRecord, score: Double)] = []
        scored.reserveCapacity(unpinned.count)
        for record in unpinned {
            scored.append((record, score(record, queryTokens: queryTokens, now: now)))
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.record.id < rhs.record.id }
            return lhs.score > rhs.score
        }

        for candidate in scored {
            let cost = entryTokens(candidate.record)
            if cost <= remaining {
                remaining -= cost
                result.records.append(candidate.record)
                result.estimatedTokens += cost
            } else {
                result.droppedCount += 1
            }
        }
        return result
    }

    /// 一条记忆注入后的估算 token（含 Markdown 行本身的开销）。
    static func entryTokens(_ record: MemoryRecord) -> Int {
        AIConversation.estimateTokens(MemoryDocument.renderLine(record.entry))
    }

    // MARK: - 捕获

    /// 找重：返回相似度达到阈值的既有条目（取最像的那条）。
    static func duplicate(of text: String, in records: [MemoryRecord]) -> MemoryRecord? {
        var best: (record: MemoryRecord, similarity: Double)?
        for record in records {
            let similarity = MemoryTokens.similarity(text, record.entry.text)
            if similarity >= sameEntrySimilarity, similarity > (best?.similarity ?? 0) {
                best = (record, similarity)
            }
        }
        return best?.record
    }

    // MARK: - 巩固

    /// 合并同一 kind 下高度相似的条目。保留较新的正文，计数相加，出处取第一个非空的。
    ///
    /// 纯函数、确定性（按文件顺序遍历，合并进来的条目从结果里消失），所以可以单测。
    static func consolidate(_ records: [MemoryRecord]) -> [MemoryRecord] {
        var kept: [MemoryRecord] = []
        for record in records {
            // 只在同 kind 内合并：把「术语」并进「约定」会改变它的权重与语义。
            if let index = kept.firstIndex(where: {
                $0.entry.kind == record.entry.kind
                    && MemoryTokens.similarity($0.entry.text, record.entry.text) >= sameEntrySimilarity
            }) {
                kept[index].counter.useCount += record.counter.useCount
                kept[index].counter.pinned = kept[index].counter.pinned || record.counter.pinned
                if kept[index].counter.source == nil { kept[index].counter.source = record.counter.source }
                // 正文取更新时间较晚的那条。
                let incoming = record.counter.updatedAt ?? record.counter.createdAt ?? .distantPast
                let existing = kept[index].counter.updatedAt ?? kept[index].counter.createdAt ?? .distantPast
                if incoming > existing {
                    kept[index].entry.text = record.entry.text
                    kept[index].counter.updatedAt = incoming
                }
            } else {
                kept.append(record)
            }
        }
        return kept
    }

    // MARK: - 遗忘

    /// 可归档的条目：非 pinned、超过 `staleDays` 天没被用过、且一次都没被检索到过。
    ///
    /// 条件里「一次都没用过」是关键：只按时间老化会把「一年只用一次但每次都关键」的
    /// 长期约定清掉。归档不删除，用户能在面板里恢复。
    static func archivable(_ records: [MemoryRecord], now: Date) -> [MemoryRecord] {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        return records.filter { record in
            guard !record.counter.pinned, record.counter.useCount == 0 else { return false }
            let last = record.counter.lastUsedAt ?? record.counter.updatedAt ?? record.counter.createdAt ?? now
            return last < cutoff
        }
    }
}
