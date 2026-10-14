import Foundation
import Observation

/// 当前打开文档的状态 + AI 写入/撤销 + 文件操作（创建/重命名/删除）。
/// 最近文档列表管理委托给 RecentHistory。
@MainActor
@Observable
final class DocumentStore {

    // MARK: - 子服务

    /// 最近文档列表与工作区管理（注入可测试）。
    let recents: RecentHistory

    // MARK: - 文档内容

    private(set) var text: String = ""
    var fileName: String = ""
    /// 当前文档的磁盘 URL（工作区内或沙盒外原地打开的原始位置）。
    private(set) var sandboxURL: URL? = nil
    /// 沙盒外文档（iCloud Drive 等）的 security-scoped bookmark；nil 表示工作区内文档。
    private(set) var externalBookmark: Data? = nil
    var lastError: String? = nil
    var showPreview: Bool = true

    var hasDocument: Bool { sandboxURL != nil }
    /// 当前文档是否沙盒外原地打开（iCloud Drive / 其他文件 Provider）。
    var isExternalDocument: Bool { externalBookmark != nil }

    /// 上次打开文档（重启后恢复）：工作区内存相对路径，沙盒外存 bookmark。
    private static let lastDocKey = "lastDocumentRelativePath"
    private static let lastDocBookmarkKey = "lastDocumentBookmark"

    /// 沙盒外文档持有的 security scope（关闭/切换文档时释放）。
    private var scopedURL: URL? = nil

    var workspace: URL { recents.workspace }

    // MARK: - Init

