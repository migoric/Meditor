import Foundation

/// 文档诊断：一个检查出的问题。
struct DocumentIssue: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case deadLink(String)                 // 相对路径链接指向不存在的文件
        case missingImage(String)             // 图片引用指向不存在的本地文件
        case duplicateHeading(String)         // 同文档内重复出现的标题文本
        case headingLevelSkip(from: Int, to: Int)  // 标题层级跳跃（如 H1 → H3）
        case emptyHeading                     // 只有 # 没有文字的标题
        case unclosedCodeBlock                // 围栏代码块没有收尾（报在开栏行）
        case mermaidSyntax(String)            // Mermaid 块语法错误（关联值是 mermaid.parse 的错误消息）

        /// 模型能否通过改文本修复（「让 Agent 修复」入口的可用性口径）。
        /// missingImage 是纯缺失资源——模型变不出图片文件，改文本只能删引用，
        /// 不算可修复；死链模型可以改路径/去掉链接，算可修复。
        /// mermaidSyntax 也走默认 true：错误消息里就带着定位线索，模型改图代码即可修复。
        var isAgentFixable: Bool {
            if case .missingImage = self { return false }
            return true
        }

        /// 写后自检的分级（比 isAgentFixable 更严）：文本层面可确定性修复、
        /// 结果不依赖外部因素的才进「一键修复」列表。
        /// deadLink 的目标文件可能稍后才被创建（Agent 分批写文件的中途态），
        /// 与 missingImage 一样只报告不自动改。mermaidSyntax 同样只报告：
        /// 怎么改对要靠模型判断，不是确定性文本替换。
        var isDeterministicFix: Bool {
            switch self {
            case .duplicateHeading, .headingLevelSkip, .emptyHeading, .unclosedCodeBlock:
                return true
            case .deadLink, .missingImage, .mermaidSyntax:
                return false
            }
        }
    }

    /// 严重度：error 会让导出产物明显缺内容，warning 只是质量提醒。
    enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    let kind: Kind
    let fileURL: URL
    /// 0-based 行号（与 requestEditorScroll / TOC 的约定一致）
    let line: Int

    var severity: Severity {
        switch kind {
        case .missingImage, .unclosedCodeBlock, .mermaidSyntax: return .error
        case .deadLink, .duplicateHeading, .headingLevelSkip, .emptyHeading: return .warning
        }
    }

    var id: String { "\(fileURL.path):\(line):\(kind)" }
}

/// 本地规则引擎：纯静态检查，不调 AI。
/// 逐行扫描，跳过围栏代码块（与 render.js 的 collectHeadingLines 同一策略）；
/// 标题判定直接复用 MarkdownText.headingPrefix，不另写 Markdown parser。
enum DocumentDiagnostics {

