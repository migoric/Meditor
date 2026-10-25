import Foundation

// MARK: - Outline Document

/// 标题树 + 行区间 + 字数。
///
/// 为什么不是「让 `read_document` 顺手给个目录」：大纲是**每轮都要重发**的东西，
/// 而 `read_document` 回来的是全文；混在一起等于每轮都为目录付全文的钱。
struct OutlineDocumentTool: AgentTool {
    let spec = AgentToolSpec(
        name: "outline_document",
        description: "List the section outline of a Markdown document: for each heading its `#n` ordinal, line range, body character count and level. Call this before editing a section instead of reading the whole document — then use read_section / rewrite_section with the `#n` shown here.",
        parameters: ToolParameterSchema(
            properties: [
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: []
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        let filename = arguments["filename"]?.stringValue
        switch try await AuthoringWrite.load(filename: filename, context: context) {
        case .message(let text):
            return text
        case .ok(let name, let content, _):
            let sections = MarkdownStructure.sections(in: content)
            guard !sections.isEmpty else {
                return "# \(name)\n\n（空文档，还没有任何内容）"
            }
            let heading = "# \(name)（\(sections.count) 节，\(content.count) 字）\n\n"
            let footer = "\n\nUse read_section(\"#n\") to read one section in full; "
                + "rewrite_section(\"#n\", newContent) replaces one section."
            return heading + MarkdownStructure.outline(content) + footer
        }
    }
}

// MARK: - Read Section

/// 按 `#n` / 标题 / 完整路径读**一节**。
struct ReadSectionTool: AgentTool {
    let spec = AgentToolSpec(
        name: "read_section",
        description: "Read one section of a Markdown document, addressed by `#n` (from outline_document), by heading text, or by full path like \"Design > Data model\". Cheaper and safer than re-reading the whole document.",
        parameters: ToolParameterSchema(
            properties: [
                "section":  ToolPropertySchema(type: "string", description: "Section reference: \"#3\", the heading text, or a full path \"Outer > Inner\"."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: ["section"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let query = arguments["section"]?.stringValue, !query.isEmpty else {
            throw AgentError.executionError("缺少 section 参数")
        }
        let filename = arguments["filename"]?.stringValue
        switch try await AuthoringWrite.load(filename: filename, context: context) {
        case .message(let text):
            return text
        case .ok(let name, let content, _):
            let section: MarkdownSection
            do {
                section = try MarkdownStructure.locate(query, in: content)
            } catch let error as MarkdownStructureError {
                return error.modelFacingMessage
            }
            let source = MarkdownStructure.source(of: section, in: content)
            // 回灌的是文件正文：与 read_document 同级净化后再进历史
            let (safe, flagged) = PromptInjectionSanitizer.sanitize(source)
            let header = "# \(name) · 第 #\(section.ordinal) 节（\(section.lineRange)，\(section.charCount) 字）\n\n"
            return PromptInjectionSanitizer.guardrailNote(flagged: flagged) + header + safe
        }
    }
}

// MARK: - Rewrite Section

/// 整节替换。
///
/// 典型收益：用户说「把第二节扩写到 800 字」。今天的做法是 `read_document`（全文进）→
/// 自己定位 → 构造完整新全文 → `write_document`（全文出）：改 50 个字付 6,300 字的钱，
/// 而且有丢别节内容的风险。这里进 200 出 800，结构上不可能碰到别的节。
struct RewriteSectionTool: AgentTool {
    let spec = AgentToolSpec(
        name: "rewrite_section",
        description: "Replace ONE section of a Markdown document. The section heading is preserved unless your content starts with its own heading line. Use this for \"expand/rewrite section X\"; use patch_document for small wording changes. Addressed by `#n` (from outline_document), heading text, or full path.",
        parameters: ToolParameterSchema(
            properties: [
                "section":  ToolPropertySchema(type: "string", description: "Section reference: \"#3\", the heading text, or a full path \"Outer > Inner\"."),
                "content":  ToolPropertySchema(type: "string", description: "New section body in Markdown (heading line optional)."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: ["section", "content"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let query = arguments["section"]?.stringValue, !query.isEmpty else {
            throw AgentError.executionError("缺少 section 参数")
        }
        guard let newBody = arguments["content"]?.stringValue else {
            throw AgentError.executionError("缺少 content 参数")
        }
        guard !newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "[!] content 为空。清空一节请明确说明用什么替换（rewrite_section 不接受空内容，避免静默删节）。"
        }
        let filename = arguments["filename"]?.stringValue

        let loaded = try await AuthoringWrite.load(filename: filename, context: context)
        let name: String
        let content: String
        let target: AuthoringWrite.Target
        switch loaded {
        case .message(let text): return text
        case .ok(let loadedName, let loadedContent, let loadedTarget):
            name = loadedName; content = loadedContent; target = loadedTarget
        }

        let section: MarkdownSection
        do {
            section = try MarkdownStructure.locate(query, in: content)
        } catch let error as MarkdownStructureError {
            return error.modelFacingMessage
        }

        let updated = MarkdownStructure.replacing(section, in: content, with: newBody)
        guard updated != content else {
            return "[!] 新内容与原文完全相同，未落盘。"
        }
        let summary = "改写 \(name) 第 #\(section.ordinal) 节「\(section.displayTitle(maxLength: 30))」"
            + "（原 \(section.lineRange)，新内容 \(newBody.count) 字符）"
        return try await AuthoringWrite.commit(updated, to: target, summary: summary, context: context)
    }
}