    init(recents: RecentHistory) {
        self.recents = recents
        // 优先恢复沙盒外文档（bookmark），失败再退回工作区相对路径。
        if let bookmark = UserDefaults.standard.data(forKey: Self.lastDocBookmarkKey),
           restoreExternal(bookmark: bookmark) {
            // 已通过 bookmark 恢复
        } else if let rel = UserDefaults.standard.string(forKey: Self.lastDocKey) {
            let url = workspace.appendingPathComponent(rel)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                sandboxURL = url
                fileName   = url.lastPathComponent
                text       = content
                recents.touchRecent(url)
            }
        }
        recents.refreshWorkspaceDocuments()
    }

    // MARK: - Document kind

    enum ContentKind: String { case markdown, html, other }

    var kind: ContentKind {
        switch (sandboxURL?.pathExtension ?? fileName.split(separator: ".").last.map(String.init) ?? "").lowercased() {
        case "md", "markdown": return .markdown
        case "html", "htm":    return .html
        default:               return .other
        }
    }

    // MARK: - 打开文件

    private static let maxFileBytes = 10 * 1024 * 1024

    /// 处理 fileImporter / .onOpenURL 传入的文件。
    /// 工作区内文件直接打开；沙盒外文件（iCloud Drive 等）原地打开并持久化 bookmark，
    /// 编辑直接写回原位置，不再复制进沙盒。
    func openIncoming(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        // 沙盒外原地打开时要继续持有 scope，成功后不 stop（由 scopedURL 管理生命周期）。
        var keepScope = false
        defer { if scoped && !keepScope { url.stopAccessingSecurityScopedResource() } }
        startDownloadingIfUbiquitous(url)
        guard let content = readFileContent(url) else { return }

        if isInsideWorkspace(url) {
            setCurrentDocument(url: url, content: content, bookmark: nil)
            return
        }
        // 沙盒外：创建 security-scoped bookmark 以便跨启动恢复访问。
        guard let bookmark = try? url.bookmarkData() else {
            lastError = "无法保存文件访问权限：\(url.lastPathComponent)"
            return
        }
        setCurrentDocument(url: url, content: content, bookmark: bookmark)
        if scoped {
            scopedURL = url
            keepScope = true
        }
    }

    /// 打开一条最近记录（列表点击 / 快捷动作）。沙盒外记录走 bookmark 解析。
    @discardableResult
    func openRecent(_ doc: RecentHistory.RecentDocument) -> Bool {
        guard let bookmark = doc.bookmarkData else {
            return loadFromSandbox(workspace.appendingPathComponent(doc.relativePath))
        }
        return openExternal(bookmark: bookmark, knownRel: doc.relativePath)
    }

    /// 通过 bookmark 打开沙盒外文档；stale 时重建书签并更新记录。
    /// knownRel：最近记录中的标识（用于 stale 时回写），无则不回写。
    private func openExternal(bookmark: Data, knownRel: String? = nil) -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            if let knownRel { recents.remove(knownRel) }
            lastError = "文件已被移动或删除，无法恢复访问。"
            return false
        }
        let scoped = url.startAccessingSecurityScopedResource()
        var keepScope = false
        defer { if scoped && !keepScope { url.stopAccessingSecurityScopedResource() } }
        startDownloadingIfUbiquitous(url)
        guard let content = readFileContent(url) else { return false }

        var effectiveBookmark = bookmark
        if stale, let renewed = try? url.bookmarkData() {
            effectiveBookmark = renewed
            if let knownRel {
                recents.updateExternalEntry(oldRel: knownRel, url: url, bookmark: renewed)
            }
        }
        setCurrentDocument(url: url, content: content, bookmark: effectiveBookmark)
        if scoped {
            scopedURL = url
            keepScope = true
        }
        return true
    }

    /// 启动时通过 bookmark 恢复上次打开的沙盒外文档。
    private func restoreExternal(bookmark: Data) -> Bool {
        openExternal(bookmark: bookmark)
    }

    /// iCloud 占位文件（未下载到本地）：先触发下载再读。
    private func startDownloadingIfUbiquitous(_ url: URL) {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let base = workspace.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base + "/")
    }

    /// 读取文件内容（10MB 上限 + 编码 fallback），失败时设置 lastError 并返回 nil。
    ///
    /// 上限必须**在执行读取时**生效：早期实现是 `Data(contentsOf:)` 全量读入后再判
    /// `data.count`，上限形同虚设——一个 2GB 文件会先把 2GB 全部搬进内存才被拒绝，
    /// 足以直接 OOM（且 iOS 上无从恢复）。这里改为有硬上限的分块读取：任何文件最多
    /// 只分配 `maxFileBytes + 1` 字节，超限即拒绝。
    private func readFileContent(_ url: URL) -> String? {
        let limit = Self.maxFileBytes
        let data: Data
        do {
            // 预检磁盘大小：命中上限时连读都不读（iCloud 占位文件的 fileSize 不可信，
            // 所以这层只是快路径，真正的保证仍由下面的分块读取兜底）。
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > limit {
                lastError = "文件过大（超过 10 MB），暂不支持打开：\(url.lastPathComponent)"
                return nil
            }
            // 分块读到上限 +1 字节：只要多出 1 字节即可判定超限，无需读完整文件。
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var buffer = Data()
            while buffer.count <= limit {
                guard let chunk = try handle.read(upToCount: limit + 1 - buffer.count),
                      !chunk.isEmpty else { break }
                buffer.append(chunk)
            }
            guard buffer.count <= limit else {
                lastError = "文件过大（超过 10 MB），暂不支持打开：\(url.lastPathComponent)"
                return nil
            }
            data = buffer
        } catch {
            lastError = "打开失败：\(error.localizedDescription)"
            return nil
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if data.prefix(8 * 1024).contains(0) {
            lastError = "不支持二进制文件：\(url.lastPathComponent)"
            return nil
        }
        guard let legacy = String(data: data, encoding: .isoLatin1) else {
            lastError = "无法解码文件：\(url.lastPathComponent)"
            return nil
        }
        return legacy
    }

    /// 切换当前文档：**先落盘上一篇的待保存内容**、释放上一个 security scope，
    /// 再写入新状态并记忆。
    ///
    /// 早期实现在这里直接 `autosaveTask?.cancel()`：用户在 800ms 防抖窗口内敲的字
    /// 会被静默丢弃（`renameDocument` 反而会先 flush，说明这是漏改而非有意）。
    private func setCurrentDocument(url: URL, content: String, bookmark: Data?) {
        // 打开的就是当前文档：保留内存内容（可能含尚未落盘的编辑），
        // 不要用磁盘上的旧内容把它覆盖掉。
        if let current = sandboxURL, current.standardizedFileURL == url.standardizedFileURL {
            return
        }
        let saveError = flushPendingAutosave()
        releaseScope()
        sandboxURL = url
        fileName = url.lastPathComponent
        text = content
        externalBookmark = bookmark
        // 不吞掉上一文档的保存失败：宁可让用户看到错误，也不静默丢内容
        lastError = saveError
        remember(url, bookmark: bookmark)
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: - 新建 / 加载

    func createDocument() {
        var name = "未命名.md"
        var n = 2
        while FileManager.default.fileExists(atPath: workspace.appendingPathComponent(name).path) {
            name = "未命名-\(n).md"
            n += 1
        }
        let url = workspace.appendingPathComponent(name)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            // 新建前先把上一文档的待保存内容落盘（同 setCurrentDocument，避免丢写）
            let saveError = flushPendingAutosave()
            releaseScope()
            sandboxURL = url
            fileName   = name
            text       = ""
            externalBookmark = nil
            showPreview = false
            lastError  = saveError
            remember(url)
        } catch {
            lastError = "新建失败：\(error.localizedDescription)"
        }
    }

    func loadFromSandbox(_ url: URL) -> Bool {
        // 已是当前文档：保留内存内容，不重读磁盘（否则会覆盖未落盘的编辑）
        if let current = sandboxURL, current.standardizedFileURL == url.standardizedFileURL {
            return true
        }
        // 先 flush 再读新文件——顺序反了会把用户刚敲的字读回旧版本
        let saveError = flushPendingAutosave()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = saveError
            return false
        }
        releaseScope()
        sandboxURL = url
        fileName   = url.lastPathComponent
        text       = content
        externalBookmark = nil
        lastError  = saveError
        remember(url)
        return true
    }

    private func remember(_ url: URL, bookmark: Data? = nil) {
        if let bookmark {
            // 沙盒外文档：恢复入口是 bookmark，不是相对路径。
            UserDefaults.standard.set(bookmark, forKey: Self.lastDocBookmarkKey)
            UserDefaults.standard.removeObject(forKey: Self.lastDocKey)
            recents.touchRecent(url, bookmark: bookmark)
        } else {
            UserDefaults.standard.set(relativePath(for: url), forKey: Self.lastDocKey)
            UserDefaults.standard.removeObject(forKey: Self.lastDocBookmarkKey)
            recents.touchRecent(url)
        }
    }

    private func relativePath(for url: URL) -> String {
        let base = workspace.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    // MARK: - 重命名 / 删除

    @discardableResult
    func renameDocument(at rel: String, to newBaseName: String) -> String? {
        // 沙盒外文档（relativePath 为完整路径）不支持在 App 内重命名/移动。
        guard !rel.hasPrefix("/") else { return nil }
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oldURL = workspace.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: oldURL.path) else { return nil }

        let ext = (rel as NSString).pathExtension
        let dir = (rel as NSString).deletingLastPathComponent
        let dirURL = dir.isEmpty || dir == "." ? workspace : workspace.appendingPathComponent(dir, isDirectory: true)
        let desired = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        if desired == oldURL.lastPathComponent { return desired }
        var candidate = desired
        var n = 2
        while FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(trimmed)-\(n)" : "\(trimmed)-\(n).\(ext)"
            n += 1
        }
        let newURL = dirURL.appendingPathComponent(candidate)
        let isCurrent = sandboxURL?.standardizedFileURL == oldURL.standardizedFileURL
        if isCurrent {
            // 重命名前先落盘：写失败就不再搬移，避免把旧内容搬到新路径
            if let saveError = flushPendingAutosave() {
                lastError = saveError
                return nil
            }
        }
        // 搬移失败不能再静默：此前 try? 让「名字没变但文件也没动」与「参数非法」
        // 对调用方完全同形（都只返回 nil），用户看到的是「点了重命名没反应」。
        // lastError 在 iOS 侧是 String?（桌面端是 Error?），按本文件既有风格取
        // localizedDescription 拼可读消息（对照上面「打开失败：…」）。
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            lastError = "重命名失败：\(error.localizedDescription)"
            return nil
        }

        let newRel = relativePath(for: newURL)
        recents.updatePath(old: rel, new: newRel, newName: candidate)
        if isCurrent {
            sandboxURL = newURL
            fileName   = candidate
            UserDefaults.standard.set(newRel, forKey: Self.lastDocKey)
        }
        return candidate
    }

    func deleteDocument(at rel: String) {
        // 沙盒外文档（relativePath 为完整路径）不支持在 App 内删除。
        guard !rel.hasPrefix("/") else { return }
        let url = workspace.appendingPathComponent(rel)
        let wasCurrent = sandboxURL?.standardizedFileURL == url.standardizedFileURL
        try? FileManager.default.removeItem(at: url)
        recents.remove(rel)
        if wasCurrent {
            // 文档已删除，待保存内容随之作废
            discardPendingAutosave()
            releaseScope()
            sandboxURL = nil
            fileName   = ""
            text       = ""
            externalBookmark = nil
            aiSnapshot = nil
            aiFinalText = nil
            UserDefaults.standard.removeObject(forKey: Self.lastDocKey)
        }
    }

    // MARK: - AI 写入 / 撤销

    private(set) var aiSnapshot: String? = nil
    private(set) var aiFinalText: String? = nil
    var canUndoAI: Bool { aiSnapshot != nil && aiFinalText == text }

    func beginAIRun() { aiSnapshot = nil; aiFinalText = nil }

    func noteAIReplace(_ newContent: String) throws {
        if aiSnapshot == nil { aiSnapshot = text }
        try replaceContent(newContent)
        aiFinalText = text
    }

    func undoAIChanges() {
        guard let snapshot = aiSnapshot else { return }
        do {
            try replaceContent(snapshot)
            aiSnapshot = nil; aiFinalText = nil
        } catch {
            print("[DocumentStore] 撤销 AI 改动写盘失败：\(error.localizedDescription)")
            lastError = "撤销失败：\(error.localizedDescription)"
        }
    }

    /// 最近一次自动保存的时间（UI 展示用）。
    var lastSavedAt: Date = .distantPast

    func replaceContent(_ newContent: String) throws {
        guard let url = sandboxURL else { throw AgentContextError.noActiveDocument }
        try writeText(newContent, to: url)
        // 内容已直接落盘，防抖任务及其待保存标记一并作废
        discardPendingAutosave()
        text = newContent
    }

    /// 写盘统一入口。沙盒外文档（iCloud Drive 等 ubiquitous 位置）用
    /// NSFileCoordinator 协调写入，避免与 iCloud 同步守护进程打架；
    /// 此时 security scope 由 scopedURL 持有，协调块内直接写即可。
    ///
    /// 判据是 `externalBookmark != nil` **或** `isUbiquitousItem`：
    /// 早先只判 bookmark——workspace 本身位于 iCloud Drive 时，其中的文档没有
    /// security-scoped bookmark（externalBookmark == nil）但仍是 ubiquitous item，
    /// 旧判据下直写绕过协调，与同步守护进程打架（丢更新 / 冲突副本）。
    /// isUbiquitousItem 的判定与 openDocument 的下载检查是同一把尺子。
    private func writeText(_ text: String, to url: URL) throws {
        guard externalBookmark != nil || Self.isUbiquitousItem(url) else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: [], error: &coordError
        ) { newURL in
            do {
                try text.write(to: newURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordError { throw coordError }
    }

    /// ubiquitous item 判定（resourceValues）。与 openDocument 的下载检查
    /// （`.isUbiquitousItemKey`）同一把尺子；取不到资源值时按非 ubiquitous 处理
    /// （保守：本地文件不会因为这个误判，iCloud 文件拿不到资源值的场景不存在）。
    private static func isUbiquitousItem(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]) else { return false }
        return values.isUbiquitousItem == true
    }

    func reloadIfCurrent(_ url: URL) {
        guard url.standardizedFileURL == sandboxURL?.standardizedFileURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content
    }

    // MARK: - 自动保存

    private static let autosaveDelayNanos: UInt64 = 800_000_000
    private var autosaveTask: Task<Void, Never>?
    /// 是否有「已改动但尚未落盘」的内容（防抖窗口内的编辑）。
    /// 切换/新建文档前据此决定要不要先 flush，避免静默丢写。
    private var pendingAutosave = false

    func applyManualEdit(_ newText: String) {
        text = newText
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        guard let url = sandboxURL else { return }
        pendingAutosave = true
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: Self.autosaveDelayNanos)
            guard !Task.isCancelled else { return }
            do {
                try self.writeText(self.text, to: url)
                self.lastSavedAt = Date()
                self.pendingAutosave = false
            } catch {
                print("[DocumentStore] 自动保存失败：\(error.localizedDescription)")
                self.lastError = "自动保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// 立刻把待保存内容写盘（若有）。返回错误文案，成功或无待保存内容时返回 nil。
    /// 必须在**改动 sandboxURL / externalBookmark 之前**调用——写盘目标与
    /// security scope 都还指向旧文档（协调写入判据见 writeText 的注释）。
    private func flushPendingAutosave() -> String? {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard pendingAutosave, let url = sandboxURL else { return nil }
        pendingAutosave = false
        do {
            try writeText(text, to: url)
            lastSavedAt = Date()
            return nil
        } catch {
            print("[DocumentStore] 切换文档前保存失败：\(error.localizedDescription)")
            return "保存失败：\(error.localizedDescription)"
        }
    }

    /// 丢弃待保存内容（仅在文档内容不再需要写回时使用，例如文档被删除或已被替换）。
    private func discardPendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        pendingAutosave = false
    }
}
