import Foundation

// MARK: - 记忆种类

/// 记忆条目的种类。既决定注入时的排序权重，也决定面板里的分组。
///
/// 为什么要分类而不是一个扁平列表：不同类型的记忆**半衰期不同**。
/// 「这个项目把 hunk 叫作变更块」这种术语基本不变；「这一版封面用蓝色」
/// 这种决策过两周就废了。混在一起就没法给不同的老化策略。
enum MemoryKind: String, Codable, CaseIterable, Sendable {
    /// 约定：命名、格式、章节骨架。项目级最稳的一类，权重最高。
    case convention
    /// 术语：这个词在本项目里指什么。
    case term
    /// 偏好：文风、语气、禁用词。
    case preference
    /// 事实：已核实的结论、数字、出处。
    case fact
    /// 决策：定下来的方案与理由。
    case decision

    /// 检索排序用的种类权重。convention 最高：它通常是「不遵守就写错」的硬规则。
    var weight: Double {
        switch self {
        case .convention: return 1.5
        case .decision:   return 1.2
        case .preference: return 1.2
        case .term:       return 1.0
        case .fact:       return 0.8
        }
    }

    var displayName: String {
        switch self {
        case .convention: return "约定"
        case .term:       return "术语"
        case .preference: return "偏好"
        case .fact:       return "事实"
        case .decision:   return "决策"
        }
    }

    /// 面板里的分组顺序：越稳的越靠前。
    var sortOrder: Int {
        switch self {
        case .convention: return 0
        case .decision:   return 1
        case .term:       return 2
        case .preference: return 3
        case .fact:       return 4
        }
    }
}

// MARK: - 条目

/// 一条记忆。
///
/// `id` 是 6–8 位十六进制短串，直接写在 Markdown 里（`[#a1b2c3]`），
/// 这样模型可以在回答里引用「依据 [#a1b2c3]」，用户能回溯到具体哪一条。
struct MemoryEntry: Identifiable, Codable, Sendable, Equatable {
    /// 单条正文上限。超过通常说明该拆成两条，或它根本不是「记忆」而是文档内容。
    static let maxTextLength = 500

    let id: String
    var kind: MemoryKind
    var text: String

    /// 内容寻址 id：取归一化文本的 FNV-1a 前 6 位。
    ///
    /// 为什么不用 UUID：文件里已经有显式 id 时这条用不上；只在**人写进文件但没写 id**
    /// 的条目上兜底。内容寻址让「同一段话」在每次解析时拿到同一个 id，解析是幂等的，
    /// 计数器不会因为多读一次文件就漂移。代价：用户改了正文就等于换了一条记忆，
    /// 计数归零——这个取舍写进了设计稿 §2。
    static func makeID(text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in MemoryTokens.normalize(text).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%06x", hash & 0x00ff_ffff)
    }
}

// MARK: - 作用域

/// 记忆的作用域。两层：工作区级随项目走（进 git），全局级跟人走。
enum MemoryScope: String, Sendable, CaseIterable {
    case workspace
    case global

    var displayName: String {
        switch self {
        case .workspace: return "本项目"
        case .global:    return "全局"
        }
    }
}

// MARK: - 分词与相似度

/// 中英混排的分词与相似度。
///
/// 中文没有空格，按词切需要词典。这里用 **2-gram**（相邻两字一取）：
/// 无依赖、对「章节标题」「章节标题只用两级」这种命中足够，代价是会有噪声 token，
/// 所以关键词计分用「命中数 / 查询 token 数」而不是绝对命中数。
enum MemoryTokens {

    /// 无语义归一：小写 + 折叠空白。用于去重比较和 id 生成。
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 检索用 token 集合。
    static func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        let normalized = normalize(text)
        // ASCII / 数字：按词边界切，长度 < 2 的丢掉（"a" "of" 之类没有区分度）
        var asciiRun = ""
        var cjkRun: [Character] = []

        func flushASCII() {
            if asciiRun.count >= 2 { tokens.insert(asciiRun) }
            asciiRun = ""
        }
        func flushCJK() {
            // 单字成不了 gram，但整串就是一个字时仍保留（如「钩」）
            if cjkRun.count == 1 { tokens.insert(String(cjkRun)) }
            for i in 0..<max(0, cjkRun.count - 1) {
                tokens.insert(String(cjkRun[i...(i + 1)]))
            }
            cjkRun.removeAll()
        }

        for ch in normalized {
            if ch.isASCII {
                flushCJK()
                if ch.isLetter || ch.isNumber {
                    asciiRun.append(ch)
                } else {
                    flushASCII()
                }
            } else {
                flushASCII()
                if ch.isWhitespace || ch.isPunctuation {
                    flushCJK()
                } else {
                    cjkRun.append(ch)
                }
            }
        }
        flushASCII()
        flushCJK()
        return tokens
    }

    /// Jaccard 相似度。去重与巩固都靠它（阈值 0.8）。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = tokenize(lhs), b = tokenize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return normalize(lhs) == normalize(rhs) ? 1 : 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}

// MARK: - 计数器

/// 旁挂的机器状态：命中次数、最近使用、pin、出处。
///
/// 这些数字每次注入都会变，写进人可读的 Markdown 会让 git diff 淹没真实内容，
/// 所以单独一个 JSON。它丢了不影响记忆本身（计数归零），正文不丢。
///
/// `source` 也放这里而不是 Markdown 里：出处是溯源元数据，不是记忆内容。
/// 塞进 Markdown 会让每条变成 `- [事实] … [#a1b2]（来源：docs/spec.md L42-57）`，
/// 人读起来全是噪声，而机器本来就有这个 JSON。
struct MemoryCounter: Codable, Sendable, Equatable {
    var useCount: Int = 0
    var lastUsedAt: Date?
    var pinned: Bool = false
    var source: String?
    /// 首次见到这条的时间。文件里没有时间信息，所以用「第一次被载入时文件的修改时间」兜底。
    var createdAt: Date?
    /// 正文最后一次被改的时间。面板用它排「最近变更」。
    var updatedAt: Date?
}

/// 带计数的条目视图（面板与检索都用它）。
struct MemoryRecord: Identifiable, Sendable, Equatable {
    var entry: MemoryEntry
    var counter: MemoryCounter
    var scope: MemoryScope

    var id: String { entry.id }
}
