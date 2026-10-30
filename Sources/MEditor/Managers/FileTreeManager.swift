import Foundation
import Observation
import OSLog

/// Owns file-tree state and all related async operations.
///
/// AppState holds a reference and calls `reload(rootURL:)` / `scheduleWatchedReload(rootURL:)`
/// whenever the project root or FSEvents trigger a refresh. Views that only read
/// the file tree (FileSidebar, QuickOpen) can observe this manager directly if needed,
/// but for now AppState forwards its properties to keep the View layer unchanged.
@MainActor
@Observable
final class FileTreeManager {

    // MARK: - State

    var fileTree: [FileItem] = []
    var fileItemMap: [URL: FileItem] = [:]
    var indexedFiles: [FileItem] = []
    /// 文件 + 目录全量列表，专供 @mention 搜索，与 indexedFiles 同步构建。
    var mentionItems: [FileItem] = []

    // MARK: - Private

    private let fileService: FileServiceProtocol

    @ObservationIgnored
    private var pendingReloadWork: DispatchWorkItem?

    @ObservationIgnored
    private var fileIndexGeneration = 0

    /// Set to true when index is stale; rebuilt lazily on next `ensureIndexReady()` call.
    private var indexStale = true
    private var lastIndexedRootURL: URL?

    // MARK: - Init

    init(fileService: FileServiceProtocol) {
        self.fileService = fileService
    }

    // MARK: - Public API

    /// Immediately reload the first level of the tree and rebuild the full index.
    /// 首层目录扫描在后台执行，避免阻塞主线程。
    ///
    /// 递归刷新已展开（childrenLoaded == true）的子目录：FSEvents 是对整棵目录树
    /// 递归监听的，外部在已展开的子文件夹内新建文件/文件夹时，仅刷新根目录的第一层
    /// 是不够的——UI 只在 isExpanded 从 false→true "翻转"时才会重新拉取子级
    /// (DirectoryRow.onChange(of: isExpanded))，已经展开的目录永远不会再次触发。
    /// 因此这里在后台线程按需递归重新扫描所有已加载过子级的目录。
    func reload(rootURL: URL) {
        pendingReloadWork?.cancel()
        let sid     = PerformanceTracer.begin("ReloadFileTree", log: PerformanceTracer.fileOps)
        let current = fileTree          // 主线程快照
        let svc     = fileService
        Task.detached(priority: .userInitiated) { [weak self] in
            let children = svc.loadImmediateChildren(of: rootURL)
            let merged = Self.mergeChildrenRecursively(children, into: current, fileService: svc)
            await self?.applyReload(children: merged, rootURL: rootURL, sid: sid)
        }
    }

    @MainActor
    private func applyReload(children: [FileItem], rootURL: URL, sid: OSSignpostID) {
        fileItemMap  = [:]
        fileTree     = children
        addToMap(children)
        indexStale        = true
        lastIndexedRootURL = rootURL
        PerformanceTracer.end("ReloadFileTree", log: PerformanceTracer.fileOps, id: sid)
    }

