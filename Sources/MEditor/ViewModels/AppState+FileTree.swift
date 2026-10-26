import Foundation

// MARK: - File tree forwarding, CRUD, and cross-domain coordination

extension AppState {

    // MARK: - FileTreeManager forwarding

    var fileTree: [FileItem]           { fileTreeManager.fileTree }
    var fileItemMap: [URL: FileItem]   { fileTreeManager.fileItemMap }
    var indexedFiles: [FileItem]       { fileTreeManager.indexedFiles }

    func reloadFileTree() {
        guard let rootURL else { return }
        fileTreeManager.reload(rootURL: rootURL)
    }

    func loadChildrenIfNeeded(for item: FileItem) { fileTreeManager.loadChildrenIfNeeded(for: item) }
    func isSameOrDescendant(_ url: URL, of base: URL) -> Bool { fileTreeManager.isSameOrDescendant(url, of: base) }
    func replacingDescendantURL(_ url: URL, from old: URL, to new: URL) -> URL? { fileTreeManager.replacingDescendantURL(url, from: old, to: new) }

    // MARK: - Open folder

    func openFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        let previous   = rootURL?.standardizedFileURL
        if previous != normalized { beginAccessing(normalized) }
        if let previous, previous != normalized { endAccessing(previous) }

        tabManager.openTabs.forEach { endAccessing($0.url) }
        tabManager.openTabs.removeAll()
        tabManager.selectedTabID = nil
        selectedFileID = nil
        previewManager.clear()
        // 先加载文件树，再设置 rootURL：ContentView 从 welcomeScreen → mainLayout 时
        // fileTree 已就绪，避免空列表闪烁。rootURL 只设一次——此前在清 tab 之前先设了
        // 一次，会提前触发 didSet（索引重建 / 调度器 reload / share 同步）且带着旧 tab。
        // 全量索引（QuickOpen/@mention）不自建：defersFullIndex 等 rootURL didSet 触发的
        // 工作区扫描（scanWorkspace 一次枚举）把树索引与内容/Spotlight 索引一起分发下来。
        fileTreeManager.reloadFresh(rootURL: url, defersFullIndex: true)
        rootURL = url

        // Git 状态：打开工作区后立即刷新一次（非 git 目录内部静默）
        gitStatusService.refreshNow(rootURL: url)

        fileWatcher.startWatching(urls: [url]) { [weak self] in
            // FSEvents 回调经 FileWatcherService 派发到主队列；用 assumeIsolated 声明主 actor 上下文。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileTreeManager.scheduleWatchedReload(rootURL: url)
                self.checkExternalModifications()
                self.scheduleWorkspaceIndexRefresh(root: url)
                let spotlight = SpotlightIndexManager.shared
                Task { await spotlight.scheduleRefresh(root: url, includeContent: AppSettings.shared.spotlightIndexContent) }
                self.gitStatusService.scheduleRefresh(rootURL: url)
            }
        }
    }

    func selectFile(_ item: FileItem) {
        if item.isDirectory { selectedFileID = item.id } else { openFile(item) }
    }

    // MARK: - File CRUD (called by FileSidebar)

    func createFileOrFolder(name: String, isFolder: Bool, parentURL: URL) {
        let target = parentURL.appendingPathComponent(name)
        do {
            if isFolder { try fileService.createDirectory(at: target) }
            else        { try fileService.createFile(at: target, content: "") }
            reloadFileTree()
        } catch { setError(error.localizedDescription) }
    }

    func renameFileItem(from oldURL: URL, newName: String) {
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try fileService.moveItem(from: oldURL, to: newURL)
            handleItemRenamed(from: oldURL, to: newURL)
            reloadFileTree()
        } catch { setError(error.localizedDescription) }
    }

    func deleteFileItem(at url: URL) {
        do {
            try fileService.removeItem(at: url)
            handleItemDeleted(at: url)
            reloadFileTree()
        } catch { setError(error.localizedDescription) }
    }

    // MARK: - Cross-domain coordination

    func syncSidebarSelectionToTab(_ tab: EditorTab) {
        // Always highlight the tab's file in the sidebar, regardless of whether
        // its parent directory has been expanded (fileItemMap may not contain it yet).
        selectedFileID = tab.url
    }

    func handleItemRenamed(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL, new = newURL.standardizedFileURL
        if let id = selectedFileID,
           let r = fileTreeManager.replacingDescendantURL(id, from: old, to: new) { selectedFileID = r }
        for tab in tabManager.openTabs {
            if let r = fileTreeManager.replacingDescendantURL(tab.url, from: old, to: new) { tab.url = r }
        }
        tabManager.recentlyClosedURLs = tabManager.recentlyClosedURLs.compactMap {
            fileTreeManager.replacingDescendantURL($0, from: old, to: new)
        }
        if let tab = selectedTab { syncPreviewContent(from: tab) }
        // Spotlight 即时路径：删旧 id；新路径 upsert（目录重命名的子项由 FSEvents diff 兜底）
        let spotlight = SpotlightIndexManager.shared
        Task { await spotlight.removeFile(at: oldURL) }
        Task { await spotlight.updateFile(at: newURL, includeContent: AppSettings.shared.spotlightIndexContent) }
    }

    func handleItemDeleted(at deletedURL: URL) {
        let deleted = deletedURL.standardizedFileURL
        tabManager.openTabs.filter   { fileTreeManager.isSameOrDescendant($0.url, of: deleted) }
                           .forEach  { endAccessing($0.url) }
        tabManager.openTabs.removeAll         { fileTreeManager.isSameOrDescendant($0.url, of: deleted) }
        tabManager.recentlyClosedURLs.removeAll { fileTreeManager.isSameOrDescendant($0, of: deleted) }

        if let id = selectedFileID,
           fileTreeManager.isSameOrDescendant(id, of: deleted) { selectedFileID = nil }

        if let id = tabManager.selectedTabID,
           !tabManager.openTabs.contains(where: { $0.id == id }) {
            tabManager.selectedTabID = tabManager.openTabs.first?.id
        }

        if let tab = selectedTab { syncSidebarSelectionToTab(tab); syncPreviewContent(from: tab) }
        else                     { tabManager.selectedTabID = nil; previewManager.clear() }

        // Spotlight 即时路径：文件删精确 id，目录删前缀下所有 id
        let spotlight = SpotlightIndexManager.shared
        Task { await spotlight.removeFile(at: deletedURL) }
    }
}