    private static let linkPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(!?)\[[^\]]*\]\(([^)]*)\)"#,
            options: []
        )
    }()

    // MARK: - 单文件检查（纯逻辑，fileExists 可注入，便于测试）

    static func issues(in content: String,
                       fileURL: URL,
                       fileExists: (URL) -> Bool) -> [DocumentIssue] {
        var issues: [DocumentIssue] = []
        var inFence = false
        var fenceMarker: Character = "`"
        var fenceOpenLine = 0
        var seenHeadings: Set<String> = []
        var previousHeadingLevel = 0

        let lines = content.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块：记录开栏字符（``` 或 ~~~），同字符才认为关栏
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker: Character = trimmed.hasPrefix("```") ? "`" : "~"
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                    fenceOpenLine = lineIndex
                } else if marker == fenceMarker {
                    inFence = false
                }
                continue
            }
            if inFence { continue }

            // 标题规则
            if let heading = MarkdownText.headingPrefix(line) {
                if heading.text.isEmpty {
                    issues.append(DocumentIssue(
                        kind: .emptyHeading,
                        fileURL: fileURL, line: lineIndex))
                } else if seenHeadings.contains(heading.text) {
                    issues.append(DocumentIssue(
                        kind: .duplicateHeading(heading.text),
                        fileURL: fileURL, line: lineIndex))
                } else {
                    seenHeadings.insert(heading.text)
                }
                if previousHeadingLevel > 0, heading.level > previousHeadingLevel + 1 {
                    issues.append(DocumentIssue(
                        kind: .headingLevelSkip(from: previousHeadingLevel, to: heading.level),
                        fileURL: fileURL, line: lineIndex))
                }
                previousHeadingLevel = heading.level
            }

            // 链接 / 图片规则
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            for match in linkPattern.matches(in: line, range: range) {
                guard match.numberOfRanges == 3 else { continue }
                let isImage = nsLine.substring(with: match.range(at: 1)) == "!"
                let rawTarget = nsLine.substring(with: match.range(at: 2))
                guard let target = linkTarget(rawTarget),
                      let resolved = resolveLocalTarget(target, relativeTo: fileURL),
                      !fileExists(resolved) else { continue }
                issues.append(DocumentIssue(
                    kind: isImage ? .missingImage(target) : .deadLink(target),
                    fileURL: fileURL, line: lineIndex))
            }
        }

        // 扫描结束仍在围栏内 → 代码块未闭合，报在开栏行
        if inFence {
            issues.append(DocumentIssue(
                kind: .unclosedCodeBlock,
                fileURL: fileURL, line: fenceOpenLine))
        }
        return issues
    }

    // MARK: - 工作区扫描（后台线程，可取消）

    /// 递归扫描 rootURL 下的 .md/.markdown 文件。随 Task 取消中断（返回已扫部分）。
    /// progress 回调参数为（已扫描文件数, 总文件数），在后台线程触发。
    static func scan(rootURL: URL,
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [DocumentIssue] {
        // Task.detached 不继承调用方的取消——桥接一下，否则面板的取消按钮和
        // onDisappear 停不掉后台扫描（detached 里的 Task.isCancelled 永远为 false）
        let task = Task.detached(priority: .userInitiated) {
            let files = DefaultAgentFileRepository.enumerate(
                root: rootURL,
                extensions: ["md", "markdown"],
                noiseDirectories: DefaultAgentFileRepository.noiseDirectories)
            let fm = FileManager.default
            var found: [DocumentIssue] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    found.append(contentsOf: issues(in: content, fileURL: url) {
                        fm.fileExists(atPath: $0.path)
                    })
                }
                if index % 10 == 0 || index == files.count - 1 {
                    progress?(index + 1, files.count)
                }
            }
            return found.sorted {
                $0.fileURL.path != $1.fileURL.path
                    ? $0.fileURL.path < $1.fileURL.path
                    : $0.line < $1.line
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - 链接目标解析

    /// 取出 `(...)` 里的真实目标：支持 `<...>` 包裹与可选 title（`path "title"`）。
    private static func linkTarget(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("<") {
            guard let end = t.firstIndex(of: ">"), end > t.startIndex else { return nil }
            return String(t[t.index(after: t.startIndex)..<end])
        }
        if let space = t.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(t[t.startIndex..<space])
        }
        return t
    }

    /// 把链接目标解析成本地文件 URL；外部链接 / 纯锚点 / 空目标返回 nil（不检查）。
    private static func resolveLocalTarget(_ target: String, relativeTo fileURL: URL) -> URL? {
        var t = target
        if t.hasPrefix("#") { return nil }                       // 页内锚点
        if t.hasPrefix("//") { return nil }                      // protocol-relative
        // 带 scheme 的（http:、mailto:、data: 等）一律视为外部链接
        if t.range(of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*:"#, options: .regularExpression) != nil {
            return nil
        }
        if let hash = t.firstIndex(of: "#") { t = String(t[t.startIndex..<hash]) }
        if let query = t.firstIndex(of: "?") { t = String(t[t.startIndex..<query]) }
        guard !t.isEmpty else { return nil }
        let decoded = t.removingPercentEncoding ?? t
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent(decoded).standardizedFileURL
    }
}
