import Foundation

// MARK: - MarkdownSection

/// Markdown 里的一节：标题（或段落）的位置与规模。行号 1-based、闭区间。
///
/// `level == 0` 表示这篇文档没有标题，退化成「按空行分段」的段落块——此时
/// `title` 是首行摘要。两种情形共用同一套定位 / 读取 / 替换逻辑，工具层不必分叉。
struct MarkdownSection: Sendable, Equatable {
    /// 文档内的序号（1-based、文档顺序）。唯一 ⇒ 模型可以直接用 `#3` 指代，
    /// 不必复述标题（复述会错字，也会多花 token）。
    let ordinal: Int
    let title: String
    /// 1...6；0 = 无标题文档里的段落块。
    let level: Int
    /// 从最外层到本节的标题路径（含本节）。
    let path: [String]
    let startLine: Int
    let endLine: Int
    /// 正文字符数（不含标题行、已去首尾空白）。
    let charCount: Int

    var pathText: String { path.joined(separator: " > ") }
    var lineRange: String { "L\(startLine)–L\(endLine)" }
    var isParagraphBlock: Bool { level == 0 }
    /// 大纲里的引述文本：标题超长时截断（标题通常是散文，不是地址）。
    func displayTitle(maxLength: Int = 60) -> String {
        title.count > maxLength ? String(title.prefix(maxLength)) + "…" : title
    }
}

enum MarkdownStructureError: Error, Equatable {
    case notFound(query: String, available: [String])
    case ambiguous(query: String, matches: [MarkdownSection])

    var modelFacingMessage: String {
        switch self {
        case .notFound(let query, let available):
            let list = available.prefix(40).map { "  - \($0)" }.joined(separator: "\n")
            let tail = available.count > 40 ? "\n  …（共 \(available.count) 节）" : ""
            return "[!] 没有找到名为「\(query)」的节。可用的节：\n\(list)\(tail)"
        case .ambiguous(let query, let matches):
            let list = matches.prefix(10)
                .map { "  - \($0.pathText)（\($0.lineRange)）" }
                .joined(separator: "\n")
            return "[!] 「\(query)」匹配到 \(matches.count) 节，请用完整路径消歧（外层 > 内层）：\n\(list)"
        }
    }
}

// MARK: - MarkdownStructure

/// Markdown 结构层：标题树解析、按路径定位、整节替换。纯函数、无 IO。
///
/// 只认 ATX 标题（`## 标题`）与 Setext 标题（下一行是 `===` / `---`），与预览端
/// （marked）的口径一致；围栏代码块（``` / ~~~）里的 `#` 不算标题——这一条是
/// 解析器的分水岭，漏了它任何带 shell 注释的文档都会解析出满屏假标题。
enum MarkdownStructure {

    struct Heading: Equatable {
        let level: Int
        /// 0-based 行号。
        let lineIndex: Int
        let title: String
    }

    // MARK: 标题扫描

    static func headings(in text: String) -> [Heading] {
        let lines = text.components(separatedBy: "\n")
        var result: [Heading] = []
        var fence: (marker: Character, length: Int)? = nil

        for (index, rawLine) in lines.enumerated() {
            if let open = fence {
                if isFenceLine(rawLine, char: open.marker, minLength: open.length) {
                    fence = nil
                }
                continue
            }
            if let open = fenceOpening(rawLine) {
                fence = open
                continue
            }
            // 下划线行自身不是标题文本：否则 `Title\n=====\nSub\n---` 会把 `=====`
            // 当成下一节的标题。Thematic break（单独的 `---`）同理被跳过。
            if parseSetextUnderline(rawLine) != nil { continue }
            if let parsed = parseATX(rawLine) {
                result.append(Heading(level: parsed.level, lineIndex: index, title: parsed.title))
                continue
            }
            // Setext：本行是普通文本、下一行全是 = 或 -（且不是表格分隔行）
            if index + 1 < lines.count, !rawLine.trimmingCharacters(in: .whitespaces).isEmpty,
               let level = parseSetextUnderline(lines[index + 1]) {
                result.append(Heading(level: level, lineIndex: index,
                                      title: rawLine.trimmingCharacters(in: .whitespaces)))
            }
        }
        return result
    }

