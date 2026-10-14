import SwiftUI

/// Lightweight native Markdown renderer for chat content. Handles the common
/// block constructs (headings, bullet/ordered lists, fenced code, blockquotes,
/// horizontal rules, paragraphs) and inline syntax (bold/italic/code/links via
/// `AttributedString`). Re-parses cheaply on every change, so it works while a
/// reply is still streaming in.
struct MarkdownText: View {
    let markdown: String
    var textColor: Color = .primary
    var secondaryColor: Color = .secondary
    var codeBackground: Color = Color.primary.opacity(0.06)
    var accent: Color = .accentColor

    // 平台字号：桌面面板 13pt 正文；移动端全宽对话，整体放大一档。
    #if os(iOS)
    fileprivate static let bodySize: CGFloat = 16
    fileprivate static let codeSize: CGFloat = 14
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 19
        case 3: return 17.5
        default: return 16.5
        }
    }
    #else
    fileprivate static let bodySize: CGFloat = 13
    fileprivate static let codeSize: CGFloat = 12
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 14.5
        default: return 13.5
        }
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Self.parse(markdown)) { block in
                view(for: block)
            }
        }
    }

    // MARK: Block rendering

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .kerning(-0.2)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 5 : 3)

        case .paragraph(let text):
            inline(text)
                .font(.system(size: Self.bodySize))
                .foregroundStyle(textColor)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    bulletItem(item)
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(accent.opacity(0.85))
                        inline(item).font(.system(size: Self.bodySize)).foregroundStyle(textColor)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .code(let code, let lang):
            CodeBlockView(
                code: code, lang: lang,
                textColor: textColor, secondaryColor: secondaryColor,
                codeBackground: codeBackground, accent: accent
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.5))
                    .frame(width: 3)
                inline(text)
                    .font(.system(size: Self.bodySize))
                    .foregroundStyle(secondaryColor)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.06))
            )

        case .table(let header, let rows):
            tableView(header, rows)

        case .rule:
            Rectangle().fill(secondaryColor.opacity(0.2)).frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    /// A list item, rendered as a task checkbox when it starts with `[ ]`/`[x]`.
    @ViewBuilder
    private func bulletItem(_ item: String) -> some View {
        if let task = taskPrefix(item) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: task.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12.5))
                    .foregroundStyle(task.done ? accent : secondaryColor)
                inline(task.text).font(.system(size: Self.bodySize))
                    .foregroundStyle(task.done ? secondaryColor : textColor)
                    .strikethrough(task.done, color: secondaryColor)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(accent.opacity(0.55))
                    .frame(width: 4.5, height: 4.5)
                    .padding(.top, 6)
                inline(item).font(.system(size: Self.bodySize)).foregroundStyle(textColor)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func taskPrefix(_ item: String) -> (done: Bool, text: String)? {
        let lower = item.lowercased()
        if lower.hasPrefix("[ ] ") { return (false, String(item.dropFirst(4))) }
        if lower.hasPrefix("[x] ") { return (true, String(item.dropFirst(4))) }
        return nil
    }

    @ViewBuilder
    private func tableView(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        VStack(spacing: 0) {
            tableRow(header, columns: columns, kind: .header)
            ForEach(rows.indices, id: \.self) { r in
                tableRow(rows[r], columns: columns, kind: r % 2 == 0 ? .even : .odd)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                // ⚠️ 此处刻意用字面量 1 而非 DS.Stroke.regular：本文件在 iOS target
                // 的共享清单里（Mobile/MEditorMobile.xcodeproj 直接引用
                // ../Sources/MEditor/Views/Shared/MarkdownText.swift），但定义 `DS`
                // 的 DesignTokens.swift **不在**那份清单里 ⇒ iOS 侧编译不到 `DS`。
                // 共享文件不能引用仅桌面端可见的 token。
                .strokeBorder(secondaryColor.opacity(0.22), lineWidth: 1)
        )
    }

    private enum TableRowKind { case header, even, odd }

    private func tableRow(_ cells: [String], columns: Int, kind: TableRowKind) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { c in
                inline(c < cells.count ? cells[c] : "")
                    .font(.system(size: 12, weight: kind == .header ? .semibold : .regular))
                    .foregroundStyle(kind == .header ? textColor : textColor)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                if c < columns - 1 {
                    Rectangle().fill(secondaryColor.opacity(0.10)).frame(width: 1)
                }
            }
        }
        .background(tableRowBackground(kind))
        .overlay(alignment: .bottom) {
            if kind == .header {
                Rectangle().fill(secondaryColor.opacity(0.22)).frame(height: 1)
            }
        }
    }

    private func tableRowBackground(_ kind: TableRowKind) -> Color {
        switch kind {
        case .header: return secondaryColor.opacity(0.10)
        case .even:   return Color.clear
        case .odd:    return secondaryColor.opacity(0.045)
        }
    }

    /// Inline markdown (bold/italic/code/links) for a single block of text.
    /// Inline `code` spans get a tinted background + monospaced font; links use
    /// the accent color.
    private func inline(_ s: String) -> Text {
        guard var attr = try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return Text(s)
        }
        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = .system(size: Self.codeSize, weight: .medium, design: .monospaced)
                attr[run.range].foregroundColor = accent
                attr[run.range].backgroundColor = codeBackground
            }
            if run.link != nil {
                attr[run.range].foregroundColor = accent
                attr[run.range].underlineStyle = .single
            }
        }
        return Text(attr)
    }

    // MARK: Parsing

    struct Block: Identifiable {
        enum Kind {
            case heading(Int, String)
            case paragraph(String)
            case bullet([String])
            case ordered([String])
            case code(String, String?)
            case quote(String)
            case table([String], [[String]])
            case rule
        }
        let id = UUID()
        let kind: Kind
    }

    // MARK: - Parse cache

    /// LRU-style cache (NSCache manages memory under pressure automatically).
    /// Key: the raw Markdown string; value: parsed Block array boxed in a class.
    private final class BlockList { let blocks: [Block]; init(_ b: [Block]) { blocks = b } }
    private static let parseCache: NSCache<NSString, BlockList> = {
        let c = NSCache<NSString, BlockList>()
        c.countLimit = 64   // at most 64 distinct strings cached
        return c
    }()

    /// Returns the cached parse result when available, otherwise parses and caches.
    /// internal（非 private）：iOS 端文档预览（MarkdownPreviewView）复用同一 parser，
    /// 以获得 GFM 表格与 LRU 缓存；macOS 侧调用点与行为不变。
    static func parse(_ text: String) -> [Block] {
        let key = text as NSString
        if let cached = parseCache.object(forKey: key) { return cached.blocks }
        let result = _parse(text)
        parseCache.setObject(BlockList(result), forKey: key)
        return result
    }

    private static func _parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(Block(kind: .paragraph(paragraph.joined(separator: "\n"))))
                paragraph = []
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // consume closing fence
                blocks.append(Block(kind: .code(code.joined(separator: "\n"), lang.isEmpty ? nil : lang)))
                continue
            }

            // Heading.
            if let h = headingPrefix(line) {
                flushParagraph()
                blocks.append(Block(kind: .heading(h.level, h.text)))
                i += 1; continue
            }

            // Horizontal rule.
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(Block(kind: .rule))
                i += 1; continue
            }

            // GFM table: header row followed by a delimiter row.
            if line.contains("|"), i + 1 < lines.count,
               isTableDelimiter(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = splitTableRow(line)
                i += 2 // skip header + delimiter
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty || !l.contains("|") { break }
                    rows.append(splitTableRow(l))
                    i += 1
                }
                blocks.append(Block(kind: .table(header, rows)))
                continue
            }

            // Blockquote.
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(Block(kind: .quote(quote.joined(separator: "\n"))))
                continue
            }

            // Unordered list.
            if isBullet(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(bulletContent(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(Block(kind: .bullet(items)))
                continue
            }

            // Ordered list.
            if isOrdered(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(orderedContent(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(Block(kind: .ordered(items)))
                continue
            }

            // Blank line → paragraph boundary.
            if line.isEmpty {
                flushParagraph()
                i += 1; continue
            }

            paragraph.append(raw)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // internal（非 private）：文档诊断 DocumentDiagnostics 复用同一条 ATX 标题判定规则
    static func headingPrefix(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func bulletContent(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isOrdered(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: ".") else { return false }
        let num = line[line.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber) && line.index(after: dot) < line.endIndex
            && line[line.index(after: dot)] == " "
    }
    private static func orderedContent(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    /// A table delimiter row, e.g. `| --- | :--: | --: |`.
    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") else { return false }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            var body = c
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// Splits a table row into trimmed cells, dropping the outer pipes.
    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Code block

/// Fenced code block with an optional language label and a hover "copy" button.
private struct CodeBlockView: View {
    let code: String
    let lang: String?
    let textColor: Color
    let secondaryColor: Color
    let codeBackground: Color
    let accent: Color

    @State private var hovered = false
    @State private var copied = false

    private var hasHeader: Bool { (lang?.isEmpty == false) }
    // 触屏没有 hover：iOS 上代码块头部（语言标签 + 复制钮）常驻显示。
    private var showHeader: Bool {
        #if os(iOS)
        true
        #else
        hasHeader || hovered
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HStack {
                    if let lang, !lang.isEmpty {
                        Text(lang)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(secondaryColor)
                    }
                    Spacer(minLength: 0)
                    #if os(iOS)
                    let showCopy = true
                    #else
                    let showCopy = hovered || copied
                    #endif
                    if showCopy {
                        Button(action: copy) {
                            HStack(spacing: 3) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text(copied ? L("ai.copied") : L("ai.copy"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(copied ? accent : secondaryColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.top, 7)
                .padding(.bottom, 3)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: MarkdownText.codeSize, design: .monospaced))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.top, hasHeader ? 0 : 9)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(secondaryColor.opacity(0.16), lineWidth: 1)
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func copy() {
        Pasteboard.copy(code)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}
