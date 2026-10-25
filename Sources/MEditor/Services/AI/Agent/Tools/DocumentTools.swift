import Foundation

// 说明：以下四个 "*_document" 工具均支持可选的 `filename` 参数。
//   - 不传 filename → 作用于当前激活的编辑器文档（selectedTab）。
//   - 传 filename   → 直接作用于指定文件（文件名 / 工作区相对路径 / 绝对路径），
//                     无需先 open_file 激活 tab。

// 写回「当前文档」前的 tab 锁定校验统一放在 AuthoringWrite（结构化工具有同一份需求，
// 复制两遍迟早走形）。

// MARK: - AuthoringWrite

/// 结构化工具有一个统一的读写入口。
///
/// 存在的理由：`rewrite_section` / `patch_style` / `set_node_class` /
/// `write_html_with_template` 都要做同一件事——「取当前内容 → 改一段 → 走审阅 → 落盘」。
/// 这几步里最容易漏的是**审阅**与**tab 锁定**，各复制一遍必然走形（历史上 iOS 就因为
/// 某条写入路径漏了确认，AI 可以静默改文件）。所以只剩这一份。
enum AuthoringWrite {

    enum Target: Sendable, Equatable {
        /// 当前激活的编辑器文档：写入走 `writeDocument`，并且必须在写前校验 tab 没被切走。
        case currentDocument(name: String, tabID: UUID?)
        /// 磁盘上的具体文件：写入走 `writeFile`。
        case file(String)
    }

    enum Loaded: Sendable {
        case ok(name: String, content: String, target: Target)
        /// 直接回灌给模型的文案（找不到文件 / 没有激活文档等）。
        case message(String)
    }

    /// 读目标文档。**当前 tab 优先用内存内容**（与 `patch_document` 一致）——
    /// 用磁盘内容会把用户还没保存的编辑覆盖掉。
    static func load(filename: String?, context: any AgentContextProtocol) async throws -> Loaded {
        if let filename, !filename.isEmpty {
            let resolved = await context.resolveFile(filename)
            guard case .found(let url) = resolved else {
                if let message = resolved.promptMessage(forQuery: filename) { return .message(message) }
                return .message("未找到文件：\(filename)")
            }
            do {
                let content = try await context.fileContentFull(at: url)
                return .ok(name: url.lastPathComponent, content: content, target: .file(url.path))
            } catch {
                return .message("[!] 读取 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
            }
        }
        guard let content = await context.currentDocument else {
            return .message("[!] 当前没有打开的文档。请先 open_file，或给工具传 filename。")
        }
        let name = await context.currentDocumentName ?? "untitled"
        let tabID = await context.currentTabID
        return .ok(name: name, content: content, target: .currentDocument(name: name, tabID: tabID))
    }

    /// 审阅后落盘。返回给模型的 `[OK]` / `[!]` 文案。
    static func commit(_ content: String,
                       to target: Target,
                       summary: String,
                       context: any AgentContextProtocol) async throws -> String {
        switch target {
        case .file(let path):
            var finalContent = content
            if !(await context.isFileWritePreApproved(path: path)) {
                let base: WriteBaseContent
                if let old = try? await context.fileContentFull(at: URL(fileURLWithPath: path)) {
                    base = .existing(old)
                } else {
                    base = .newFile
                }
                let preview = WriteDiffPreviewBuilder.make(
                    path: path, summary: summary, base: base, newContent: content)
                guard let merged = await context.reviewFileWrite(preview, base: base, newContent: content) else {
                    return "[!] 用户已拒绝写入：\(path)（未落盘）"
                }
                finalContent = merged
            }
            do {
                let url = try await context.writeFile(name: path, content: finalContent)
                return "[OK] 已写入 \(url.lastPathComponent)（\(finalContent.count) 字符）"
            } catch {
                return "[!] 写入失败：\(error.localizedDescription)"
            }

        case .currentDocument(let name, let tabID):
            var finalContent = content
            if !(await context.isFileWritePreApproved(path: name)) {
                let base: WriteBaseContent =
                    (await context.currentDocument).map { .existing($0) } ?? .newFile
                let preview = WriteDiffPreviewBuilder.make(
                    path: name, summary: summary, base: base, newContent: content)
                guard let merged = await context.reviewFileWrite(preview, base: base, newContent: content) else {
                    return "[!] 用户已拒绝写入：\(name)（未落盘）"
                }
                finalContent = merged
            }
            // 审阅把工具挂起在 continuation 上，期间用户可能切 tab / 点 Stop
            if let refusal = try await validateCurrentDocumentTarget(
                sourceTabID: tabID, docName: name, context: context) {
                return refusal
            }
            do {
                try await context.writeDocument(finalContent)
                return "[OK] 已更新 \(name)（\(finalContent.count) 字符）"
            } catch {
                return "[!] 写入失败：\(error.localizedDescription)"
            }
        }
    }

    /// 写回「当前文档」前的双重校验（对齐 `SlashAICommandExecutor` 的 sourceTabID 锁定模式）。
    /// - Returns: 校验失败时给模型的错误文案（不落盘）；nil = 通过。
    /// - Throws:  run 已取消时抛 `CancellationError`（按取消收尾，不包装成误导性的工具错误）。
    static func validateCurrentDocumentTarget(
        sourceTabID: UUID?,
        docName: String,
        context: any AgentContextProtocol
    ) async throws -> String? {
        if Task.isCancelled { throw CancellationError() }
        guard await context.currentTabID == sourceTabID else {
            return "[!] 已放弃写入 \(docName)：审阅期间活动文档已切换，为避免写进错误文档本次未落盘。请切回目标文档后重新发起。"
        }
        return nil
    }
}

// MARK: - Read Document

struct ReadDocumentTool: AgentTool {
    /// 与磁盘读取路径（AgentFileRepository）一致的截断上限。
    /// 激活 tab 此前走 tab.content 全文返回——大文档一次读穿，且结果永久留在
    /// agentHistory 里逐轮重发（成本审计 8.1）。改为：默认截断 + 行区间读取。
    private static let maxChars = 64 * 1024