    /// ATX 标题解析。要求 `#` 后有空格（与 CommonMark / marked 一致）：
    /// 预览不认的写法，大纲也不该认，否则「大纲有这节、预览看不到标题」。
    static func parseATX(_ rawLine: String) -> (level: Int, title: String)? {
        var index = rawLine.startIndex
        var spaces = 0
        while index < rawLine.endIndex, rawLine[index] == " ", spaces < 4 {
            index = rawLine.index(after: index)
            spaces += 1
        }
        guard spaces <= 3 else { return nil }   // 4 空格 = 缩进代码块

        var level = 0
        while index < rawLine.endIndex, rawLine[index] == "#", level < 7 {
            level += 1
            index = rawLine.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        guard index == rawLine.endIndex || rawLine[index] == " " || rawLine[index] == "\t" else { return nil }

        var title = String(rawLine[index...]).trimmingCharacters(in: .whitespaces)
        // CommonMark：结尾的一串 `#` 只有**前面是空白**时才是结束符
        // （`## 标题 ##` → 标题，`## C#` → C#）
        let chars = Array(title)
        var end = chars.count
        while end > 0, chars[end - 1] == "#" { end -= 1 }
        if end < chars.count {
            if end == 0 {
                title = ""
            } else if chars[end - 1] == " " || chars[end - 1] == "\t" {
                title = String(chars[0..<end])
            }
        }
        return (level, title.trimmingCharacters(in: .whitespaces))
    }

    /// Setext 下划线：`===` → H1，`---` → H2。表格分隔行（含 `|`）不算。
    static func parseSetextUnderline(_ rawLine: String) -> Int? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func fenceOpening(_ rawLine: String) -> (marker: Character, length: Int)? {
        let trimmed = rawLine.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count)
    }

