import Foundation

// MARK: - CommandApprovalStore（跨 context 共享的命令审批缓存）

/// safe 命令的"批准一次不再弹框"缓存。此前放在 AgentContext 实例上，
/// 但 macOS 每轮消息都新建 context（AIChatCoordinator.make）→ 每条消息重弹；
/// iOS 端 context 活整个会话、缓存真有效。提成引用类型后两端一致：
/// 整个 App 会话内同一命令只确认一次。
final class CommandApprovalStore: @unchecked Sendable {
    private var keys: Set<String> = []
    private let lock = NSLock()
    func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.contains(key)
    }
    func insert(_ key: String) {
        lock.lock(); keys.insert(key); lock.unlock()
    }
}

// MARK: - AgentContext（薄协调层）

// PatchNotFoundError / AgentContextError 已上移至 AgentFileRepository.swift（iOS 共享编译）。

/// 把 AgentFileRepository（纯磁盘 IO）和 AgentDocumentAdapter（AppState 交互）
/// 组合成工具层所需的 AgentContextProtocol。
///
/// 自身不含业务逻辑 — 逻辑分别在 PatchEngine / AgentFileRepository / AgentDocumentAdapter 中，
/// 均可独立单测。
@MainActor
final class AgentContext: AgentContextProtocol {

    let files: any AgentFileRepository
    let doc:   any AgentDocumentAdapter
    /// 命令审批缓存（可注入共享实例；默认独立）。
    let approvals: CommandApprovalStore
    /// run 级文件快照（一键回滚用）。由 run 发起方按 run 创建注入；
    /// nil = 不记录（测试 / 非 run 场景）。
    let checkpoint: AgentRunCheckpoint?

    init(files: any AgentFileRepository, doc: any AgentDocumentAdapter,
         approvals: CommandApprovalStore = CommandApprovalStore(),
         checkpoint: AgentRunCheckpoint? = nil) {
        self.files = files
        self.doc   = doc
        self.approvals = approvals
        self.checkpoint = checkpoint
    }

    /// 工厂方法：从 AppState 创建标准 AgentContext（App 侧调用）
    /// 审批缓存共享 AppState 的会话级实例，safe 命令批准一次全 session 有效。
    static func make(appState: AppState, checkpoint: AgentRunCheckpoint? = nil) -> AgentContext {
        let repo    = DefaultAgentFileRepository(
            { [weak appState] in appState?.rootURL },
            indexProvider: { [weak appState] in appState?.workspaceIndex }
        )
        let adapter = AppStateDocumentAdapter(appState: appState, fileRepo: repo)
        return AgentContext(files: repo, doc: adapter, approvals: appState.commandApprovals,
                            checkpoint: checkpoint)
    }

    // MARK: - Current document → doc

    var currentDocument: String?     { doc.currentDocument }
    var currentDocumentName: String? { doc.currentDocumentName }
    var workspaceURL: URL?           { doc.workspaceURL }
    /// 当前 tab 身份（写工具的 tab 锁定校验用，见 DocumentContext.currentTabID）
    var currentTabID: UUID?          { doc.currentTabID }

    /// 当前文档全量重写（= 当前 tab 内容替换）。快照记 tab 写前原文
    /// （tab 内存内容是用户视角的最新内容，含未保存编辑）。
    func writeDocument(_ content: String) throws {
        let tabURL = doc.currentTabURL
        if let tabURL, let pre = doc.currentDocument {
            checkpoint?.captureBeforeWrite(url: tabURL, knownContent: pre)
        }
        try doc.writeDocument(content)
        if let tabURL { checkpoint?.markWritten(url: tabURL, content: content) }
    }
    /// 插入到当前文档。与 writeDocument / patchDocument 同一取舍：快照记 tab 写前原文，
    /// 否则「撤销本次运行的全部修改」覆盖不到插入（步骤面板会漏掉这类改动）。
    func insertIntoDocument(_ text: String) {
        let tabURL = doc.currentTabURL
        if let tabURL, let pre = doc.currentDocument {
            checkpoint?.captureBeforeWrite(url: tabURL, knownContent: pre)
        }
        doc.insertIntoDocument(text)
        if let tabURL, let post = doc.currentDocument {
            checkpoint?.markWritten(url: tabURL, content: post)
        }
    }

