import Foundation

// MARK: - Insert At Cursor

struct InsertAtCursorTool: AgentTool {
    // iOS 的 SwiftUI TextEditor 拿不到光标，insertIntoDocument 实际是追加到末尾，
    // 文案必须与行为一致，否则模型会预期插到光标处。
    //
    // 描述里刻意不再写「加新内容优先用我」：那句话会把「往文档里加一段」这个最常见的
    // 请求主动引到本工具上，而本工具没有 diff 形态（拿不到插入后全文），只能给确认条；
    // 要改文档的既有内容应该走 patch_document（局部）/ write_document（全量）。
    #if os(iOS)
    private static let toolDescription = "Append text to the end of the current document. Use only when the user wants to append; to change existing content use patch_document (partial edit) or write_document (full rewrite)."
    #else
    private static let toolDescription = "Insert text at the current cursor position in the editor. Use only when the user explicitly asks to insert at the cursor; to change existing content use patch_document (partial edit) or write_document (full rewrite)."
    #endif

    let spec = AgentToolSpec(
        name: "insert_at_cursor",
        description: InsertAtCursorTool.toolDescription,
        parameters: ToolParameterSchema(
            properties: [
                "text": ToolPropertySchema(type: "string", description: "The Markdown text to insert at the cursor.")
            ],
            required: ["text"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let text = arguments["text"]?.stringValue else {
            throw AgentError.executionError("缺少 text 参数")
        }
        // 插入同样修改用户内容：与 patch_document / write_document 同级走写前确认。
        // 这里给不了 diff——插入点由编辑器光标决定，工具拿不到「插入后全文」，
        // 所以 base 走 .unavailable（确认条只显示目标 + 摘要，不进全屏审阅）。
        if !(await context.isFileWriteAllowedForRun) {
            let docName = await context.currentDocumentName ?? "当前文档"
            let preview = WriteDiffPreviewBuilder.make(
                path: docName,
                summary: "在 \(docName) 插入 \(text.count) 字符：\(Self.snippet(text))",
                base: .unavailable,
                newContent: text)
            guard await context.confirmFileWrite(preview) else {
                return "[!] 用户已拒绝插入：\(docName)（未改动）"
            }
        }
        await context.insertIntoDocument(text)
        return "[OK] 内容已插入（\(text.count) 字符）"
    }

    /// 确认条上的一句话预览：压成单行并截断，避免长文本把确认条撑高。
    static func snippet(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }
}

// MARK: - Open File

struct OpenFileTool: AgentTool {
    let spec = AgentToolSpec(
        name: "open_file",
        description: "Open a file in the editor AND return its full content. Accepts a filename (e.g. 'README.md'), a workspace-relative path (e.g. 'docs/intro.md'), or an absolute path. The file must exist.",
        parameters: ToolParameterSchema(
            properties: [
                "filename": ToolPropertySchema(type: "string", description: "Filename, relative path from workspace root, or absolute path of the file to open.")
            ],
            required: ["filename"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let filename = arguments["filename"]?.stringValue else {
            throw AgentError.executionError("缺少 filename 参数")
        }
        let opened = await context.openFile(named: filename)
        guard opened else {
            // false 有两种含义：不存在，或存在但超过打开上限（TabManager 会
            // 向用户弹体积错误）。报「未找到」会误导模型放弃或走 read_file
            // 绕路，先区分再报。
            if await context.resolveExistingFile(filename) != nil {
                return "[!] 文件存在但超过编辑器的打开体积上限：\(filename)。"
                    + "请不要尝试 read_file 全量读取，改用 search_workspace 定位相关段落。"
            }
            return "[!] 未找到文件：\(filename)"
        }
        // 编辑器内容是异步加载的，open 之后 selectedTab.content 仍可能为空，
        // 因此这里直接从磁盘读回内容一并返回，避免 agent 误以为"已看到内容"而产生幻觉。
        if let url = await context.resolveExistingFile(filename),
           let content = try? await context.readFile(at: url) {
            // 与 read_file 同级净化：open_file 同样把文件内容回灌给模型，
            // 不能成为绕过注入防护的旁路。
            let (safeContent, flagged) = PromptInjectionSanitizer.sanitize(content)
            return "[OK] 已在编辑器中打开：\(filename)\n\n"
                + PromptInjectionSanitizer.guardrailNote(flagged: flagged)
                + "# \(filename)\n\n\(safeContent)"
        }
        return "[OK] 已在编辑器中打开：\(filename)"
    }
}

// MARK: - Get HTML Template

struct GetHTMLTemplateTool: AgentTool {
    let spec = AgentToolSpec(
        name: "get_html_template",
        description: "Get MEditor's built-in HTML document template (a complete HTML document with inlined <style>). Call this first when creating or restyling an HTML file, and use the returned template as the base — do not invent your own CSS or strip the template's styles. Styles: 'doc' (default — styled document), 'craft' (modern cards), 'tufte' (serif academic), 'dark' (dark code style).",
        parameters: ToolParameterSchema(
            properties: [
                "style": ToolPropertySchema(type: "string", description: "Template style: doc | craft | tufte | dark. Default: doc.")
            ],
            required: []
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        let style = (arguments["style"]?.stringValue ?? "doc").lowercased()
        let id: String
        switch style {
        case "craft": id = "html-craft"
        case "tufte": id = "html-tufte"
        case "dark":  id = "html-dark"
        default:       id = "html-doc"
        }
        let content = await MainActor.run { TemplateStore.builtins.first { $0.id == id }?.content }
        guard let content, !content.isEmpty else {
            return "未找到 HTML 模板：\(style)（可用：doc / craft / tufte / dark）"
        }
        return "# MEditor 内建 HTML 模板（\(style)）\n\n用它作为基底，保留其 <style> 与结构，把用户内容填进去：\n\n```html\n\(content)\n```"
    }
}
