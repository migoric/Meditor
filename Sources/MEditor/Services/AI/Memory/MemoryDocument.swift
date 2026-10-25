import Foundation

/// `MEDITOR.md` 的解析与渲染。
///
/// ## 只认两段
///
/// MEditor 拥有 `## 记忆` 与 `## 归档` 两段：解析时把它们的行**摘掉**，渲染时按原文
/// 相同位置写回。其余内容（`## 约定`、用户自己的备注、注释）全部原样保留 —— 这是硬约束。
/// 「解析成结构体再整体重渲染」这种写法会把用户手写的散文段吃掉，而用户的文件不是我们的缓冲区。
///
/// ## 为什么是 Markdown 不是 JSON
///
/// ① 用户能在 MEditor 自己里编辑，带 diff 审阅；② 能进 git 随项目走；
/// ③ 与 `AGENTS.md` / `CLAUDE.md` 的行业惯例同构，别的 agent 也能读。
/// 机器要的计数与出处放在旁挂的 `memory-state.json`（见 `MemoryCounter`）。
struct MemoryDocument: Equatable, Sendable {

    static let memoryHeading = "## 记忆"
    static let archiveHeading = "## 归档"

    /// 记忆段之外的全部行，原样，含 `## 约定` 段与用户备注。
    var otherLines: [String]
    /// 活跃条目（按文件顺序，**不排序**：排序会让每次保存都重写全文，git diff 全是噪音）。
    var entries: [MemoryEntry]
    /// 归档条目（被遗忘策略刷下来的，不参与检索）。
    var archived: [MemoryEntry]
    /// 记忆段在 `otherLines` 中的插入位置。保存时放回原处，避免段落顺序来回漂。
    var insertionIndex: Int

    /// 新建文件时的骨架。带一句注释告诉用户这个文件是干什么的、能不能手改。
    static let empty = MemoryDocument(
        otherLines: [
            "# MEDITOR.md",
            "",
            "<!-- MEditor 的 AI 记忆。人可以直接按同样格式增删；agent 只往「记忆」段追加。 -->",
            ""
        ],
        entries: [],
        archived: [],
        insertionIndex: 4
    )

    var isEmpty: Bool { entries.isEmpty && archived.isEmpty && otherLines.isEmpty }

    /// `## 约定` 段的正文（人写的那部分），原样返回、去掉首尾空行。
    ///
    /// 不解析成条目：它是散文，切碎了就没法原样注入。它比任何条目都重要，
    /// 所以在检索里**先吃预算**（见 `MemorySelector.select`）。
    var conventionText: String {
        var collecting = false
        var body: [String] = []
        for line in otherLines {
            if let title = Self.sectionTitle(line) {
                collecting = (title == "约定")
                continue
            }
            if collecting { body.append(line) }
        }
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        return body.joined(separator: "\n")
    }

    // MARK: - 解析

    static func parse(_ text: String) -> MemoryDocument {
        var others: [String] = []
        var entries: [MemoryEntry] = []
        var archived: [MemoryEntry] = []
        var insertion: Int?

        enum Section { case other, memory, archive }
        var section: Section = .other

        for line in text.components(separatedBy: "\n") {
            if let title = sectionTitle(line) {
                switch title {
                case "记忆":
                    section = .memory
                    if insertion == nil { insertion = others.count }
                case "归档":
                    section = .archive
                default:
                    section = .other
                    others.append(line)
                }
                continue
            }
            switch section {
            case .memory:
                if let entry = entry(from: line) { entries.append(entry) }
            case .archive:
                if let entry = entry(from: line) { archived.append(entry) }
            case .other:
                others.append(line)
            }
        }

        return MemoryDocument(
            otherLines: others,
            entries: entries,
            archived: archived,
            insertionIndex: insertion ?? others.count
        )
    }

    /// 二级标题的标题文本（`## 记忆` → `记忆`）。三级及以下不算段（`### x` 是段内小标题）。
    private static func sectionTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), !trimmed.hasPrefix("###") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// 解析一行条目：`- [约定] 正文 [#a1b2c3]`。
    ///
    /// 宽容口径：种类标记缺失 ⇒ 落 `.fact`；id 缺失 ⇒ 内容寻址补一个。
    /// 这两条让用户手写 `- 别忘了封面用蓝色` 也能被采纳，而不是静默丢弃。
    static func entry(from line: String) -> MemoryEntry? {
        var body = line.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("- ") || body.hasPrefix("* ") else { return nil }
        body.removeFirst(2)
        body = body.trimmingCharacters(in: .whitespaces)

        var kind: MemoryKind = .fact
        if body.hasPrefix("["), let close = body.firstIndex(of: "]"), close > body.startIndex {
            let inner = String(body[body.index(after: body.startIndex)..<close])
            if let matched = MemoryKind.allCases.first(where: { $0.displayName == inner }) {
                kind = matched
                body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        var id: String?
        if body.hasSuffix("]"), let open = body.range(of: "[#", options: .backwards) {
            let candidate = String(body[open.upperBound..<body.index(before: body.endIndex)])
            if (4...12).contains(candidate.count), candidate.allSatisfy(\.isHexDigit) {
                id = candidate
                body = String(body[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !body.isEmpty else { return nil }
        return MemoryEntry(id: id ?? MemoryEntry.makeID(text: body), kind: kind, text: body)
    }

    // MARK: - 渲染

    func render() -> String {
        var block: [String] = [Self.memoryHeading, ""]
        for entry in entries {
            block.append(Self.renderLine(entry))
        }
        if !archived.isEmpty {
            block.append("")
            block.append(Self.archiveHeading)
            block.append("")
            for entry in archived {
                block.append(Self.renderLine(entry))
            }
        }

        let index = min(max(insertionIndex, 0), otherLines.count)
        var lines = Array(otherLines[0..<index])
        lines.append(contentsOf: block)
        lines.append(contentsOf: otherLines[index...])
        return lines.joined(separator: "\n")
    }

    static func renderLine(_ entry: MemoryEntry) -> String {
        "- [\(entry.kind.displayName)] \(entry.text) [#\(entry.id)]"
    }

    // MARK: - 变更

    mutating func upsert(_ entry: MemoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    @discardableResult
    mutating func remove(id: String) -> MemoryEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    @discardableResult
    mutating func archive(id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        archived.append(entries.remove(at: index))
        return true
    }

    @discardableResult
    mutating func restore(id: String) -> Bool {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return false }
        entries.append(archived.remove(at: index))
        return true
    }
}