    /// Off-main-thread recursive merge: rescans any directory that was
    /// previously expanded (`childrenLoaded == true`) so newly created
    /// files/folders inside already-expanded subdirectories show up without
    /// requiring the user to manually collapse/re-expand. Directories that
    /// were never expanded keep their lazy `childrenLoaded = false` state.
    nonisolated private static func mergeChildrenRecursively(
        _ fresh: [FileItem],
        into existing: [FileItem],
        fileService: FileServiceProtocol
    ) -> [FileItem] {
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.url, $0) })
        return fresh.map { newItem in
            guard let old = existingMap[newItem.url], old.isDirectory == newItem.isDirectory else {
                return newItem
            }
            if old.isDirectory, old.childrenLoaded {
                let freshChildren = fileService.loadImmediateChildren(of: old.url)
                let mergedChildren = mergeChildrenRecursively(freshChildren, into: old.children ?? [], fileService: fileService)
                old.children = mergedChildren
                old.childrenLoaded = true
            }
            return old
        }
    }

    /// Fresh open: load and assign in one step, bypassing merge so SwiftUI
    /// sees a single [] → [items] transition with no intermediate empty render.
    /// IO 在后台执行，完成后回到主线程更新树。
    /// - Parameter defersFullIndex: true 时只刷首层目录树，全量索引等待组合根
    ///   （AppState 的工作区扫描合一）经 `applyScannedIndex` 下发——避免与
    ///   WorkspaceIndexService / SpotlightIndexManager 各自重复枚举整树。
    ///   独立使用方（测试 / QuickOpen 兜底）保持默认 false，索引行为不变。
    func reloadFresh(rootURL: URL, defersFullIndex: Bool = false) {
        pendingReloadWork?.cancel()
        fileIndexGeneration &+= 1
        let generation = fileIndexGeneration
        // 同步落地 root 标记：组合根的扫描分发（applyScannedIndex）以此判定
        // 产物是否属于当前工作区，必须在扫描任务启动前就位。
        lastIndexedRootURL = rootURL
        let svc     = fileService
        Task.detached(priority: .userInitiated) { [weak self] in
            let children = svc.loadImmediateChildren(of: rootURL)
            await self?.applyReloadFresh(children: children, rootURL: rootURL,
                                         generation: generation, defersFullIndex: defersFullIndex)
        }
    }

    @MainActor
    private func applyReloadFresh(children: [FileItem], rootURL: URL,
                                  generation: Int, defersFullIndex: Bool) {
        // Still merge to reuse existing FileItem instances when reopening the
        // same folder — avoids DisclosureGroup node destruction/recreation.
        let merged = mergeChildren(children, into: fileTree)
        fileItemMap = [:]
        fileTree = merged
        addToMap(merged)
        if defersFullIndex {
            // 组合根的扫描可能先于本回调落地（generation 已被 applyScannedIndex
            // 推进）：索引产物已就位，不得再清空。否则标记 stale，QuickOpen
            // 提前打开时仍能走 ensureIndexReady 的兜底重建。
            guard generation == fileIndexGeneration else { return }
            indexedFiles = []
            mentionItems = []
            indexStale = true
            return
        }
        // 打开项目时立即构建全量索引（含目录），不再延迟到 QuickOpen/@mention
        rebuildIndex(rootURL: rootURL)
    }

    /// 组合根（AppState）下发的工作区扫描产物：一次枚举喂给三方索引。
    /// generation 自增使在途的兜底重建结果（若竞态发生）不会覆盖这份数据；
    /// root 不匹配（快速连开两个工作区，旧扫描晚到）直接丢弃。
    func applyScannedIndex(files: [FileItem], items: [FileItem], rootURL: URL) {
        guard lastIndexedRootURL == rootURL else { return }
        fileIndexGeneration &+= 1
        indexStale = false
        indexedFiles = files
        mentionItems = items
        onMentionItemsUpdated?()
    }

    /// Ensure the full-text index is up to date. Called by QuickOpen on open.
    func ensureIndexReady(rootURL: URL) {
        guard indexStale || lastIndexedRootURL != rootURL || mentionItems.isEmpty else { return }
        rebuildIndex(rootURL: rootURL)
    }

    /// Debounced reload triggered by FSEvents (200 ms coalesce).
    func scheduleWatchedReload(rootURL: URL) {
        pendingReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload(rootURL: rootURL)
        }
        pendingReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Lazily load a directory's children on first expand.
    func loadChildrenIfNeeded(for item: FileItem) {
        guard item.isDirectory, !item.childrenLoaded, !item.isLoadingChildren else { return }
        item.isLoadingChildren = true
        let service = fileService
        let url = item.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let children = service.loadImmediateChildren(of: url)
            await self?.applyLoadedChildren(children, to: item, expectedURL: url)
        }
    }

    /// Clear all tree state (called when a new folder is opened).
    func clear() {
        pendingReloadWork?.cancel()
        fileTree = []
        fileItemMap = [:]
        indexedFiles = []
        fileIndexGeneration &+= 1
    }

    // MARK: - URL Helpers

    func isSameOrDescendant(_ url: URL, of baseURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let basePath = baseURL.standardizedFileURL.path
        return path == basePath || path.hasPrefix(basePath + "/")
    }

    func replacingDescendantURL(_ url: URL, from oldBase: URL, to newBase: URL) -> URL? {
        let oldPath = oldBase.standardizedFileURL.path
        let srcPath = url.standardizedFileURL.path
        guard srcPath == oldPath || srcPath.hasPrefix(oldPath + "/") else { return nil }
        let suffix = srcPath.dropFirst(oldPath.count)
        guard !suffix.isEmpty else { return newBase.standardizedFileURL }
        return newBase.standardizedFileURL.appendingPathComponent(
            String(suffix.drop(while: { $0 == "/" }))
        )
    }

    // MARK: - Internal

    private func rebuildIndex(rootURL: URL) {
        let sid = PerformanceTracer.begin("RebuildFileIndex", log: PerformanceTracer.fileOps)
        fileIndexGeneration &+= 1
        let generation = fileIndexGeneration
        let service = fileService
        indexedFiles = []
        mentionItems = []
        indexStale = false
        Task.detached(priority: .utility) { [weak self] in
            // 一次枚举同时拿到两份列表：分两次调用会把整棵目录树扫两遍。
            // 排序在 loadAll 内部收口为一次，files 从排好的 items 派生，见 FileService.sortItems。
            let index = service.loadAll(under: rootURL)
            await self?.applyIndexedFiles(index.files, items: index.items, generation: generation, rootURL: rootURL)
            await MainActor.run {
                PerformanceTracer.end("RebuildFileIndex", log: PerformanceTracer.fileOps, id: sid)
            }
        }
    }

    private func applyLoadedChildren(_ children: [FileItem], to item: FileItem, expectedURL: URL) {
        guard item.url == expectedURL else { return }
        item.children = children
        item.childrenLoaded = true
        item.isLoadingChildren = false
        addToMap(children)
    }

    private func applyIndexedFiles(_ files: [FileItem], items: [FileItem], generation: Int, rootURL: URL) {
        // 始终更新 mentionItems（即使 generation 过期）：显示稍旧的数据远比空列表好
        // indexedFiles 仍然用 generation 保护，避免过期搜索结果覆盖
        if generation == fileIndexGeneration {
            indexedFiles = files
        }
        mentionItems = items
        onMentionItemsUpdated?()
    }

    /// Called on MainActor after mentionItems is updated — used by AppState to bump its version counter
    var onMentionItemsUpdated: (() -> Void)?

    private func addToMap(_ items: [FileItem]) {
        for item in items {
            fileItemMap[item.id] = item
        }
    }

    /// Merge freshly-loaded children with existing items, preserving already-loaded
    /// subtrees so expanded directories don't collapse on FSEvent-triggered reloads.
    /// Returns existing FileItem instances where URLs match — same object identity
    /// means SwiftUI skips diffing that subtree entirely.
    private func mergeChildren(_ fresh: [FileItem], into existing: [FileItem]) -> [FileItem] {
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.url, $0) })
        return fresh.map { newItem in
            guard let old = existingMap[newItem.url] else { return newItem }
            // 已展开的目录：标记为 stale，让用户再次展开时通过 loadChildrenIfNeeded 异步刷新。
            // 不在 mergeChildren 里内联同步读磁盘，避免 FSEvent reload 时採集所有展开目录。
            if old.isDirectory && old.childrenLoaded {
                old.childrenLoaded = false   // 下次展开时重新加载
            }
            return old
        }
    }
}
