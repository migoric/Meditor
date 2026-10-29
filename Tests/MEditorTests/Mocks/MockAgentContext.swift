import Foundation
@testable import MEditor

// MARK: - MockAgentContext

/// 完全内存态的 AgentContextProtocol 实现，用于工具单测。
/// 设计原则：
///   - 所有文件操作在内存字典里完成，不触碰磁盘
///   - 通过 Result/Error 属性注入失败场景
///   - spy 属性记录所有调用，方便断言"是否被调用、参数是什么"
@MainActor
final class MockAgentContext: AgentContextProtocol {

    // MARK: - Current document state

    var currentDocument: String?     = "# Test Document\n\nSome content here.\nAnother line."
    var currentDocumentName: String? = "test.md"
    var workspaceURL: URL?           = URL(fileURLWithPath: "/mock/workspace")
    /// 当前 tab 身份（tab 锁定校验用）：测试中可在审阅回调里改值，模拟「审阅期间切 tab」。
    var currentTabID: UUID?          = UUID()

    // MARK: - In-memory filesystem
    // 文件名（不含目录前缀）→ 内容，resolveFile / listWorkspaceFiles 从此查找

    var files: [String: String] = [:]

    // MARK: - Spy records（验证工具是否正确调用了 context）

    var writtenContents:    [String]                         = []
    var patchCalls:         [(find: String, replace: String, all: Bool)] = []
    var insertedTexts:      [String]                         = []
    var createdFiles:       [(name: String, content: String)] = []
    var writtenFiles:       [(name: String, content: String)] = []
    var openedFiles:        [String]                         = []
    var createdDirectories: [String]                         = []
    var confirmedCommands:  [String]                         = []
    var confirmedWrites:    [(path: String, summary: String)] = []
    /// 携带 diff 预览的写入确认 spy（与 confirmedWrites 同步记录，另存完整 preview）
    var confirmedWritePreviews: [FileWritePreview]           = []
    /// 写前审阅 spy：记录进入审阅的 preview 与提议内容
    var reviewedWritePreviews: [FileWritePreview]            = []
    var reviewedWriteContents:  [String]                     = []

    // MARK: - Error injection

    var writeDocumentError:  Error?                 = nil
    var patchDocumentResult: Result<Int, Error>     = .success(1)
    var patchFileResult:     Result<Int, Error>     = .success(1)
    var createFileError:     Error?                 = nil
    var writeFileError:      Error?                 = nil
    var fileContentError:    Error?                 = nil
    /// fileContentFull 的内容覆盖（key = 文件 lastPathComponent）：模拟「tab 内存内容
    /// 优先于磁盘」的场景，用于断言工具取写前内容走的是 fileContentFull 而非 readFile。
    var fullContentOverrides: [String: String]      = [:]
    var commandConfirmResult: Bool                  = true
    var allowedCommandPatterns: [String]?           = nil
    /// 文件写入确认的注入结果 / run 级「全部允许」开关（spy 语义同 commandConfirmResult）
    var writeConfirmResult: Bool                    = true
    var fileWriteAllowedForRun: Bool                = false
    var preApprovedWritePaths: Set<String>          = []
    /// 写前审阅结果注入：返回批准后的最终内容（可改写），nil = 用户拒绝/取消。
    /// 未设置时走协议默认语义——转发 confirmFileWrite（Bool 确认），保持既有测试不变。
    var reviewWriteHandler: ((FileWritePreview, String) -> String?)? = nil
    /// 挂起式写审阅：置 true 后 reviewFileWrite 挂起在 continuation 上（不响应 Task 取消，
    /// 模拟 GUI diff 审阅态），直到 cancelPendingWriteConfirmation() 以「取消」语义放行。
    var reviewHangsUntilCancelled: Bool = false
    /// 挂起中的写审阅 continuation（cancelPendingWriteConfirmation 统一放行）
    private var pendingReviewContinuations: [CheckedContinuation<String?, Never>] = []
    /// cancelPending* 调用次数 spy（验证 Runner cancel/收尾的解除接线）
    private(set) var cancelPendingWriteConfirmationCallCount = 0
    private(set) var cancelPendingCommandConfirmationCallCount = 0

    func setAllowedCommandPatterns(_ patterns: [String]?) {
        allowedCommandPatterns = patterns?.isEmpty == false ? patterns : nil
    }

    // MARK: - Per-key approval cache (spy)
    private var _approvedKeys: Set<String>          = []

    // MARK: - AgentContextProtocol — Document

    func writeDocument(_ content: String) throws {
        if let e = writeDocumentError { throw e }
        writtenContents.append(content)
        currentDocument = content
    }

    func patchDocument(find: String, replace: String, all: Bool) throws -> Int {
        patchCalls.append((find: find, replace: replace, all: all))
        switch patchDocumentResult {
        case .success(let n):
            // 真实模拟替换，让 currentDocument 保持一致
            if var doc = currentDocument {
                if all {
                    doc = doc.replacingOccurrences(of: find, with: replace)
                } else if let r = doc.range(of: find) {
                    doc.replaceSubrange(r, with: replace)
                }
                currentDocument = doc
            }
            return n
        case .failure(let e): throw e
        }
    }

    func insertIntoDocument(_ text: String) {
        insertedTexts.append(text)
    }

    func patchFile(name: String, find: String, replace: String, all: Bool) async throws -> Int {
        patchCalls.append((find: find, replace: replace, all: all))
        switch patchFileResult {
        case .success(let n):
            if var content = files[name] {
                content = all
                    ? content.replacingOccurrences(of: find, with: replace)
                    : { var c = content; if let r = c.range(of: find) { c.replaceSubrange(r, with: replace) }; return c }()
                files[name] = content
            }
            return n
        case .failure(let e): throw e
        }
    }