    func patchDocument(find: String, replace: String, all: Bool) throws -> Int {
        let tabURL = doc.currentTabURL
        if let tabURL, let pre = doc.currentDocument {
            checkpoint?.captureBeforeWrite(url: tabURL, knownContent: pre)
        }
        let count = try doc.patchDocument(find: find, replace: replace, all: all)
        if let tabURL, let post = doc.currentDocument {
            checkpoint?.markWritten(url: tabURL, content: post)
        }
        return count
    }

    // MARK: - File IO → files

    func listWorkspaceFiles(extensions: [String]) async -> [URL] {
        await files.listWorkspaceFiles(extensions: extensions)
    }

    func readFile(at url: URL) async throws -> String {
        try validateReadTarget(url)
        return try await files.readFile(at: url)
    }

    func searchWorkspace(query: String, extensions: [String]) async -> [String] {
        await files.searchWorkspace(query: query, extensions: extensions)
    }

    // MARK: - fileContentFull（桥接：Tab 内容优先，否则完整读盘）

    func fileContentFull(at url: URL) async throws -> String {
        try validateReadTarget(url)
        if let tabContent = doc.contentForTab(at: url) { return tabContent }
        return try await files.readDiskFull(at: url)
    }

    // MARK: - resolveFile（加 Tab 优先级排序）

    func resolveFile(_ name: String) -> FileResolveResult {
        let result = files.resolveFile(name)
        guard case .ambiguous(let urls) = result else { return result }
        let currentURL = doc.currentTabURL
        let sorted = urls.sorted { a, b in
            let aIsCurrent = a.standardizedFileURL == currentURL
            let bIsCurrent = b.standardizedFileURL == currentURL
            if aIsCurrent != bIsCurrent { return aIsCurrent }
            let da = a.pathComponents.count, db = b.pathComponents.count
            return da != db ? da < db : a.path < b.path
        }
        return .ambiguous(sorted)
    }

    // MARK: - File mutations（磁盘 IO + 通知 AppState）

    /// 写入目标合规性校验：必须位于工作区内（与 RunCommandTool 的 cwd 校验
    /// 同一安全边界），或对应一个已打开的 Tab（散文件场景）。
    /// 防止提示注入诱导 Agent 写入 ~/.zshrc 等任意路径。
    func validateWriteTarget(_ url: URL) throws {
        // 解析符号链接后再做前缀比较：standardizedFileURL 只规范化路径、不解析
        // symlink，工作区内一个指向外部目录的 symlink 就能把写目标引到工作区外。
        // root 与 target 两侧都解析（macOS 上 /tmp 本身是 /private/tmp 的 symlink）。
        let target = CommandSandbox.resolveSymlinks(url)
        if let root = workspaceURL.map(CommandSandbox.resolveSymlinks),
           target.path == root.path || target.path.hasPrefix(root.path + "/") {
            return
        }
        // Tab 匹配沿用未解析的标准化路径：AppState 记录的是用户打开时的原始路径
        if doc.hasOpenTab(at: url.standardizedFileURL) { return }
        throw AgentContextError.pathOutsideWorkspace(target.path)
    }

    /// 读取目标合规性校验：与 `validateWriteTarget` 完全对称——必须位于工作区内，
    /// 或对应一个已打开的 Tab。
    ///
    /// 为什么读也要限：写路径已被约束，但读路径此前可以拿任意绝对路径
    /// （`read_file("/Users/x/.aws/credentials")` / `~/.ssh/id_rsa`），
    /// 文件内容会被送进模型 provider 并明文持久化到会话历史；
    /// 配合工作区文档里的提示注入即可诱导模型读取并回显本地密钥。
    func validateReadTarget(_ url: URL) throws {
        let target = CommandSandbox.resolveSymlinks(url)
        if let root = workspaceURL.map(CommandSandbox.resolveSymlinks),
           target.path == root.path || target.path.hasPrefix(root.path + "/") {
            return
        }
        if doc.hasOpenTab(at: url.standardizedFileURL) { return }
        throw AgentContextError.pathOutsideWorkspace(target.path)
    }

    func createFile(name: String, content: String) throws -> URL {
        let target = files.resolveURL(name)
        try validateWriteTarget(target)
        // 快照：文件尚不存在时记「新建」（已存在则下方 createFile 会抛错，不产生写入）
        if !FileManager.default.fileExists(atPath: target.standardizedFileURL.path) {
            checkpoint?.captureCreatedFile(url: target)
        }
        let url = try files.createFile(name: name, content: content)
        checkpoint?.markWritten(url: url, content: content)
        doc.notifyFileCreated(url)
        return url
    }

