import Foundation

// MARK: - AuthoringContextBuilder

/// 按档案构建「当前文档」这段上下文。
///
/// 纯函数：给定档案 + 文档快照 + 选区，返回要拼进 system prompt 的那段文本。
/// 单独抽出来的理由不是好看，而是**可断言**——「plain 档案的输出与旧实现逐字节相同」
/// 这条守卫（`AuthoringContextBuilderTests`）是整套分档的安全绳，靠人眼看是看不出来的。
enum AuthoringContextBuilder {

    struct Input: Sendable, Equatable {
        let name: String
        let content: String
        /// 已去首尾空白的选区文本（空串 = 无选区）。
        let selection: String
        /// 选区所在段落（段落不长于选区上限时才由调用方给）。
        let selectionParagraph: String?
        /// 1-based 光标行（plain 档案的预算截取要用）。
        let cursorLine: Int?

        init(name: String, content: String, selection: String = "",
             selectionParagraph: String? = nil, cursorLine: Int? = nil) {
            self.name = name
            self.content = content
            self.selection = selection
            self.selectionParagraph = selectionParagraph
            self.cursorLine = cursorLine
        }
    }

    /// 选区注入上限（与旧实现的硬编码保持一致）。
    static let selectionLimit = 4000

    /// 短文档仍然给全文：一篇 200 字的笔记，全套「大纲 + read_section」是一条
    /// 往返换 200 token——往返本身（模型思考 + 一次工具结果）比省下的 token 贵得多。
    /// 分档的收益只在长文档上成立，这里按 token 估算卡一道门槛。
    static let fullTextThresholdTokens = 500

    static func context(for profile: DocumentAuthoringProfile,
                        input: Input,
                        includeFullDocument: Bool) -> String {
        switch profile.kind {
        case .plain:    return plainContext(input: input, includeFullDocument: includeFullDocument)
        case .markdown: return markdownContext(input: input, includeFullDocument: includeFullDocument)
        case .html:     return htmlContext(input: input, includeFullDocument: includeFullDocument)
        }
    }

    // MARK: plain（旧行为，逐字节不变）

    private static func plainContext(input: Input, includeFullDocument: Bool) -> String {
        if !input.selection.isEmpty {
            var ctx = selectionBlock(input: input)
            if let para = input.selectionParagraph,
               para.count > input.selection.count, para.count <= selectionLimit {
                ctx += "\n\nThe selection is part of this paragraph in \"\(input.name)\":\n\n\(para)"
            }
            return ctx
        }
        if includeFullDocument {
            let body = DocumentContextExcerpt.excerpt(content: input.content, cursorLine: input.cursorLine)
            return "\n\nThe current document is \"\(input.name)\":\n\n\(body)"
        }
        return "\n\nThe user is editing a document named \"\(input.name)\"."
    }

    // MARK: markdown

    private static func markdownContext(input: Input, includeFullDocument: Bool) -> String {
        if !input.selection.isEmpty {
            var ctx = selectionBlock(input: input)
            if let section = MarkdownStructure.section(containing: input.selection, in: input.content) {
                ctx += "\n\nThe selection is in section #\(section.ordinal) 「\(section.displayTitle())」"
                    + "（\(section.lineRange)）。"
            }
            if let para = input.selectionParagraph,
               para.count > input.selection.count, para.count <= selectionLimit {
                ctx += "\n\nThe selection is part of this paragraph in \"\(input.name)\":\n\n\(para)"
            }
            return ctx
        }

        let sections = MarkdownStructure.sections(in: input.content)
        guard includeFullDocument else {
            return "\n\nThe user is editing a Markdown document named \"\(input.name)\""
                + "（\(sections.count) 节）。它的大纲在更早的上下文里；需要时用 outline_document 重新取。"
        }
        guard !sections.isEmpty else {
            return "\n\nThe current document \"\(input.name)\" is empty. Write into it with write_document,"
                + " or append with insert_at_cursor."
        }
        // 短文档直接给全文：为「先读一节」多付一次往返不划算
        if AIConversation.estimateTokens(input.content) <= fullTextThresholdTokens {
            return "\n\nThe current document is \"\(input.name)\"（\(sections.count) 节，全文如下）：\n\n"
                + input.content
        }
        return """

        The current document is "\(input.name)"（\(sections.count) 节，约 \(input.content.count) 字）。
        Below is its **outline**, not the full text. Read a section with `read_section("#n")` before rewriting it;
        replace one section with `rewrite_section("#n", newContent)`.

        \(MarkdownStructure.outline(input.content))
        """
    }

    // MARK: html

    private static func htmlContext(input: Input, includeFullDocument: Bool) -> String {
        if !input.selection.isEmpty {
            var ctx = selectionBlock(input: input)
            if let para = input.selectionParagraph,
               para.count > input.selection.count, para.count <= selectionLimit {
                ctx += "\n\nThe selection is part of this paragraph in \"\(input.name)\":\n\n\(para)"
            }
            return ctx
        }

        let document = HTMLScanner.scan(input.content)
        guard includeFullDocument else {
            return "\n\nThe user is editing an HTML document named \"\(input.name)\""
                + "（\(document.elements.count) 个元素，\(document.foldedStyleNotice)）。"
                + "它的结构树在更早的上下文里；需要时用 html_outline 重新取。"
        }
        guard !document.isEmpty else {
            return "\n\nThe current document \"\(input.name)\" is empty. Create it with"
                + " `write_html_with_template(template:body:)` — do not hand-copy a template."
        }
        return """

        The current document is "\(input.name)"（\(document.elements.count) 个元素）。
        Styles: \(document.foldedStyleNotice)。正文与 CSS 都不在上下文里——
        use `read_node("<selector>")` for a node, `patch_document` / `read_node`+rewrite for text,
        `patch_style` to append CSS rules, and only call `read_style` when the user actually asks about styling.

        \(document.outline())
        """
    }

    // MARK: 公共片段

    private static func selectionBlock(input: Input) -> String {
        let selected = input.selection.count > selectionLimit
            ? String(input.selection.prefix(selectionLimit)) + "…"
            : input.selection
        return "\n\nThe user selected this text in \"\(input.name)\":\n\n\(selected)"
    }
}
