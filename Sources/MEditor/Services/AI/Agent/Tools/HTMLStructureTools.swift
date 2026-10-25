import Foundation

// 内建模板的 id 解析在 EditorTools.swift（与 get_html_template 同一份映射，
// 那个文件是 iOS 共享文件，映射放在那里才能被两端复用）。

// MARK: - HTML Outline

struct HTMLOutlineTool: AgentTool {
    let spec = AgentToolSpec(
        name: "html_outline",
        description: "List the structure tree of an HTML document: containers (tag#id.class, with li / tr counts) and headings with their text. CSS is NOT included — use read_style only if the user asks about styling. Call this instead of read_document to locate a node, then read_node(\"<selector>\").",
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
            let document = HTMLScanner.scan(content)
            guard !document.isEmpty else { return "# \(name)\n\n（空文档，还没有任何元素）" }
            let header = "# \(name)（\(document.elements.count) 个元素；\(document.foldedStyleNotice)）\n\n"
            return header + document.outline()
        }
    }
}

// MARK: - Read Node

struct ReadNodeTool: AgentTool {
    /// 单次返回上限：一个 `<section>` 可能就有几千字符，整段进历史后每轮重发。
    private static let maxChars = 8000

    let spec = AgentToolSpec(
        name: "read_node",
        description: "Read one element of an HTML document by selector: `#id`, `.class`, `tag`, `tag#id`, `tag.class`, optionally with `:nth(n)` for the n-th match. Returns the element's outerHTML (truncated). Use html_outline first to find the selector.",
        parameters: ToolParameterSchema(
            properties: [
                "selector": ToolPropertySchema(type: "string", description: "Selector such as \"#summary\", \"section.data\", \"table:nth(2)\"."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: ["selector"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let selector = arguments["selector"]?.stringValue, !selector.isEmpty else {
            throw AgentError.executionError("缺少 selector 参数")
        }
        let filename = arguments["filename"]?.stringValue
        switch try await AuthoringWrite.load(filename: filename, context: context) {
        case .message(let text):
            return text
        case .ok(let name, let content, _):
            let document = HTMLScanner.scan(content)
            let hits = document.matchIndices(selector: selector)
            guard let first = hits.first else {
                let candidates = document.elements
                    .filter { HTMLDocument.isStructural($0) || HTMLDocument.headingTags.contains($0.name) }
                    .prefix(20)
                    .map(\.label)
                    .joined(separator: "、")
                return "[!] 没有元素匹配「\(selector)」。可用：\(candidates.isEmpty ? "（文档里没有结构性元素）" : candidates)"
            }
            let element = document.elements[first]
            let html = document.slice(element.startOffset..<element.endOffset)
            let (safe, flagged) = PromptInjectionSanitizer.sanitize(html)
            let body = safe.count > Self.maxChars
                ? String(safe.prefix(Self.maxChars)) + "\n…（已截断至前 \(Self.maxChars) 字符）"
                : safe
            var header = "# \(name) · \(element.label)（\(html.count) 字符）\n\n"
            if hits.count > 1 {
                header += "> 匹配到 \(hits.count) 个元素，返回的是第 1 个："
                    + hits.prefix(5).map { document.elements[$0].label }.joined(separator: "、")
                    + "。需要别的请用 `:nth(n)` 或更精确的选择器。\n\n"
            }
            return PromptInjectionSanitizer.guardrailNote(flagged: flagged) + header + body
        }
    }
}

// MARK: - Read Style

struct ReadStyleTool: AgentTool {
    let spec = AgentToolSpec(
        name: "read_style",
        description: "Read the CSS inside all <style> blocks of an HTML document. This is expensive (often 1.5K+ tokens) — only call it when the user asks about styling. To ADD rules use patch_style instead of reading first.",
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
            let document = HTMLScanner.scan(content)
            guard !document.styleRanges.isEmpty else {
                return "# \(name)\n\n（无独立 <style> 块：样式可能在外部链接或内联 style 属性里）"
            }
            let css = document.styleText
            let (safe, flagged) = PromptInjectionSanitizer.sanitize(css)
            let header = "# \(name) · CSS（\(document.styleRanges.count) 个 <style> 块，约 \(document.styleTokenEstimate) token）\n\n"
            return PromptInjectionSanitizer.guardrailNote(flagged: flagged) + header + safe
        }
    }
}

// MARK: - Patch Style

struct PatchStyleTool: AgentTool {
    let spec = AgentToolSpec(
        name: "patch_style",
        description: "Append CSS rules to an HTML document's <style> block (CSS cascade: later rules win). Use this to change styling instead of rewriting the document. The rules are appended verbatim — include full selectors and braces.",
        parameters: ToolParameterSchema(
            properties: [
                "css":      ToolPropertySchema(type: "string", description: "CSS rules to append, e.g. \"h2 { color: #0f766e; }\""),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: ["css"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let css = arguments["css"]?.stringValue,
              !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.executionError("缺少 css 参数")
        }
        let filename = arguments["filename"]?.stringValue

        let loaded = try await AuthoringWrite.load(filename: filename, context: context)
        let name: String
        let content: String
        let target: AuthoringWrite.Target
        switch loaded {
        case .message(let text): return text
        case .ok(let n, let c, let t): name = n; content = c; target = t
        }

        let document = HTMLScanner.scan(content)
        var chars = document.source
        let rule = css.hasSuffix("\n") ? css : css + "\n"
        if let lastStyle = document.styleRanges.last {
            chars.insert(contentsOf: Array("\n" + rule), at: lastStyle.upperBound)
        } else if let headClose = HTMLScanner.find(chars, from: 0, token: "</head>") {
            chars.insert(contentsOf: Array("<style>\n" + rule + "</style>\n"), at: headClose)
        } else if let bodyClose = HTMLScanner.find(chars, from: 0, token: "</body>") {
            chars.insert(contentsOf: Array("<style>\n" + rule + "</style>\n"), at: bodyClose)
        } else {
            return "[!] 这份文档既没有 <style> 块也没有 </head></body>，无法追加 CSS。"
                + "新建文档请用 write_html_with_template（样式由模板提供）。"
        }

        let summary = "在 \(name) 追加 CSS 规则（\(rule.count) 字符）"
        return try await AuthoringWrite.commit(String(chars), to: target, summary: summary, context: context)
    }
}

// MARK: - Set Node Class

struct SetNodeClassTool: AgentTool {
    let spec = AgentToolSpec(
        name: "set_node_class",
        description: "Replace the class attribute of exactly ONE element (addressed by selector). Use this to restyle an element without touching its text. The selector must match a single element — narrow it with `#id` or `tag.class`.",
        parameters: ToolParameterSchema(
            properties: [
                "selector": ToolPropertySchema(type: "string", description: "Selector matching exactly one element, e.g. \"#summary\" or \"section.intro\"."),
                "class":    ToolPropertySchema(type: "string", description: "New class list, space separated. Empty string clears the class attribute."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit for the currently active document.")
            ],
            required: ["selector", "class"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let selector = arguments["selector"]?.stringValue, !selector.isEmpty else {
            throw AgentError.executionError("缺少 selector 参数")
        }
        guard let newClass = arguments["class"]?.stringValue else {
            throw AgentError.executionError("缺少 class 参数")
        }
        let filename = arguments["filename"]?.stringValue

        let loaded = try await AuthoringWrite.load(filename: filename, context: context)
        let name: String
        let content: String
        let target: AuthoringWrite.Target
        switch loaded {
        case .message(let text): return text
        case .ok(let n, let c, let t): name = n; content = c; target = t
        }

        let document = HTMLScanner.scan(content)
        let hits = document.matchIndices(selector: selector)
        guard let index = hits.first else {
            return "[!] 没有元素匹配「\(selector)」。先用 html_outline 看结构树。"
        }
        guard hits.count == 1 else {
            let labels = hits.prefix(5).map { document.elements[$0].label }.joined(separator: "、")
            return "[!] 「\(selector)」匹配到 \(hits.count) 个元素（\(labels)），换 class 必须精确到一个。请用 `#id` 或 `tag.class` 收窄。"
        }

        let element = document.elements[index]
        var chars = document.source
        if let valueRange = element.attributeValueRanges["class"] {
            chars.replaceSubrange(valueRange, with: Array(newClass))
        } else if newClass.isEmpty {
            return "[!] 该元素本来就没有 class 属性，无需清空。"
        } else {
            let insertAt = element.startOffset + 1 + element.name.count
            chars.insert(contentsOf: Array(" class=\"\(newClass)\""), at: insertAt)
        }

        let summary = "把 \(name) 的 \(element.label) class 改为「\(newClass)」"
        return try await AuthoringWrite.commit(String(chars), to: target, summary: summary, context: context)
    }
}

// MARK: - Write HTML With Template

/// 模板引用式写入：模型只写语义 body，模板与 `<style>` 由宿主展开。
struct WriteHTMLWithTemplateTool: AgentTool {
    let spec = AgentToolSpec(
        name: "write_html_with_template",
        description: "Create or rewrite an HTML document from a built-in template: you supply only the semantic body (e.g. \"<section id=\\\"intro\\\"><h2>…</h2></section>\"), the host fills it into the template's <main> and regenerates the sidebar navigation from your sections/headings. The template's CSS never enters the conversation. Templates: doc (default), craft, tufte, dark, landing, report, resume. Body must not contain <style> or <link rel=stylesheet> — use patch_style for style changes.",
        parameters: ToolParameterSchema(
            properties: [
                "body":     ToolPropertySchema(type: "string", description: "Semantic HTML body. Prefer <section id=\"…\"> blocks; the sidebar nav is generated from them."),
                "template": ToolPropertySchema(type: "string", description: "Template name: doc | craft | tufte | dark | landing | report | resume. Default: doc."),
                "title":    ToolPropertySchema(type: "string", description: "Optional. Replaces the document <title>."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit to write the currently active document.")
            ],
            required: ["body"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let body = arguments["body"]?.stringValue,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.executionError("缺少 body 参数")
        }
        let style = arguments["template"]?.stringValue ?? "doc"
        let title = arguments["title"]?.stringValue
        let filename = arguments["filename"]?.stringValue

        guard let template = await BuiltinHTMLTemplates.content(for: style) else {
            let names = await BuiltinHTMLTemplates.availableNames()
            return "[!] 没有这个模板：\(style)。可用：\(names.joined(separator: " / "))"
        }
        let assembled: String
        do {
            assembled = try HTMLTemplateAssembly.assemble(
                template: template.content, title: title, body: body)
        } catch let failure as HTMLTemplateAssembly.Failure {
            return failure.modelFacingMessage
        }

        // 新建文件是正常情形：不走 load()（它把「文件不存在」当失败），
        // 让 commit 走 .file 分支——写前审阅对不存在的文件按「纯新增」处理。
        let name: String
        let target: AuthoringWrite.Target
        if let filename, !filename.isEmpty {
            let resolved = await context.resolveFile(filename)
            switch resolved {
            case .found(let url):
                name = url.lastPathComponent
                target = .file(url.path)
            case .ambiguous:
                return resolved.promptMessage(forQuery: filename) ?? "[!] 文件名有歧义：\(filename)"
            case .notFound:
                name = filename
                target = .file(filename)
            }
        } else {
            guard await context.currentDocument != nil else {
                return "[!] 当前没有打开的文档。请给一个 filename 新建文件，或先 open_file。"
            }
            name = await context.currentDocumentName ?? "untitled.html"
            target = .currentDocument(name: name, tabID: await context.currentTabID)
        }

        let summary = "用 \(template.id) 模板生成 \(name)（含模板样式，约 \(assembled.count) 字符）"
        let result = try await AuthoringWrite.commit(
            assembled, to: target, summary: summary, context: context)
        return result
    }
}
