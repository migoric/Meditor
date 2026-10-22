import Foundation
import Observation
import OSLog

/// Owns all tab state and lifecycle operations.
///
/// Cross-cutting concerns (preview sync, sidebar selection, security-scope access)
/// are injected as closures so TabManager has zero dependency on AppState itself.
/// AppState wires these up in its init and forwards its public properties/methods
/// to TabManager so the View layer is unchanged.
@MainActor
@Observable
final class TabManager {

    // MARK: - State

    var openTabs: [EditorTab] = [] {
        didSet { onOpenTabsChanged?() }
    }

    var selectedTabID: UUID? {
        didSet { onSelectedTabIDChanged?() }
    }

    var pendingCloseTab: EditorTab?
    var showingCloseConfirmation = false
    /// 批量关闭时排队等待确认的 dirty tab（见 closeTab/confirmCloseTab）。
    @ObservationIgnored private var pendingCloseQueue: [EditorTab] = []
    var pendingLargeFile: FileItem?
    var showingLargeFileWarning = false

    @ObservationIgnored var recentlyClosedURLs: [URL] = []
    static let recentlyClosedLimit = 16
    static let largeFileThreshold: Int64 = 1024 * 1024

    // MARK: - Pure dependencies

    let fileService: FileServiceProtocol

    // MARK: - Cross-cutting callbacks (wired by AppState.init)

    /// Called whenever `openTabs` changes (e.g. tab added/removed).
    var onOpenTabsChanged: (() -> Void)?
    /// Called whenever `selectedTabID` changes.
    var onSelectedTabIDChanged: (() -> Void)?
    /// Called after a content mutation that doesn't change `openTabs` itself.
    var onScheduleSessionPersist: (() -> Void)?

    /// Tell the preview manager to sync content from this tab.
    var onSyncPreview: ((EditorTab) -> Void)?
    /// A tab's content was just written to disk (manual save / auto-save).
    /// Used to refresh disk-backed previews (HTML) for the same file.
    var onDidWriteToDisk: ((URL) -> Void)?
    /// 保存成功后携带内容回调（本地历史快照用，AppState 接线）。
    var onDidWriteContent: ((URL, String) -> Void)?
    /// Clear the preview (no active tab).
    var onClearPreview: (() -> Void)?
    /// Update the sidebar's selected file to match the given tab.
    var onSyncSidebarSelection: ((EditorTab) -> Void)?
    /// Update `selectedFileID` on AppState.
    var onSetSelectedFileID: ((URL?) -> Void)?
    /// Begin security-scoped access.
    var onBeginAccessing: ((URL) -> Void)?
    /// End security-scoped access.
    var onEndAccessing: ((URL) -> Void)?
    /// Returns true if the URL is outside the project root (sandbox).
    var onRequiresDirectFileAccess: ((URL) -> Bool)?
    /// Record the last-known modification date for external-change detection.
    var onRecordModDate: ((URL) -> Void)?
    /// Surface an error to the user.
    var onReport: ((AppError) -> Void)?
    var onDidSave: (() -> Void)?

    // MARK: - Init

    init(fileService: FileServiceProtocol) {
        self.fileService = fileService
    }

    // MARK: - Computed

    var selectedTab: EditorTab? { openTabs.first { $0.id == selectedTabID } }

    /// 同一文件的不同 URL 写法（`/tmp` vs `/private/tmp`、尾斜杠、
    /// 百分号编码等）视为同一个 tab，避免 GURL/拖拽等外部入口开出重复 tab。
    static func urlsReferToSameFile(_ a: URL, _ b: URL) -> Bool {
        if a == b { return true }
        return a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Open

    func openFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        let attrs = fileService.attributes(at: item.url)
        if let size = attrs?[.size] as? Int64, size > Self.largeFileThreshold {
            pendingLargeFile = item
            showingLargeFileWarning = true
            return
        }
        openFileUnchecked(item)
    }