    private static func isFenceLine(_ rawLine: String, char: Character, minLength: Int) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == char else { return false }
        let run = trimmed.prefix { $0 == char }
        return run.count >= minLength && run.count == trimmed.count
    }

    // MARK: 节树

    /// 标题节；无标题文档退化为「按空行分段」的段落块（`level == 0`）。
    static func sections(in text: String) -> [MarkdownSection] {
        let heads = headings(in: text)
        guard !heads.isEmpty else { return paragraphSections(in: text) }
        let lines = text.components(separatedBy: "\n")

        var result: [MarkdownSection] = []
        var stack: [(level: Int, title: String)] = []

        for (index, head) in heads.enumerated() {
            while let last = stack.last, last.level >= head.level { stack.removeLast() }
            stack.append((head.level, head.title))

            // 本节结束于「下一个 level <= 自己」的标题之前，否则到文末
            var endLine = lines.count
            for next in heads[(index + 1)...] where next.level <= head.level {
                endLine = next.lineIndex        // next.lineIndex 是 0-based ⇒ 上一行即 1-based 结尾
                break
            }
            let bodyStart = head.lineIndex + 1  // 0-based，标题下一行
            let bodyText: String
            if bodyStart < endLine {
                bodyText = lines[bodyStart..<endLine].joined(separator: "\n")
            } else {
                bodyText = ""
            }
            result.append(MarkdownSection(
                ordinal: result.count + 1,
                title: head.title,
                level: head.level,
                path: stack.map(\.title),
                startLine: head.lineIndex + 1,
                endLine: max(head.lineIndex + 1, endLine),
                charCount: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count
            ))
        }
        return result
    }

    static func paragraphSections(in text: String) -> [MarkdownSection] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [(start: Int, end: Int)] = []
        var start: Int? = nil
        for (index, line) in lines.enumerated() {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if let s = start { blocks.append((s, index - 1)); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { blocks.append((s, lines.count - 1)) }

        return blocks.enumerated().map { offset, block in
            let body = lines[block.start...block.end].joined(separator: "\n")
            let firstLine = lines[block.start].trimmingCharacters(in: .whitespaces)
            return MarkdownSection(
                ordinal: offset + 1,
                title: firstLine,
                level: 0,
                path: [firstLine],
                startLine: block.start + 1,
                endLine: block.end + 1,
                charCount: body.trimmingCharacters(in: .whitespacesAndNewlines).count
            )
        }
    }

    // MARK: 大纲

    /// 大纲文本（不含文档标题行，由调用方补）：每节一行，约 11–16 token。
    static func outline(_ text: String, maxSections: Int = 80) -> String {
        let all = sections(in: text)
        guard !all.isEmpty else { return "（空文档）" }
        let fallback = all.first?.isParagraphBlock == true

        var lines: [String] = []
        if fallback {
            lines.append("（本文没有标题，按空行分段列出；`#n` 指代第 n 段）")
        }
        for section in all.prefix(maxSections) {
            let indent = fallback ? "" : String(repeating: "  ", count: max(0, section.path.count - 1))
            let heading = fallback ? "¶" : String(repeating: "#", count: section.level)
            lines.append("\(indent)#\(section.ordinal) · \(section.lineRange) · \(section.charCount) 字 · \(heading) \(section.displayTitle())")
        }
        if all.count > maxSections {
            lines.append("…（共 \(all.count) 节，已省略 \(all.count - maxSections) 节；用 read_section 直接读指定节）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 定位

    /// 按 `#n`（序号）/ 标题 / 完整路径定位唯一一节。
    ///
    /// 不做模糊匹配：这是**写操作**的定位依据，猜错就是改错节。匹配到多节时抛
    /// `.ambiguous` 并把所有候选的行区间交给模型自己消歧。
    static func locate(_ query: String, in text: String) throws -> MarkdownSection {
        let all = sections(in: text)
        guard !all.isEmpty else {
            throw MarkdownStructureError.notFound(query: query, available: [])
        }
        let candidates = all.map(\.pathText)
        let normalized = normalize(query)

        // ① `#3` / `3` → 序号
        if let ordinal = ordinalQuery(normalized) {
            if let hit = all.first(where: { $0.ordinal == ordinal }) { return hit }
            throw MarkdownStructureError.notFound(query: query, available: candidates)
        }
        // ② 完整路径
        if normalized.contains(">") {
            let parts = query.split(separator: ">").map { normalize(String($0)) }
            let matched = all.filter { $0.path.map(normalize) == parts }
            if matched.count == 1 { return matched[0] }
            if matched.count > 1 { throw MarkdownStructureError.ambiguous(query: query, matches: matched) }
            throw MarkdownStructureError.notFound(query: query, available: candidates)
        }
        // ③ 标题
        let matched = all.filter { normalize($0.title) == normalized }
        if matched.count == 1 { return matched[0] }
        if matched.count > 1 { throw MarkdownStructureError.ambiguous(query: query, matches: matched) }
        throw MarkdownStructureError.notFound(query: query, available: candidates)
    }

    /// 归一化：去 `#`、去包裹引号、小写、折叠空白。
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        let quotes: Set<Character> = ["\"", "'", "「", "」", "“", "”", "『", "』"]
        while let f = s.first, quotes.contains(f) { s.removeFirst() }
        while let l = s.last, quotes.contains(l) { s.removeLast() }
        return s.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
            .joined(separator: " ")
    }

    private static func ordinalQuery(_ normalized: String) -> Int? {
        guard !normalized.isEmpty else { return nil }
        let digits = normalized.hasPrefix("#") ? normalized.dropFirst() : normalized[...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    // MARK: 读 / 写

    /// 包含某段文本的**最内层**节（选区落在哪一节）。找不到返回 nil。
    static func section(containing needle: String, in text: String) -> MarkdownSection? {
        guard !needle.isEmpty, let range = text.range(of: needle) else { return nil }
        let line = text[text.startIndex..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return sections(in: text).last { $0.startLine <= line }
    }

    /// 读出该节的完整原文（含标题行）。段落块同样适用。
    static func source(of section: MarkdownSection, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let from = min(section.startLine - 1, lines.count)
        let to = min(section.endLine, lines.count)
        guard from < to else { return "" }
        return lines[from..<to].joined(separator: "\n")
    }

    /// 整节替换。
    ///
    /// 语义：**标题行默认保留**，`content` 只替换正文——模型说「把第二节扩写到 800 字」时
    /// 给的通常是正文，不是新标题。若 `content` 自己以标题行开头，则连标题一起替换
    /// （允许「把 H2 改成 H3」「改节名」）。
    static func replacing(_ section: MarkdownSection, in text: String, with content: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var newLines = content.components(separatedBy: "\n")

        let contentStartsWithHeading = newLines
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .flatMap { parseATX($0) != nil || parseSetextUnderline($0) != nil } ?? false
        let replaceHeading = section.isParagraphBlock || contentStartsWithHeading

        // 0-based 半开区间
        var from = replaceHeading ? section.startLine - 1 : section.startLine
        var to = section.endLine
        from = min(max(0, from), lines.count)
        to = min(max(from, to), lines.count)

        // 只替换**正文实体**，不吃掉节两侧的空行：否则「# 一 / 空 / 旧正文 / 空」换成
        // 「新正文」之后，标题下面那行空行会一起消失，输出变成「# 一\n新正文」——
        // 结构没错但格式变了，用户会在 diff 里看到多余的删除行。
        if !replaceHeading {
            while from < to, lines[from].trimmingCharacters(in: .whitespaces).isEmpty { from += 1 }
            while to > from, lines[to - 1].trimmingCharacters(in: .whitespaces).isEmpty { to -= 1 }
        }

        // 与后文之间留一个空行：新内容末行非空、后一行也非空时补
        let following = to < lines.count ? lines[to] : nil
        if let following, !following.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = newLines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            newLines.append("")
        }
        // 与上文之间同样处理（整节替换时上一行可能是正文）
        if replaceHeading, from > 0, let first = newLines.first,
           !first.trimmingCharacters(in: .whitespaces).isEmpty,
           !lines[from - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            newLines.insert("", at: 0)
        }
        lines.replaceSubrange(from..<to, with: newLines)
        return lines.joined(separator: "\n")
    }
}
