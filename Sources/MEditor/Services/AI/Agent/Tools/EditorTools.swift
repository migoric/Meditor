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

/// 模板「查看」工具。
///
/// 自 0.13.9 起**创建/改版 HTML 不再用它**——用 `write_html_with_template` 只写语义
/// body，模板由宿主展开（模板的 2,699 token 不进历史，也不会被模型逐字抄错）。
/// 保留这个工具只为「用户想看模板长什么样」和它自带模板库的完整清单。
struct GetHTMLTemplateTool: AgentTool {
    let spec = AgentToolSpec(
        name: "get_html_template",
        description: "View MEditor's built-in HTML template source (a complete HTML document with inlined <style>). ONLY for showing the template to the user. To create or restyle an HTML file use write_html_with_template(template:body:) instead — copying this template by hand wastes ~2.7K tokens per call and tends to break the layout.",
        parameters: ToolParameterSchema(
            properties: [
                "style": ToolPropertySchema(type: "string", description: "Template style: doc | craft | tufte | dark | landing | report | resume. Default: doc.")
            ],
            required: []
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        let style = arguments["style"]?.stringValue ?? "doc"
        let names = await BuiltinHTMLTemplates.availableNames()
        guard let template = await BuiltinHTMLTemplates.content(for: style) else {
            return "未找到 HTML 模板：\(style)（可用：\(names.joined(separator: " / "))）"
        }
        return "# MEditor 内建 HTML 模板（\(template.id)）\n\n仅供查看。新建/改版请用 write_html_with_template(template:body:)：\n\n```html\n\(template.content)\n```"
    }
}

// MARK: - 内建 HTML 模板解析

/// 模板名 → 内建模板。工具与 `get_html_template` 共用这一份映射，避免两处漂移。
enum BuiltinHTMLTemplates {

    /// 接受 `doc` / `html-doc` / `craft` / `report` 等写法，规范成内建 id 候选。纯函数。
    static func candidateID(for name: String) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        return cleaned.hasPrefix("html-") ? cleaned : "html-" + cleaned
    }

    /// 只在主线程取（`TemplateStore.builtins` 读 Bundle + 本地化）；跨 actor 只传字符串。
    static func content(for name: String) async -> (id: String, content: String)? {
        guard let candidate = candidateID(for: name) else { return nil }
        return await MainActor.run {
            guard let template = TemplateStore.builtins.first(where: { $0.id == candidate }) else { return nil }
            return (template.id, template.content)
        }
    }

    /// 可用的模板名（错误文案里列给模型）。
    static func availableNames() async -> [String] {
        await MainActor.run {
            TemplateStore.builtins
                .filter { $0.id.hasPrefix("html-") }
                .map { String($0.id.dropFirst(5)) }
        }
    }
}