    func openFileUnchecked(_ item: FileItem) {
        let sid = PerformanceTracer.begin("OpenFile", log: PerformanceTracer.fileOps)
        let needsDirectAccess = onRequiresDirectFileAccess?(item.url) ?? true
        if needsDirectAccess { onBeginAccessing?(item.url) }
        onSetSelectedFileID?(item.id)

        if let existing = openTabs.first(where: { Self.urlsReferToSameFile($0.url, item.url) }) {
            if needsDirectAccess { onEndAccessing?(item.url) }
            selectedTabID = existing.id
            onSyncPreview?(existing)
            PerformanceTracer.end("OpenFile", log: PerformanceTracer.fileOps, id: sid)
            return
        }

        let lang = FileTypeConfiguration.shared.editorLanguage(for: item.fileExtension) ?? .markdown

        // 小文件同步读、带内容建 tab：避免「空白骨架 → 内容」的两段式渲染
        // （异步跳转至少隔一两个 runloop，肉眼可见闪一下）。大文件仍走异步，
        // 不阻塞主线程。
        let syncThreshold: Int64 = 512 * 1024
        let fileSize = (fileService.attributes(at: item.url)?[.size] as? Int64) ?? .max
        if fileSize <= syncThreshold, let content = try? fileService.readFile(at: item.url) {
            let tab = EditorTab(url: item.url, content: content, language: lang)
            openTabs.insert(tab, at: 0)
            selectedTabID = tab.id
            onRecordModDate?(tab.url)
            onSyncPreview?(tab)
            PerformanceTracer.end("OpenFile", log: PerformanceTracer.fileOps, id: sid)
            return
        }

        let tab = EditorTab(url: item.url, content: "", language: lang, awaitingInitialContent: true)
        openTabs.insert(tab, at: 0)
        selectedTabID = tab.id
        onSyncPreview?(tab)

        let tabID = tab.id
        let url   = item.url
        let svc   = fileService

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let content = try svc.readFile(at: url)
                await self?.applyLoadedContent(tabID: tabID, content: content)
            } catch {
                await self?.failLoadingTab(tabID: tabID, url: url, error: error)
            }
            await MainActor.run {
                PerformanceTracer.end("OpenFile", log: PerformanceTracer.fileOps, id: sid)
            }
        }
    }

    func applyLoadedContent(tabID: UUID, content: String) {
        guard let tab = openTabs.first(where: { $0.id == tabID }),
              tab.awaitingInitialContent else { return }
        tab.content = content
        tab.contentRevision &+= 1
        tab.awaitingInitialContent = false
        onRecordModDate?(tab.url)
        // 恢复会话时 tab 先以空内容入列（awaitingInitialContent），内容在这里才回填。
        // 两种语言都要把内容推给预览：markdown 靠 contentRevision，HTML 靠 reloadToken
        // （PreviewManager.showHTML）。此前这里只放行 markdown，HTML tab 的预览就停在
        // 入场那次「加载空内容」上——表现为冷启动白屏，切一下 tab 才渲染（切 tab 会走
        // onSyncPreview）。是否真的会重载由 PreviewManager 自己按内容 diff 决定，幂等。
        if selectedTabID == tabID { onSyncPreview?(tab) }
    }

    func failLoadingTab(tabID: UUID, url: URL, error: Error) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }),
              openTabs[idx].awaitingInitialContent else {
            onReport?(.fileRead(url, underlying: error))
            return
        }
        let closingURL  = openTabs[idx].url
        let wasSelected = selectedTabID == tabID
        openTabs.remove(at: idx)
        onEndAccessing?(closingURL)

        if wasSelected {
            if idx < openTabs.count      { selectedTabID = openTabs[idx].id }
            else if !openTabs.isEmpty    { selectedTabID = openTabs.last?.id }
            else                         { selectedTabID = nil; onClearPreview?() }
            if let t = selectedTab { onSyncSidebarSelection?(t); onSyncPreview?(t) }
            else                   { onSetSelectedFileID?(nil) }
        }
        onReport?(.fileRead(url, underlying: error))
    }

    // MARK: - Close

    func closeTab(_ tabID: UUID) {
        guard let tab = openTabs.first(where: { $0.id == tabID }) else { return }
        if tab.isModified {
            // 已有确认框在展示时把后续 dirty tab 排队，逐个确认——
            // 否则「关闭其他/全部」时单槽 pendingCloseTab 只保留最后一个，
            // 前面的 dirty tab 既不确认也不关闭。
            if showingCloseConfirmation {
                pendingCloseQueue.append(tab)
            } else {
                pendingCloseTab = tab
                showingCloseConfirmation = true
            }
            return
        }
        performCloseTab(tabID)
    }

    /// 关闭除 `tabID` 外的所有 tab（dirty 的逐个弹确认）。
    func closeOtherTabs(keeping tabID: UUID) {
        for id in openTabs.map(\.id) where id != tabID { closeTab(id) }
    }

    /// 关闭全部 tab（dirty 的逐个弹确认）。
    func closeAllTabs() {
        for id in openTabs.map(\.id) { closeTab(id) }
    }

    func confirmCloseTab(save: Bool) {
        guard let tab = pendingCloseTab else { return }
        if save { saveTab(tab) }
        performCloseTab(tab.id)
        pendingCloseTab = nil
        showingCloseConfirmation = false
        presentNextPendingCloseIfNeeded()
    }

    /// 依次处理排队中的关闭请求：clean 直接关，dirty 重新弹确认。
    private func presentNextPendingCloseIfNeeded() {
        while !pendingCloseQueue.isEmpty {
            let next = pendingCloseQueue.removeFirst()
            guard openTabs.contains(where: { $0.id == next.id }) else { continue }
            if next.isModified {
                // 等当前 confirmationDialog 完成 dismiss 后再置位，避免同帧内重复展示被吞
                Task { @MainActor [weak self] in
                    guard let self, self.pendingCloseTab == nil else { return }
                    self.pendingCloseTab = next
                    self.showingCloseConfirmation = true
                }
                return
            }
            performCloseTab(next.id)
        }
    }

    func performCloseTab(_ tabID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closingURL = openTabs[idx].url
        openTabs.remove(at: idx)
        onEndAccessing?(closingURL)

        recentlyClosedURLs.append(closingURL)
        if recentlyClosedURLs.count > Self.recentlyClosedLimit { recentlyClosedURLs.removeFirst() }

        if selectedTabID == tabID {
            if idx < openTabs.count   { selectedTabID = openTabs[idx].id }
            else if !openTabs.isEmpty { selectedTabID = openTabs.last?.id }
            else                      { selectedTabID = nil; onClearPreview?() }
        }
        if let t = selectedTab { onSyncSidebarSelection?(t); onSyncPreview?(t) }
        else                   { onSetSelectedFileID?(nil) }
    }

    // MARK: - Content

    func updateTabContent(_ tabID: UUID, content: String) {
        guard let tab = openTabs.first(where: { $0.id == tabID }) else { return }
        tab.content = content
        tab.contentRevision &+= 1
        tab.isModified = true
        tab.awaitingInitialContent = false
        onScheduleSessionPersist?()
        if selectedTabID == tabID { onSyncPreview?(tab) }
    }

    /// 一次进行中的写盘：task 用于串联同 URL 的保存顺序，id 用于完成后的安全清理。
    private struct PendingSave {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// 每个 URL 最近一次写盘的记录，用于把同一文件的并发保存串成链：
    /// 自动保存 / 2s 防抖 / 手动 ⌘S 三条路径可能对同一 URL 并发触发写盘，
    /// 若不串行化，先发的旧内容可能后完成 rename、覆盖新内容（评审 M1）。
    @ObservationIgnored private var pendingSaves: [URL: PendingSave] = [:]

    func saveTab(_ tab: EditorTab) {
        guard tab.isModified else { return }
        // 乐观更新 UI：先清除修改标记，避免用户连续触发多次写入
        tab.isModified = false
        let content  = tab.content
        let url      = tab.url
        let svc      = fileService
        let previous = pendingSaves[url]?.task
        let saveID   = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // 等同一 URL 的上一次写盘完成，保证落盘顺序与保存触发顺序一致
            _ = await previous?.value
            defer {
                // 清理链条尾部条目（仅当仍是自己，避免误删更新的任务），防止字典无限增长
                Task { @MainActor [weak self] in
                    guard let self, self.pendingSaves[url]?.id == saveID else { return }
                    self.pendingSaves[url] = nil
                }
            }
            do {
                try svc.writeFile(at: url, content: content)
                await self?.didSaveTab(tab, url: url)
            } catch {
                // 写入失败：回滚修改标记并报错
                await self?.didFailSaveTab(tab, url: url, error: error)
            }
        }
        pendingSaves[url] = PendingSave(id: saveID, task: task)
    }

    @MainActor
    private func didSaveTab(_ tab: EditorTab, url: URL) {
        if tab.id == selectedTabID { onSyncPreview?(tab) }
        onDidWriteToDisk?(url)
        onDidWriteContent?(url, tab.content)
        onDidSave?()
    }

    /// 退出前等待所有已排队写盘真正落盘（applicationShouldTerminate 用）。
    /// 有界循环：等待期间理论上不再产生新写入，兜底防死循环。
    func flushPendingSaves() async {
        for _ in 0..<3 {
            let tasks = pendingSaves.values.map(\.task)
            if tasks.isEmpty { return }
            for task in tasks { _ = await task.value }
        }
    }

    @MainActor
    private func didFailSaveTab(_ tab: EditorTab, url: URL, error: Error) {
        tab.isModified = true   // 回滚乐观更新
        onReport?(.fileWrite(url, underlying: error))
    }

    func saveCurrentTab() {
        guard let tab = selectedTab else { return }
        saveTab(tab)
    }

    // MARK: - Selection

    func selectTab(_ id: UUID) {
        selectedTabID = id
        if let tab = selectedTab { onSyncSidebarSelection?(tab); onSyncPreview?(tab) }
    }

    func syncSidebarSelectionToTab(_ tab: EditorTab) {
        // Sidebar selection is AppState.selectedFileID; we just notify the coordinator.
        onSyncSidebarSelection?(tab)
    }

    // MARK: - Navigation

    func reopenLastClosedTab() {
        while let url = recentlyClosedURLs.popLast() {
            guard fileService.fileExists(at: url) else { continue }
            if openTabs.contains(where: { $0.url == url }) { continue }
            openFile(FileItem(url: url, isDirectory: false))
            return
        }
    }

    func selectNextTab() {
        guard openTabs.count > 1, let id = selectedTabID,
              let idx = openTabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(openTabs[(idx + 1) % openTabs.count].id)
    }

    func selectPreviousTab() {
        guard openTabs.count > 1, let id = selectedTabID,
              let idx = openTabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(openTabs[(idx - 1 + openTabs.count) % openTabs.count].id)
    }

    func moveTab(from src: Int, to dst: Int) {
        guard src >= 0, src < openTabs.count,
              dst >= 0, dst < openTabs.count else { return }
        let tab = openTabs.remove(at: src)
        openTabs.insert(tab, at: dst)
    }
}