    let spec = AgentToolSpec(
        name: "read_document",
        description: "Read the content of a document. Without 'filename', reads the currently open document. With 'filename', reads that specific file from the workspace (no need to open it first). Long documents are truncated to 64K characters — use 'start_line'/'end_line' to read a specific range instead of re-reading the whole document.",
        parameters: ToolParameterSchema(
            properties: [
                "filename":   ToolPropertySchema(type: "string",  description: "Optional. Filename, workspace-relative path, or absolute path. Omit to read the currently active document."),
                "start_line": ToolPropertySchema(type: "integer", description: "Optional. 1-based line to start reading from. Use with end_line to read a specific range."),
                "end_line":   ToolPropertySchema(type: "integer", description: "Optional. 1-based inclusive line to stop at. Use with start_line to read a specific range.")
            ],
            required: []
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        let startLine = arguments["start_line"]?.intValue
        let endLine = arguments["end_line"]?.intValue

        let name: String
        let content: String
        if let filename = arguments["filename"]?.stringValue, !filename.isEmpty {
            let resolved = await context.resolveFile(filename)
            guard case .found(let url) = resolved else {
                if let message = resolved.promptMessage(forQuery: filename) {
                    return message
                }
                return "未找到文件：\(filename)"
            }
            name = url.lastPathComponent
            // 行区间读取用完整内容（不走 readFile 的 64KB 截断，避免区间落在截断点外）
            content = (startLine != nil || endLine != nil)
                ? (try await context.fileContentFull(at: url))
                : (try await context.readFile(at: url))
        } else {
            guard let current = await context.currentDocument else { throw AgentError.noDocument }
            name = await context.currentDocumentName ?? "untitled"
            content = current
        }

        // 提示注入轻净化（与 @mention 同一防护级别）：读回内容原文进历史，命中
        // 注入模式的行降级为引用文本；结果头部加边界声明。只净化读回内容，
        // 不影响 write/patch 路径。净化只给行加前缀、不增减行，行区间行号不受影响。
        let (safeContent, flagged) = PromptInjectionSanitizer.sanitize(content)

        let result: String
        if startLine != nil || endLine != nil {
            result = Self.rangeSlice(safeContent, name: name, start: startLine, end: endLine)
        } else {
            result = Self.truncated(safeContent, name: name)
        }
        return PromptInjectionSanitizer.guardrailNote(flagged: flagged) + result
    }

    /// 行区间切片（1-based、闭区间），附带总行数提示。
    static func rangeSlice(_ content: String, name: String, start: Int?, end: Int?) -> String {
        let lines = content.components(separatedBy: "\n")
        let from = max(1, start ?? 1)
        let to = min(lines.count, end ?? lines.count)
        guard from <= to else {
            return "[!] 行区间无效：L\(from)–L\(to)（全文共 \(lines.count) 行）"
        }
        let body = lines[(from - 1)...(to - 1)].joined(separator: "\n")
        return "# Document: \(name)（第 \(from)–\(to) 行，共 \(lines.count) 行）\n\n\(body)"
    }

    /// 超限时截断并给出区间读取指引（比静默截断更可操作）。
    static func truncated(_ content: String, name: String) -> String {
        guard content.count > maxChars else {
            return "# Document: \(name)\n\n\(content)"
        }
        return "# Document: \(name)（已截断至前 \(maxChars) 字符，可用 start_line/end_line 按行区间继续读取）\n\n"
            + content.prefix(maxChars)
    }
}

// MARK: - Write Document

struct WriteDocumentTool: AgentTool {
    let spec = AgentToolSpec(
        name: "write_document",
        description: "Replace the ENTIRE content of a document with new text. Only use for complete rewrites; for partial edits prefer patch_document. Without 'filename', rewrites the currently open document. With 'filename', writes that specific file (creating it if missing).",
        parameters: ToolParameterSchema(
            properties: [
                "content":  ToolPropertySchema(type: "string", description: "The new content to write."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit to rewrite the currently active document.")
            ],
            required: ["content"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let content = arguments["content"]?.stringValue else {
            throw AgentError.executionError("缺少 content 参数")
        }
        let lines = content.components(separatedBy: "\n").count
        if let filename = arguments["filename"]?.stringValue, !filename.isEmpty {
            // 已存在则用其绝对路径覆盖（避免裸文件名在根目录误建新文件）；否则按给定路径新建
            let resolved = await context.resolveFile(filename)
            if let message = resolved.promptMessage(forQuery: filename) {
                return message
            }
            // found 则用其绝对路径覆盖（避免裸文件名在根目录误建新文件）；notFound 则按给定路径新建
            let target: String
            if case .found(let foundURL) = resolved { target = foundURL.path } else { target = filename }
            var finalContent = content
            // 写入前审阅：本 run 已免确认（全部允许 / autoApprove 白名单命中）则直接放行；
            // 否则是否进 diff 审阅态由 context 决定（GUI 默认逐块审阅，headless / mock 直通或走确认条）
            if !(await context.isFileWritePreApproved(path: target)) {
                // diff 预览：已存在文件取写前内容（fileContentFull = tab 内存优先，与
                // AgentRunCheckpoint.captureBeforeWrite 的取舍一致）；新文件按纯新增
                let base: WriteBaseContent
                if case .found(let foundURL) = resolved {
                    base = await Self.writeBase(for: foundURL, context: context)
                } else {
                    base = .newFile
                }
                let preview = WriteDiffPreviewBuilder.make(
                    path: target, summary: "写入 \(target)（约 \(lines) 行）",
                    base: base, newContent: content)
                guard let approved = await context.reviewFileWrite(preview, base: base, newContent: content) else {
                    return "[!] 用户已拒绝写入：\(target)（未落盘）"
                }
                finalContent = approved   // 逐块审阅后的合并结果，可能与原内容不同
            }
            do {
                let url = try await context.writeFile(name: target, content: finalContent)
                return "[OK] 已写入文件：\(url.lastPathComponent)（\(finalContent.count) 字符）"
            } catch {
                return "[!] 写入失败：\(error.localizedDescription)"
            }
        }
        let docName = await context.currentDocumentName ?? "当前文档"
        // 锁定发起 tab：审阅挂起期间用户可能切 tab——写回那一刻当前 tab 必须仍是
        // 发起 tab，否则放弃写入（对齐 SlashAICommandExecutor 的 sourceTabID 模式）
        let sourceTabID = await context.currentTabID
        var finalContent = content
        // 写入前审阅（当前文档全量重写）；写前内容 = 当前 tab 内存内容
        if !(await context.isFileWritePreApproved(path: docName)) {
            let base: WriteBaseContent =
                (await context.currentDocument).map { .existing($0) } ?? .newFile
            let preview = WriteDiffPreviewBuilder.make(
                path: docName, summary: "全量重写 \(docName)（约 \(lines) 行）",
                base: base, newContent: content)
            guard let approved = await context.reviewFileWrite(preview, base: base, newContent: content) else {
                return "[!] 用户已拒绝写入：\(docName)（未落盘）"
            }
            finalContent = approved   // 逐块审阅后的合并结果，可能与原内容不同
        }
        // 审阅返回后、实际写入前：run 已被取消（Stop）或 tab 已切换则绝不落盘
        if let refusal = try await AuthoringWrite.validateCurrentDocumentTarget(
            sourceTabID: sourceTabID, docName: docName, context: context) {
            return refusal
        }
        do {
            try await context.writeDocument(finalContent)
            return "[OK] 文档已全量更新（\(finalContent.count) 字符）"
        } catch {
            return "[!] 写入失败：\(error.localizedDescription)"
        }
    }

    /// 取已存在文件的写前内容（fileContentFull = tab 内存优先）；读失败降级 .unavailable。
    static func writeBase(for url: URL, context: any AgentContextProtocol) async -> WriteBaseContent {
        if let old = try? await context.fileContentFull(at: url) {
            return .existing(old)
        }
        return .unavailable
    }
}

// MARK: - Patch Document

struct PatchDocumentTool: AgentTool {
    let spec = AgentToolSpec(
        name: "patch_document",
        description: "Precisely replace a specific piece of text. Prefer this over write_document for partial edits. Without 'filename', patches the currently open document. With 'filename', patches that specific file directly (no need to open it first).",
        parameters: ToolParameterSchema(
            properties: [
                "find":        ToolPropertySchema(type: "string",  description: "The exact text to find (case-sensitive, literal match)."),
                "replace":     ToolPropertySchema(type: "string",  description: "The replacement text."),
                "replace_all": ToolPropertySchema(type: "boolean", description: "If true, replace all occurrences. Default: first match only."),
                "filename":    ToolPropertySchema(type: "string",  description: "Optional. Filename, workspace-relative path, or absolute path. Omit to patch the currently active document.")
            ],
            required: ["find", "replace"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let find    = arguments["find"]?.stringValue,
              let replace = arguments["replace"]?.stringValue
        else { throw AgentError.executionError("缺少 find 或 replace 参数") }

        // 空 find 提前拦截：空 needle 会退化为插入式替换腐蚀文档（PatchEngine 层
        // 同样拦了一道）。返回工具错误让模型先 read_document 复制原文后重试。
        guard !find.isEmpty else {
            return "[!] patch 失败：find 参数为空。请先用 read_document 读取文档，把要替换的原文完整复制到 find 后重试。"
        }

        let replaceAll = arguments["replace_all"]?.boolValue ?? false
        let matchDesc = replaceAll ? "全部匹配" : "首个匹配"

        if let filename = arguments["filename"]?.stringValue, !filename.isEmpty {
            // 写入前审阅：本 run 已免确认（全部允许 / autoApprove 白名单命中）则直接放行；
            // 否则是否进 diff 审阅态由 context 决定（GUI 默认逐块审阅，headless / mock 直通或走确认条）
            if !(await context.isFileWritePreApproved(path: filename)) {
                // diff 预览：解析目标取写前内容（fileContentFull = tab 内存优先），
                // 找不到 / 读失败时降级为只显示 summary
                var oldContent: String? = nil
                if case .found(let url) = await context.resolveFile(filename) {
                    oldContent = try? await context.fileContentFull(at: url)
                }
                if let old = oldContent {
                    // 预演与实际写入走同一引擎；预演阶段就发现无匹配则直接报错，
                    // 不把「找不到 find」带进审阅态
                    let applied = PatchEngine.apply(to: old, find: find, replace: replace, all: replaceAll)
                    let appliedCount = applied.count
                    guard appliedCount > 0 else {
                        return PatchNotFoundError(
                            find: find,
                            nearbyContext: PatchEngine.nearbyContext(in: old, around: find)
                        ).errorDescription ?? "[!] 未找到匹配文本"
                    }
                    let base = WriteBaseContent.existing(old)
                    let preview = WriteDiffPreviewBuilder.make(
                        path: filename, summary: "在 \(filename) 中替换\(matchDesc)",
                        base: base, newContent: applied.updated)
                    guard let merged = await context.reviewFileWrite(
                        preview, base: base, newContent: applied.updated)
                    else { return "[!] 用户已拒绝写入：\(filename)（未落盘）" }
                    // 审阅通过：写合并后的完整内容（逐块接受时 ≠ 原始 patch 结果，
                    // 不能再走 patchFile 重放 find/replace）
                    do {
                        let url = try await context.writeFile(name: filename, content: merged)
                        return "[OK] 已在 \(url.lastPathComponent) 写入审阅后的改动（\(merged.count) 字符）"
                    } catch {
                        return "[!] 写入失败：\(error.localizedDescription)"
                    }
                }
                // 写前内容不可得：退化确认条，通过后仍走精准 patch
                let preview = Self.patchPreview(
                    path: filename, summary: "在 \(filename) 中替换\(matchDesc)",
                    oldContent: nil, find: find, replace: replace, all: replaceAll)
                let approved = await context.confirmFileWrite(preview)
                guard approved else { return "[!] 用户已拒绝写入：\(filename)" }
            }
            do {
                let count = try await context.patchFile(name: filename, find: find, replace: replace, all: replaceAll)
                return "[OK] 已在 \(filename) 替换 \(count) 处"
            } catch let e as PatchNotFoundError {
                return e.errorDescription ?? "[!] 未找到匹配文本"
            } catch AgentContextError.fileNotFound(let name) {
                return "[!] 未找到文件：\(name)"
            }
        }

        let docName = await context.currentDocumentName ?? "当前文档"
        // 锁定发起 tab（理由同 write_document 当前文档分支）
        let sourceTabID = await context.currentTabID
        // 写入前审阅（当前文档局部替换）；写前内容 = 当前 tab 内存内容
        if !(await context.isFileWritePreApproved(path: docName)) {
            if let old = await context.currentDocument {
                let applied = PatchEngine.apply(to: old, find: find, replace: replace, all: replaceAll)
                let appliedCount = applied.count
                guard appliedCount > 0 else {
                    return PatchNotFoundError(
                        find: find,
                        nearbyContext: PatchEngine.nearbyContext(in: old, around: find)
                    ).errorDescription ?? "[!] 未找到匹配文本"
                }
                let base = WriteBaseContent.existing(old)
                let preview = WriteDiffPreviewBuilder.make(
                    path: docName, summary: "在 \(docName) 中替换\(matchDesc)",
                    base: base, newContent: applied.updated)
                guard let merged = await context.reviewFileWrite(
                    preview, base: base, newContent: applied.updated)
                else { return "[!] 用户已拒绝写入：\(docName)（未落盘）" }
                // 审阅返回后、实际写入前：run 已被取消（Stop）或 tab 已切换则绝不落盘
                if let refusal = try await AuthoringWrite.validateCurrentDocumentTarget(
                    sourceTabID: sourceTabID, docName: docName, context: context) {
                    return refusal
                }
                do {
                    try await context.writeDocument(merged)
                    return "[OK] 已写入审阅后的改动（\(merged.count) 字符）"
                } catch {
                    return "[!] 写入失败：\(error.localizedDescription)"
                }
            }
            // 写前内容不可得：退化确认条，通过后仍走精准 patch
            let preview = Self.patchPreview(
                path: docName, summary: "在 \(docName) 中替换\(matchDesc)",
                oldContent: nil, find: find, replace: replace, all: replaceAll)
            let approved = await context.confirmFileWrite(preview)
            guard approved else { return "[!] 用户已拒绝写入：\(docName)" }
        }
        // 确认条返回后、实际 patch 前同样校验（确认条也会把工具挂起）
        if let refusal = try await AuthoringWrite.validateCurrentDocumentTarget(
            sourceTabID: sourceTabID, docName: docName, context: context) {
            return refusal
        }
        do {
            let count = try await context.patchDocument(find: find, replace: replace, all: replaceAll)
            return "[OK] 已替换 \(count) 处"
        } catch let e as PatchNotFoundError {
            return e.errorDescription ?? "[!] 未找到匹配文本"
        }
    }

    /// 用 PatchEngine 预演替换结果构建 diff 预览（预演与实际 patchFile/patchDocument
    /// 走同一引擎，预览所见即实际所得）。oldContent 为 nil = 写前内容不可得。
    static func patchPreview(path: String, summary: String, oldContent: String?,
                             find: String, replace: String, all: Bool) -> FileWritePreview {
        guard let old = oldContent else {
            return WriteDiffPreviewBuilder.make(
                path: path, summary: summary, base: .unavailable, newContent: "")
        }
        let patched = PatchEngine.apply(to: old, find: find, replace: replace, all: all).updated
        return WriteDiffPreviewBuilder.make(
            path: path, summary: summary, base: .existing(old), newContent: patched)
    }
}

// MARK: - Search Document

struct SearchDocumentTool: AgentTool {
    let spec = AgentToolSpec(
        name: "search_document",
        description: "Search for a keyword or phrase in a document. Returns matching lines with line numbers. Without 'filename', searches the currently open document. With 'filename', searches that specific file.",
        parameters: ToolParameterSchema(
            properties: [
                "query":    ToolPropertySchema(type: "string", description: "The text to search for (case-insensitive)."),
                "filename": ToolPropertySchema(type: "string", description: "Optional. Filename, workspace-relative path, or absolute path. Omit to search the currently active document.")
            ],
            required: ["query"]
        )
    )

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        guard let query = arguments["query"]?.stringValue else {
            throw AgentError.executionError("缺少 query 参数")
        }

        let content: String
        if let filename = arguments["filename"]?.stringValue, !filename.isEmpty {
            let resolved = await context.resolveFile(filename)
            guard case .found(let url) = resolved else {
                if let message = resolved.promptMessage(forQuery: filename) {
                    return message
                }
                return "未找到文件：\(filename)"
            }
            // 用完整内容搜索（不走 readFile 的 64KB 截断），避免大文件后半段漏搜
            content = try await context.fileContentFull(at: url)
        } else {
            guard let current = await context.currentDocument else { throw AgentError.noDocument }
            content = current
        }

        let lines = content.components(separatedBy: "\n")
        let matches = lines.enumerated().compactMap { (idx, line) -> String? in
            line.localizedCaseInsensitiveContains(query) ? "L\(idx + 1): \(line)" : nil
        }
        if matches.isEmpty { return "未找到包含【\(query)】的内容" }
        // 匹配行来自文件内容，属不可信数据：与 read_file 同级净化后再回灌模型。
        let (safeBody, flagged) = PromptInjectionSanitizer.sanitize(matches.prefix(20).joined(separator: "\n"))
        return PromptInjectionSanitizer.guardrailNote(flagged: flagged)
            + "找到 \(matches.count) 处匹配：\n\n" + safeBody
    }
}
