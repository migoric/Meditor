import CoreSpotlight
import Foundation
import OSLog

/// 工作区 Markdown 文档的系统 Spotlight 索引（CoreSpotlight）。
///
/// 生命周期与 WorkspaceIndexService 对齐：
///   打开工作区 `reindex` 全量建立 → FSEvents 走 `scheduleRefresh`（防抖 + 枚举 diff）
///   → 保存/删除/重命名走 `updateFile` / `removeFile` 即时路径
///   → 关闭/切换工作区 `clearWorkspace` 按 domainIdentifier 清理。
///
/// 线程模型：actor。所有 CSSearchableIndex 调用与磁盘 IO 均离开主线程；
/// 调用方（AppState @MainActor）以 `Task { await ... }` 触发。
actor SpotlightIndexManager {

    static let shared = SpotlightIndexManager()

    /// 单文件索引上限：与 WorkspaceIndexService 对齐（超大文件多为导出产物，搜索价值低）。
    static let maxIndexedFileBytes = WorkspaceIndexService.maxIndexedFileBytes
    /// 全量重建时的批量写入大小：每批之间小睡让出，避免大工作区索引期间挤占 Spotlight 服务。
    static let batchSize = 100

    private let index: CSSearchableIndex
    private var domainIdentifier: String?
    private var root: URL?
    /// identifier（文件绝对路径）→ 已索引时的 modDate，供 FSEvents diff 增量判定。
    private var indexedModDates: [String: Date?] = [:]
    /// 防抖/代际标记：scheduleRefresh 连发时只保留最后一次；reindex/clear 取消未执行的 refresh。
    private var refreshGeneration = 0

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    // MARK: - 全量重建

    /// 打开/切换工作区时的全量重建。批量写入，批间让出；可随时被 Task 取消打断。
    /// - Parameter includeContent: 是否索引正文（默认 false：只索引文件名/标题与修改时间）。
    func reindex(root: URL, includeContent: Bool = false) async {
        await reindex(root: root, enumeratedFiles: Self.enumerateMarkdownFiles(root: root),
                      includeContent: includeContent)
    }

    /// 枚举结果已由组合根（AppState 的工作区扫描合一）提供时的重建入口：
    /// 消费方不再自行枚举整树。`enumeratedFiles` 必须满足与本服务
    /// `enumerateMarkdownFiles` 相同的谓词（由 FileService.scanWorkspace 保证）。
    func reindex(root: URL, enumeratedFiles: [URL], includeContent: Bool = false) async {
        refreshGeneration &+= 1   // 取消未执行的增量刷新
        let domain = SpotlightMetadata.domainIdentifier(forRoot: root)
        // 切换到新工作区时先清理旧 domain，避免 Spotlight 里残留旧工作区条目
        if let old = domainIdentifier, old != domain {
            try? await deleteDomain(old)
        }
        self.root = root.standardizedFileURL
        self.domainIdentifier = domain
        indexedModDates = [:]

        let files = enumeratedFiles
        var batch: [CSSearchableItem] = []
        var applied: [String: Date?] = [:]
        for url in files {
            if Task.isCancelled { return }
            guard let (item, modDate) = Self.loadItem(url: url, domain: domain, includeContent: includeContent) else { continue }
            batch.append(item)
            applied[item.uniqueIdentifier] = modDate
            if batch.count >= Self.batchSize {
                try? await indexItems(batch)
                batch.removeAll()
                // 批间让出：大工作区全量索引是后台活，不抢 Spotlight 服务与其他索引方
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        if !batch.isEmpty { try? await indexItems(batch) }
        indexedModDates = applied
        AppLog.app.log("Spotlight: indexed \(applied.count) files for \(root.path, privacy: .public)")
    }

    /// 关闭工作区：按 domain 清理索引并释放内存状态。
    func clearWorkspace() async {
        refreshGeneration &+= 1
        if let domain = domainIdentifier {
            try? await deleteDomain(domain)
        }
        domainIdentifier = nil
        root = nil
        indexedModDates = [:]
    }

    // MARK: - FSEvents 增量刷新

    /// FSEvents 变化入口（内部 300ms 防抖合并连续事件）。
    /// 采用「枚举 diff」而非逐事件路径：FileWatcherService 回调不带路径信息，
    /// 枚举 + modDate 比较对千级文件是毫秒级，移动/重命名天然覆盖。
    func scheduleRefresh(root: URL, includeContent: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        await refresh(root: root, includeContent: includeContent)
    }

    private func refresh(root: URL, includeContent: Bool) async {
        guard self.root == root.standardizedFileURL, let domain = domainIdentifier else { return }
        let files = Self.enumerateMarkdownFiles(root: root)
        var disk: [String: Date?] = [:]
        for url in files {
            disk[SpotlightMetadata.identifier(for: url)] = Self.modificationDate(of: url)
        }
        let changes = SpotlightIndexDiffer.diff(disk: disk, indexed: indexedModDates)
        if !changes.delete.isEmpty { try? await deleteItems(changes.delete) }

        var items: [CSSearchableItem] = []
        var applied: [String: Date?] = [:]
        for identifier in changes.upsert {
            if Task.isCancelled { return }
            let url = URL(fileURLWithPath: identifier)
            if let (item, modDate) = Self.loadItem(url: url, domain: domain, includeContent: includeContent) {
                items.append(item)
                applied[identifier] = modDate
            }
        }
        if !items.isEmpty { try? await indexItems(items) }

        for identifier in changes.delete { indexedModDates.removeValue(forKey: identifier) }
        for (identifier, modDate) in applied { indexedModDates[identifier] = modDate }
    }

    // MARK: - 单文件即时路径

    /// 单文件 upsert（Tab 保存回调 / 应用内重命名的新路径）。
    /// 非 Markdown、不在当前工作区内、读盘失败的文件按删除处理（与磁盘状态对齐）。
    func updateFile(at url: URL, includeContent: Bool = false) async {
        guard let domain = domainIdentifier,
              Self.isMarkdownFile(url), isUnderRoot(url) else { return }
        let identifier = SpotlightMetadata.identifier(for: url)
        if let (item, modDate) = Self.loadItem(url: url, domain: domain, includeContent: includeContent) {
            try? await indexItems([item])
            indexedModDates[identifier] = modDate
        } else {
            try? await deleteItems([identifier])
            indexedModDates.removeValue(forKey: identifier)
        }
    }

    /// 删除（应用内删除/重命名的旧路径）。文件删精确 id；目录删前缀下的所有 id，
    /// 内存状态未覆盖时兜底删一次精确 id（FSEvents diff 也会兜住，此为即时路径）。
    func removeFile(at url: URL) async {
        guard isUnderRoot(url) else { return }
        let identifier = SpotlightMetadata.identifier(for: url)
        let descendants = indexedModDates.keys.filter { $0.hasPrefix(identifier + "/") }
        let ids = [identifier] + descendants
        try? await deleteItems(ids)
        for id in ids { indexedModDates.removeValue(forKey: id) }
    }

    // MARK: - 内部：CSSearchableIndex 封装

    private func indexItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func deleteItems(_ identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func deleteDomain(_ domain: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    // MARK: - 内部：枚举与加载

    private func isUnderRoot(_ url: URL) -> Bool {
        guard let root else { return false }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/")
    }

    private static func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// 与 WorkspaceIndexService / AgentFileRepository 同一套枚举规则，只取 Markdown。
    private static func enumerateMarkdownFiles(root: URL) -> [URL] {
        DefaultAgentFileRepository.enumerate(
            root: root,
            extensions: ["md", "markdown"],
            noiseDirectories: DefaultAgentFileRepository.noiseDirectories
        )
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 读盘 + 解码 + 构造索引项。返回 nil 的情形：超大小上限、iCloud 占位符
    /// （触发后台下载）、读盘失败、无法按文本解码——与 WorkspaceIndexService 同一套判定。
    /// - Parameter includeContent: false 时不读正文，只索引文件名/标题与修改时间（隐私默认）。
    private static func loadItem(url: URL, domain: String, includeContent: Bool) -> (CSSearchableItem, Date?)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        if !includeContent {
            // 不读盘内容：标题回退文件名，不带 description/textContent。
            let metadata = SpotlightDocumentMetadata(
                title: SpotlightMetadata.fallbackTitle(from: url.lastPathComponent),
                contentDescription: "",
                textContent: ""
            )
            let item = SpotlightItemBuilder.makeItem(
                url: url,
                domainIdentifier: domain,
                metadata: metadata,
                contentModificationDate: values.contentModificationDate,
                includeContent: false
            )
            return (item, values.contentModificationDate)
        }
        guard let size = values.fileSize, size <= maxIndexedFileBytes else { return nil }
        if UbiquitousFileHelper.isUbiquitousItemNotDownloaded(url) {
            UbiquitousFileHelper.startDownloadingIfNeeded(url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 二进制判定与 WorkspaceIndexService 一致：头部 8KB 内含 NUL 且无 BOM 即跳过
        let head = data.prefix(8192)
        let hasBOM = head.starts(with: [0xEF, 0xBB, 0xBF])
            || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        if !hasBOM, head.contains(0x00) { return nil }
        guard let text = TextFileDecoder.decode(data) else { return nil }

        let metadata = SpotlightMetadata.extract(from: text, fileName: url.lastPathComponent)
        let item = SpotlightItemBuilder.makeItem(
            url: url,
            domainIdentifier: domain,
            metadata: metadata,
            contentModificationDate: values.contentModificationDate
        )
        return (item, values.contentModificationDate)
    }
}