    // MARK: - AgentContextProtocol — Workspace

    func listWorkspaceFiles(extensions: [String]) async -> [URL] {
        files.keys
            .filter { name in
                extensions.isEmpty || extensions.contains { name.hasSuffix(".\($0)") }
            }
            .map { fakeURL(for: $0) }
    }

    func readFile(at url: URL) async throws -> String {
        let name = url.lastPathComponent
        guard let content = files[name] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return content
    }

    func fileContentFull(at url: URL) async throws -> String {
        if let e = fileContentError { throw e }
        if let override = fullContentOverrides[url.lastPathComponent] { return override }
        return try await readFile(at: url)
    }

    func createFile(name: String, content: String = "") throws -> URL {
        if let e = createFileError { throw e }
        guard files[name] == nil else {
            throw AgentContextError.fileAlreadyExists(name)
        }
        files[name] = content
        createdFiles.append((name: name, content: content))
        return fakeURL(for: name)
    }

    func writeFile(name: String, content: String) throws -> URL {
        if let e = writeFileError { throw e }
        files[name] = content
        writtenFiles.append((name: name, content: content))
        return fakeURL(for: name)
    }

    func createDirectory(name: String) throws -> URL {
        createdDirectories.append(name)
        return fakeURL(for: name)
    }

    func openFile(named name: String) -> Bool {
        openedFiles.append(name)
        return files[name] != nil
    }

    func searchWorkspace(query: String, extensions: [String]) async -> [String] {
        let lower = query.lowercased()
        var results: [String] = []
        for (name, content) in files {
            guard extensions.isEmpty || extensions.contains(where: { name.hasSuffix(".\($0)") })
            else { continue }
            var lineNum = 0
            content.enumerateLines { line, stop in
                lineNum += 1
                if line.lowercased().contains(lower) {
                    results.append("\(name):\(lineNum): \(line)")
                    if results.count >= 20 { stop = true }
                }
            }
        }
        return results
    }

    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool {
        confirmedCommands.append(command)
        return commandConfirmResult
    }

    /// 确认条钩子（测试用）：返回 writeConfirmResult 前调用，模拟确认条挂起期间的状态变化
    var confirmWriteHook: (() -> Void)? = nil

    func confirmFileWrite(_ path: String, summary: String) async -> Bool {
        confirmedWrites.append((path: path, summary: summary))
        confirmWriteHook?()
        return writeConfirmResult
    }

    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        confirmedWritePreviews.append(preview)
        confirmedWrites.append((path: preview.path, summary: preview.summary))
        confirmWriteHook?()
        return writeConfirmResult
    }

    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String? {
        reviewedWritePreviews.append(preview)
        reviewedWriteContents.append(newContent)
        if reviewHangsUntilCancelled {
            // 挂起直到 cancelPendingWriteConfirmation 以 nil（取消）放行
            return await withCheckedContinuation { cont in
                pendingReviewContinuations.append(cont)
            }
        }
        if let handler = reviewWriteHandler { return handler(preview, newContent) }
        // 默认与协议扩展一致：退化为 Bool 确认条语义
        return await confirmFileWrite(preview) ? newContent : nil
    }

    func cancelPendingWriteConfirmation() {
        cancelPendingWriteConfirmationCallCount += 1
        let pending = pendingReviewContinuations
        pendingReviewContinuations = []
        for cont in pending { cont.resume(returning: nil) }   // 取消 = 拒绝语义，不落盘
    }

    func cancelPendingCommandConfirmation() {
        cancelPendingCommandConfirmationCallCount += 1
    }

    var isFileWriteAllowedForRun: Bool { fileWriteAllowedForRun }

    func isFileWritePreApproved(path: String) -> Bool {
        fileWriteAllowedForRun || preApprovedWritePaths.contains(path)
    }

    func isCommandApproved(_ key: String) -> Bool {
        _approvedKeys.contains(key)
    }

    func markCommandApproved(_ key: String) {
        _approvedKeys.insert(key)
    }

    func resolveFile(_ name: String) -> FileResolveResult {
        // 支持精确文件名或 "path/to/file.md" 格式匹配
        let matches = files.keys.filter { key in
            key == name || key.hasSuffix("/\(name)") || URL(fileURLWithPath: key).lastPathComponent == name
        }.map { fakeURL(for: $0) }

        switch matches.count {
        case 0:  return .notFound
        case 1:  return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    // MARK: - Helpers

    private func fakeURL(for name: String) -> URL {
        (workspaceURL ?? URL(fileURLWithPath: "/mock/workspace"))
            .appendingPathComponent(name)
    }

    /// 快速填充 in-memory 文件，方便测试 setUp。
    func addFile(_ name: String, content: String) {
        files[name] = content
    }

    /// 重置所有 spy 记录（保留文件和配置）。
    func resetSpies() {
        writtenContents    = []
        patchCalls         = []
        insertedTexts      = []
        createdFiles       = []
        writtenFiles       = []
        openedFiles        = []
        createdDirectories = []
        confirmedCommands  = []
        confirmedWrites    = []
        confirmedWritePreviews = []
        reviewedWritePreviews = []
        reviewedWriteContents = []
        _approvedKeys      = []
    }

    /// 直接设置某个 key 为已批准（测试用）。
    func stubApprovedKey(_ key: String) {
        _approvedKeys.insert(key)
    }
}
