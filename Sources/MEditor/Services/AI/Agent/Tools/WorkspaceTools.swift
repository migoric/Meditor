import Foundation

// MARK: - List Files

struct ListFilesTool: AgentTool {
    let spec = AgentToolSpec(
        name: "list_files",
        description: "List all Markdown and text files in the current workspace.",
        parameters: ToolParameterSchema(
            properties: [
                "extension": ToolPropertySchema(type: "string", description: "File extension filter, e.g. 'md', 'txt'. Leave empty for all text files.")
            ],
            required: []
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard await context.workspaceURL != nil else { throw AgentError.noWorkspace }
        let ext  = arguments["extension"]?.stringValue ?? ""
        let exts = ext.isEmpty ? ["md", "txt", "markdown"] : [ext.lowercased()]
        let files = await context.listWorkspaceFiles(extensions: exts)
        if files.isEmpty { return "工作区没有找到文件" }
        let root  = await context.workspaceURL?.path ?? ""
        let names = files.map { url -> String in
            let rel = url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count + 1)) : url.lastPathComponent
            return "- \(rel)"
        }
        return "工作区文件（\(files.count) 个）：\n\n" + names.prefix(50).joined(separator: "\n")
    }
}

// MARK: - Read File

struct ReadFileTool: AgentTool {
    let spec = AgentToolSpec(
        name: "read_file",
        description: "Read the content of a file in the workspace by filename. Large files are automatically truncated.",
        parameters: ToolParameterSchema(
            properties: [
                "filename": ToolPropertySchema(type: "string", description: "The filename to read (e.g. README.md). Searches recursively in the workspace.")
            ],
            required: ["filename"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let filename = arguments["filename"]?.stringValue else {
            throw AgentError.executionError("缺少 filename 参数")
        }
        // 统一路径解析：支持文件名、工作区相对路径（如 test111/index.html）、绝对路径
        let resolved = await context.resolveFile(filename)
        guard case .found(let url) = resolved else {
            if let message = resolved.promptMessage(forQuery: filename) {
                return message
            }
            return "未找到文件：\(filename)"
        }
        let content = try await context.readFile(at: url)
        // 提示注入轻净化（与 @mention 同一防护级别）：命中行降级 + 边界声明
        let (safeContent, flagged) = PromptInjectionSanitizer.sanitize(content)
        return PromptInjectionSanitizer.guardrailNote(flagged: flagged) + "# \(filename)\n\n\(safeContent)"
    }
}

// MARK: - Create File

struct CreateFileTool: AgentTool {
    let spec = AgentToolSpec(
        name: "create_file",
        description: "Create a new file. Fails if the file already exists — use write_file to overwrite. Accepts both absolute paths and relative paths from the workspace root. This is the tool to use when asked to create a file.",
        parameters: ToolParameterSchema(
            properties: [
                "content":  ToolPropertySchema(type: "string", description: "Initial Markdown content (optional, default: empty)."),
                "filename": ToolPropertySchema(type: "string", description: "Filename or path, e.g. 'notes.md' or 'docs/intro.md'.")
            ],
            required: ["filename"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let filename = arguments["filename"]?.stringValue else {
            throw AgentError.executionError("缺少 filename 参数")
        }
        let content = arguments["content"]?.stringValue ?? ""
        // 写入前确认：本 run 已免确认（全部允许 / autoApprove 白名单命中）则直接放行，
        // 否则挂起等用户在确认条上决定
        if !(await context.isFileWritePreApproved(path: filename)) {
            let lines = content.components(separatedBy: "\n").count
            // 新建文件：diff = 纯新增（写前内容为空）
            let preview = WriteDiffPreviewBuilder.make(
                path: filename, summary: "新建 \(filename)（约 \(lines) 行）",
                base: .newFile, newContent: content)
            let approved = await context.confirmFileWrite(preview)
            guard approved else { return "[!] 用户已拒绝写入：\(filename)" }
        }
        do {
            let url = try await context.createFile(name: filename, content: content)
            return "[OK] 已创建文件：\(url.lastPathComponent)（\(content.count) 字符）"
        } catch AgentContextError.fileAlreadyExists(let name) {
            return "[!] 文件已存在：\(name)，如需覆盖请用 write_file"
        }
    }
}

// MARK: - Write File

struct WriteFileTool: AgentTool {
    let spec = AgentToolSpec(
        name: "write_file",
        description: "Create or overwrite a file. Accepts both absolute paths and relative paths from the workspace root. This is the tool to use when asked to write a file.",
        parameters: ToolParameterSchema(
            properties: [
                "content":  ToolPropertySchema(type: "string", description: "The content to write."),
                "filename": ToolPropertySchema(type: "string", description: "Filename or path, e.g. 'notes.md' or 'docs/intro.md'.")
            ],
            required: ["filename", "content"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let filename = arguments["filename"]?.stringValue,
              let content  = arguments["content"]?.stringValue
        else { throw AgentError.executionError("缺少 filename 或 content 参数") }
        // 写入前确认：本 run 已免确认（全部允许 / autoApprove 白名单命中）则直接放行，
        // 否则挂起等用户在确认条上决定
        if !(await context.isFileWritePreApproved(path: filename)) {
            let lines = content.components(separatedBy: "\n").count
            // diff 预览：已存在文件取写前内容（fileContentFull = tab 内存优先），新文件按纯新增
            let base: WriteBaseContent
            if case .found(let url) = await context.resolveFile(filename) {
                base = (try? await context.fileContentFull(at: url))
                    .map { .existing($0) } ?? .unavailable
            } else {
                base = .newFile
            }
            let preview = WriteDiffPreviewBuilder.make(
                path: filename, summary: "写入 \(filename)（约 \(lines) 行）",
                base: base, newContent: content)
            let approved = await context.confirmFileWrite(preview)
            guard approved else { return "[!] 用户已拒绝写入：\(filename)" }
        }
        let url = try await context.writeFile(name: filename, content: content)
        return "[OK] 已写入文件：\(url.lastPathComponent)（\(content.count) 字符）"
    }
}

// MARK: - Create Directory

struct CreateDirectoryTool: AgentTool {
    let spec = AgentToolSpec(
        name: "create_directory",
        description: "Create a directory (and any missing parent directories). Accepts both absolute paths and relative paths from workspace root. This is the tool to use when the user asks to create a directory — do not refuse or ask the user to run a terminal command.",
        parameters: ToolParameterSchema(
            properties: [
                "path": ToolPropertySchema(type: "string", description: "Directory path to create. Absolute (e.g. '/Users/john/project/test') or relative (e.g. 'docs/api').")
            ],
            required: ["path"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            throw AgentError.executionError("缺少 path 参数")
        }
        // 不拦确认：创建空目录不覆盖任何用户内容，风险与收益不对等；
        // 真正写入内容的 create_file / write_file 会各自确认
        let url = try await context.createDirectory(name: path)
        return "[OK] 已创建目录：\(url.path)"
    }
}

// MARK: - Search Workspace

struct SearchWorkspaceTool: AgentTool {
    let spec = AgentToolSpec(
        name: "search_workspace",
        description: "Search for a keyword across all files in the workspace. Returns matching lines with file path and line number.",
        parameters: ToolParameterSchema(
            properties: [
                "extension": ToolPropertySchema(type: "string", description: "Limit search to files with this extension, e.g. 'md'. Leave empty for md/txt/markdown."),
                "query":     ToolPropertySchema(type: "string", description: "The keyword or phrase to search for (case-insensitive).")
            ],
            required: ["query"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let query = arguments["query"]?.stringValue else {
            throw AgentError.executionError("缺少 query 参数")
        }
        guard await context.workspaceURL != nil else { throw AgentError.noWorkspace }
        let ext  = arguments["extension"]?.stringValue ?? ""
        let exts = ext.isEmpty ? ["md", "txt", "markdown"] : [ext.lowercased()]
        let results = await context.searchWorkspace(query: query, extensions: exts)
        if results.isEmpty { return "在工作区中未找到包含「\(query)」的内容" }
        return "找到 \(results.count) 处匹配：\n\n" + results.joined(separator: "\n")
    }
}
