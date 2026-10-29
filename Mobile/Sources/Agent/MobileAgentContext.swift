import Foundation

/// iOS 端 AgentContextProtocol 实现。
///
/// macOS 端由 AgentContext + AgentDocumentAdapter（AppKit 桥）组成；移动端没有
/// AppKit/AppState，这里直接基于 DocumentStore（当前文档）+
/// DefaultAgentFileRepository（工作区 IO，限定在沙盒 Documents 目录）实现。
///
/// 不支持的能力（光标插入、shell 命令确认等）按约定返回空实现 / false。
@MainActor
final class MobileAgentContext: AgentContextProtocol {

    private let store: DocumentStore
    private let repo: DefaultAgentFileRepository
    /// 写文件的确认闸门。**必须**注入并覆写 `confirmFileWrite`——
    /// 协议默认实现是 fail-closed（拒绝），不覆写等于 AI 完全不能写文件。
    private let gate: WriteConfirmationGate

    init(store: DocumentStore, gate: WriteConfirmationGate? = nil) {
        self.store = store
        // 工作区跟随 store（可注入，测试友好），不再静态直引。
        self.repo  = DefaultAgentFileRepository { store.workspace }
        // 默认参数里不能直接构造 @MainActor 类型（默认参数表达式在非隔离上下文求值），
        // 所以收 nil 再在这里补。
        self.gate  = gate ?? WriteConfirmationGate()
    }

    /// 供视图层绑定确认条状态。
    var writeGate: WriteConfirmationGate { gate }

    // MARK: - DocumentContext

    var currentDocument: String? { store.hasDocument ? store.text : nil }
    var currentDocumentName: String? { store.hasDocument ? store.fileName : nil }

    func writeDocument(_ content: String) throws {
        try store.noteAIReplace(content)
    }

    @discardableResult
    func patchDocument(find: String, replace: String, all: Bool) throws -> Int {
        guard store.hasDocument else { throw AgentContextError.noActiveDocument }
        let (updated, count) = PatchEngine.apply(to: store.text, find: find, replace: replace, all: all)
        if count == 0 {
            throw PatchNotFoundError(
                find: find,
                nearbyContext: PatchEngine.nearbyContext(in: store.text, around: find)
            )
        }
        try store.noteAIReplace(updated)
        return count
    }

    /// 移动端没有编辑器光标：退化为追加到文档末尾。
    func insertIntoDocument(_ text: String) {
        guard store.hasDocument else { return }
        let separator = store.text.hasSuffix("\n") || store.text.isEmpty ? "" : "\n"
        do {
            try store.noteAIReplace(store.text + separator + text)
        } catch {
            print("[MobileAgentContext] insert_at_cursor 写盘失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func patchFile(name: String, find: String, replace: String, all: Bool) async throws -> Int {
        guard let url = resolveExistingFile(name) else {
            throw AgentContextError.fileNotFound(name)
        }
        try validateWriteTarget(url)
        let original       = try await fileContentFull(at: url)
        let (updated, cnt) = PatchEngine.apply(to: original, find: find, replace: replace, all: all)
        if cnt == 0 {
            throw PatchNotFoundError(
                find: find,
                nearbyContext: PatchEngine.nearbyContext(in: original, around: find)
            )
        }
        try repo.writeDisk(updated, to: url)
        store.reloadIfCurrent(url)
        return cnt
    }

    /// 写入目标合规性校验：必须位于工作区内（对应 macOS 端 AgentContext.validateWriteTarget；
    /// iOS 无散文件 Tab 概念，工作区即全部可写范围）。
    /// DefaultAgentFileRepository.resolveURL 接受绝对路径与 ../——读路径由沙盒兜底，
    /// 写路径在此拒绝逃逸，防止提示注入诱导 Agent 写工作区外文件。
    private func canonicalURL(_ url: URL) -> URL {
        var base = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: base.path), base.path != "/" {
            suffix.insert(base.lastPathComponent, at: 0)
            base.deleteLastPathComponent()
        }
        var resolved = base.resolvingSymlinksInPath()
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved
    }

    private func validateWriteTarget(_ url: URL) throws {
        let target = canonicalURL(url)
        guard let root = workspaceURL.map(canonicalURL),
              target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw AgentContextError.pathOutsideWorkspace(target.path)
        }
    }

    private func validateReadTarget(_ url: URL) throws {
        let target = canonicalURL(url)
        if let root = workspaceURL.map(canonicalURL),
           target.path == root.path || target.path.hasPrefix(root.path + "/") {
            return
        }
        if url.standardizedFileURL == store.sandboxURL?.standardizedFileURL { return }
        throw AgentContextError.pathOutsideWorkspace(target.path)
    }

    // MARK: - WorkspaceContext

    var workspaceURL: URL? { store.workspace }

    func listWorkspaceFiles(extensions: [String]) async -> [URL] {
        await repo.listWorkspaceFiles(extensions: extensions)
    }

    func readFile(at url: URL) async throws -> String {
        try validateReadTarget(url)
        return try await repo.readFile(at: url)
    }

    func fileContentFull(at url: URL) async throws -> String {
        try validateReadTarget(url)
        if url.standardizedFileURL == store.sandboxURL?.standardizedFileURL {
            return store.text
        }
        return try await repo.readDiskFull(at: url)
    }

    @discardableResult func createFile(name: String, content: String) throws -> URL {
        try validateWriteTarget(repo.resolveURL(name))
        return try repo.createFile(name: name, content: content)
    }

    @discardableResult func writeFile(name: String, content: String) throws -> URL {
        try validateWriteTarget(repo.resolveURL(name))
        let url = try repo.writeFile(name: name, content: content)
        store.reloadIfCurrent(url)
        return url
    }

    @discardableResult func createDirectory(name: String) throws -> URL {
        try validateWriteTarget(repo.resolveURL(name))
        return try repo.createDirectory(name: name)
    }

    @discardableResult
    func openFile(named name: String) -> Bool {
        guard let url = resolveExistingFile(name) else { return false }
        return store.loadFromSandbox(url)
    }

    func searchWorkspace(query: String, extensions: [String]) async -> [String] {
        await repo.searchWorkspace(query: query, extensions: extensions)
    }

    func resolveFile(_ name: String) -> FileResolveResult {
        repo.resolveFile(name)
    }

    // MARK: - ShellContext（移动端无 shell：全部空实现）

    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool { false }
    func isCommandApproved(_ key: String) -> Bool { false }
    func markCommandApproved(_ key: String) {}
    var allowedCommandPatterns: [String]? { nil }
    func setAllowedCommandPatterns(_ patterns: [String]?) {}

    // MARK: - 文件写入确认（移动端有 UI，必须真的问）

    /// 写文件前挂起确认条。
    ///
    /// 这是本类型里唯一「非空实现」的 ShellContext 成员，也是最要紧的一个：
    /// 协议默认值已改为 fail-closed，**不覆写这一条，iOS 上 AI 就写不了任何文件**；
    /// 而在默认值还是 `true` 的年代，不覆写的结果是 AI 静默改掉用户的文档。
    /// 两个方向都不可接受，所以这里显式接 UI。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool {
        if gate.allowAllForRun { return true }
        return await gate.request(path: path, summary: summary)
    }

    /// 丢弃 diff 预览，转交 path/summary 版本——移动端没有段落级审阅面。
    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        await confirmFileWrite(preview.path, summary: preview.summary)
    }

    var isFileWriteAllowedForRun: Bool { gate.allowAllForRun }

    func cancelPendingWriteConfirmation() { gate.cancelPending() }
}