    func writeFile(name: String, content: String) throws -> URL {
        let target = files.resolveURL(name)
        try validateWriteTarget(target)
        let isNew = !FileManager.default.fileExists(atPath: files.resolveURL(name).path)
        // 快照：新建记「不存在」；覆盖记写前原文（tab 内存内容优先，否则读盘）
        if isNew {
            checkpoint?.captureCreatedFile(url: target)
        } else {
            checkpoint?.captureBeforeWrite(url: target, tabContent: doc.contentForTab(at: target))
        }
        let url   = try files.writeFile(name: name, content: content)
        checkpoint?.markWritten(url: url, content: content)
        doc.notifyFileWritten(url, content: content, isNew: isNew)
        return url
    }

    func createDirectory(name: String) throws -> URL {
        // 不记快照：空目录不含用户内容，回滚语义只覆盖文件内容（与写确认不拦目录创建同级取舍）
        try validateWriteTarget(files.resolveURL(name))
        let url = try files.createDirectory(name: name)
        doc.notifyDirectoryCreated(url)
        return url
    }

    func openFile(named name: String) -> Bool {
        switch resolveFile(name) {
        case .found(let url):
            // 与读取同一约束：否则 open_file 可先把工作区外文件变成「已打开 tab」，
            // 再借 hasOpenTab 绕过 readFile 的读取 confinement。
            guard (try? validateReadTarget(url)) != nil else { return false }
            return doc.openFile(at: url)
        case .ambiguous(let urls):
            guard let first = urls.first, (try? validateReadTarget(first)) != nil else { return false }
            return doc.openFile(at: first)
        case .notFound:
            return false
        }
    }

    // MARK: - patchFile（桥接：Tab 内容优先 → 磁盘 → 通知）

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
        // 快照：patch 已确认能生效再记录（original 即写前原文，tab 优先读出的完整内容）
        checkpoint?.captureBeforeWrite(url: url, knownContent: original)
        try files.writeDisk(updated, to: url)
        checkpoint?.markWritten(url: url, content: updated)
        doc.notifyFileWritten(url, content: updated, isNew: false)
        return cnt
    }

    // MARK: - Command Sandbox

    /// 已批准命令 key 的共享缓存（App 会话级，见 CommandApprovalStore）。
    /// 注意：warn 级命令不写入（每次都弹确认）。
    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool {
        await doc.confirmCommandExecution(command, cwd: cwd)
    }

    func cancelPendingCommandConfirmation() {
        doc.cancelPendingCommandConfirmation()
    }

    // MARK: - File Write Confirmation（与命令确认同一范式，全部转发 doc）

    func confirmFileWrite(_ path: String, summary: String) async -> Bool {
        await doc.confirmFileWrite(path, summary: summary)
    }

    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        await doc.confirmFileWrite(preview)
    }

    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String? {
        await doc.reviewFileWrite(preview, base: base, newContent: newContent)
    }

    func cancelPendingWriteConfirmation() {
        doc.cancelPendingWriteConfirmation()
    }

    /// run 级「全部允许」开关存于 doc adapter（实例随 run 新建，天然 run 级作用域）。
    var isFileWriteAllowedForRun: Bool { doc.isFileWriteAllowedForRun }

    func isCommandApproved(_ key: String) -> Bool {
        approvals.contains(key)
    }

    func markCommandApproved(_ key: String) {
        approvals.insert(key)
    }

    /// 当前执行中的 Skill command 所声明的 shell 命令白名单（前缀匹配）。
    /// nil = 无限制（非 Skill 上下文，或 Skill 未声明 allowedCommands）。
    private var _allowedCommandPatterns: [String]? = nil
    var allowedCommandPatterns: [String]? { _allowedCommandPatterns }

    /// 由 Skill 启动方设置，将当前执行命令的 allowedCommands 注入上下文。
    /// - Parameter patterns: SKILL.md `allowedCommands:` 字段内容；nil 表示无限制。
    func setAllowedCommandPatterns(_ patterns: [String]?) {
        _allowedCommandPatterns = patterns?.isEmpty == false ? patterns : nil
    }
}
