import Foundation

// MARK: - Insert At Cursor

struct InsertAtCursorTool: AgentTool {
    // iOS 的 SwiftUI TextEditor 拿不到光标，insertIntoDocument 实际是追加到末尾，
    // 文案必须与行为一致，否则模型会预期插到光标处。
    #if os(iOS)
    private static let toolDescription = "Append text to the end of the current document. Prefer this over write_document when adding new content rather than replacing."
    #else
    private static let toolDescription = "Insert text at the current cursor position in the editor. Prefer this over write_document when adding new content rather than replacing."
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
        await context.insertIntoDocument(text)
        return "[OK] 内容已插入（\(text.count) 字符）"
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
        guard opened else { return "[!] 未找到文件：\(filename)" }
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
