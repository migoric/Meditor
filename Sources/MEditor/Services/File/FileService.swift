import Foundation

enum FileServiceError: LocalizedError {
    case accessDenied
    case readFailed(Error)
    case writeFailed(Error)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return L("error.file.accessDenied")
        case .readFailed(let e): return L("error.file.readFailed", e.localizedDescription)
        case .writeFailed(let e): return L("error.file.writeFailed", e.localizedDescription)
        case .alreadyExists(let url): return L("error.file.alreadyExists", url.lastPathComponent)
        }
    }
}

/// 单次工作区枚举的分发产物（`FileService.scanWorkspace`），四份列表共享同一次
/// 目录遍历，各自保持消费方的原始谓词语义（详见 scanWorkspace 注释）。
struct WorkspaceScanResult: Sendable {
    /// 可搜索文件（QuickOpen 索引）：扩展名白名单过滤后的文件，已排序。
    var treeFiles: [FileItem] = []
    /// @mention 全量项（含目录）：与 treeFiles 同一次枚举、同一次排序派生。
    var treeItems: [FileItem] = []
    /// 内容索引全集（WorkspaceIndexService）：非隐藏、非噪音目录、不限扩展名。
    var contentFileURLs: [URL] = []
    /// Spotlight 子集：contentFileURLs 中的 md/markdown。
    var markdownFileURLs: [URL] = []
}

/// 无状态文件服务：只持有 FileManager.default（线程安全）与常量键。
final class FileService: FileServiceProtocol, @unchecked Sendable {
    private let fm = FileManager.default
    private let indexedResourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

    // MARK: - Directory scanning

    /// Dot-prefixed names that should never appear in the file tree.
    private static let hiddenNames: Set<String> = [
        ".git", ".svn", ".hg", ".DS_Store", ".Trash",
        ".build", ".swp", ".lock", "node_modules"
    ]

    /// 文档扩展名白名单：左侧文档列表（FileSidebar）筛选用的最小集。
    static let documentExtensions: Set<String> = ["md", "html"]

    /// 枚举目录下的文档文件（.md / .html），按文件名升序。
    ///
    /// 收口点：早先 FileSidebar 自己 `FileManager.contentsOfDirectory` 直接列目录
    /// （View 层越层触碰文件系统，且与 FileService 的枚举规则各写一份）。现由
    /// Service 层提供原语，View 只做渲染。
    /// nonisolated 语义（static 本身即 nonisolated）：纯 FileManager 操作、不触
    /// 视图状态，允许在后台队列调用（refreshDocFiles 的运行环境）。
    /// 取不到目录内容时返回空数组（调用方按空列表渲染，不区分错误）。
    static func listDocumentFiles(at url: URL?) -> [URL] {
        guard let url else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { candidate in
                guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
                return values.isDirectory == false
                    && documentExtensions.contains(candidate.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Load immediate children of a directory (one level only).
    func loadImmediateChildren(of directory: URL) -> [FileItem] {
        // 不预取 localizedNameKey：全仓没有消费方（FileItem.name 用 lastPathComponent），
        // 每个 URL 白付一次资源 key 填充。
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        // supportedExtensions 每次访问都重建 Set，必须提出循环（同 loadAll 的取舍）。
        let supported = FileTypeConfiguration.shared.supportedExtensions
        let items = urls.compactMap { url -> FileItem? in
            let name = url.lastPathComponent
            guard !Self.hiddenNames.contains(name) else { return nil }
            // iCloud Drive 占位符（.xxx.icloud）不进文件树，下载完成后真实文件才会出现
            let ext = url.pathExtension.lowercased()
            guard ext != "icloud" else { return nil }

            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = values.isDirectory
            else { return nil }

            if !isDir && !supported.contains(ext) {
                return nil
            }

            return FileItem(url: url, isDirectory: isDir)
        }

        return sortItems(items)
    }

    func loadChildren(for item: FileItem) -> [FileItem] {
        item.children = loadImmediateChildren(of: item.url)
        item.childrenLoaded = true
        return item.children ?? []
    }

    /// 一次枚举同时产出「可搜索文件」与「@mention 全量项（含目录）」。
    ///
    /// 实现已收敛到 `scanWorkspace`（枚举谓词的超集 + 逐消费方过滤），此处只取
    /// 树侧两份产物，保证与 scanWorkspace 的树产物逐位一致、谓词不再双写漂移。
    /// 排序只排一次：`files` 从排好的 `items` 派生（目录恒排前、同类按 name，
    /// 过滤保持相对顺序，与单独排序逐位一致），并重新 new 实例隔离可变字段。
    ///
    /// 调用方在 `FileTreeManager.rebuildIndex` 的 `Task.detached(priority: .utility)` 里，
    /// **不在主线程**，不会直接压住用户等待。
    func loadAll(under directory: URL) -> (files: [FileItem], items: [FileItem]) {
        let scan = scanWorkspace(under: directory)
        return (scan.treeFiles, scan.treeItems)
    }

    /// 递归返回所有文件 + 目录（供 @mention 搜索用）。
    /// 目录本身包含在列表中，但不过滤扩展名——由 `loadAll` 保证，见其注释。
    func loadAllItems(under directory: URL) -> [FileItem] {
        loadAll(under: directory).items
    }

    func loadAllFiles(under directory: URL) -> [FileItem] {
        loadAll(under: directory).files
    }

    /// 一次目录枚举同时产出三个消费方所需的产物（性能方案批 4：打开工作区时
    /// FileTreeManager / WorkspaceIndexService / SpotlightIndexManager 曾各自
    /// 枚举一遍整树）。
    ///
    /// 枚举谓词取三方的**并集**（最宽口径），再按消费方各自的原谓词过滤，
    /// 三方可见集合与合并前逐位一致：
    ///   - 目录剪枝只用 FileService.hiddenNames（文件树的原口径）。刻意**不**把
    ///     Agent 噪音目录（dist/vendor/Pods/.cache…）并入剪枝——文件树现状是
    ///     展示这些目录的，剪掉等于悄悄改 UI 语义；枚举成本不增（树本来就在走它们），
    ///     索引消费方在过滤阶段剔除。
    ///   - treeItems / treeFiles：与 loadAll 同一套筛选（隐藏名 / .icloud /
    ///     扩展名白名单），同一次排序派生。
    ///   - contentFileURLs：对应 DefaultAgentFileRepository.enumerate 的
    ///     .skipsHiddenFiles 语义 = 任一路径分量为 dot 名（.github 内文件也排除，
    ///     与旧实现一致）或条目带隐藏标记；再叠加噪音目录过滤（沿用旧实现
    ///     检查**完整** pathComponents 的怪癖，root 路径含噪音名时行为不变）。
    ///   - markdownFileURLs：contentFileURLs 的 md/markdown 子集（Spotlight 口径）。
    func scanWorkspace(under directory: URL) -> WorkspaceScanResult {
        let scanKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: scanKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return WorkspaceScanResult()
        }

        let keys = Set(scanKeys)
        let supported = FileTypeConfiguration.shared.supportedExtensions
        let noise = DefaultAgentFileRepository.noiseDirectories
        let rootComponents = directory.standardizedFileURL.pathComponents
        var result = WorkspaceScanResult()
        var items: [FileItem] = []

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if Self.hiddenNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // iCloud Drive 占位符（.xxx.icloud）不进索引，见 loadImmediateChildren
            let ext = url.pathExtension.lowercased()
            if ext == "icloud" { continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }

            if values.isDirectory == true {
                items.append(FileItem(url: url, isDirectory: true, childrenLoaded: true))
                continue
            }
            guard values.isRegularFile == true else { continue }

            // 文件树产物：扩展名白名单
            if supported.contains(ext) {
                items.append(FileItem(url: url, isDirectory: false, childrenLoaded: true))
            }
            // 内容索引产物：.skipsHiddenFiles 语义 + 噪音目录，不限扩展名
            let relativeComponents = url.pathComponents.dropFirst(rootComponents.count)
            let isHidden = values.isHidden == true
                || relativeComponents.contains(where: { $0.hasPrefix(".") })
            if !isHidden, !url.pathComponents.contains(where: { noise.contains($0) }) {
                result.contentFileURLs.append(url)
                if ext == "md" || ext == "markdown" {
                    result.markdownFileURLs.append(url)
                }
            }
        }

        // 只排一次序：比较器目录恒在文件前、同类按 name，过滤保持相对顺序 ⇒
        // files 直接从排好的 items 派生（顺序与单独 sortItems 逐位一致）。
        // files 侧重新 new 实例：与 items 隔离可变字段。
        let sortedItems = sortItems(items)
        result.treeItems = sortedItems
        result.treeFiles = sortedItems.compactMap { item in
            item.isDirectory ? nil : FileItem(url: item.url, isDirectory: false, childrenLoaded: item.childrenLoaded)
        }
        return result
    }

    // MARK: - File I/O

    func readFile(at url: URL) throws -> String {
        try TextFileDecoder.decode(contentsOf: url)
    }

    func writeFile(at url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func createFile(at url: URL, content: String) throws {
        // 拒绝覆盖已存在文件：用户输入的是确切文件名，静默覆盖会丢失数据。
        // 与 writeFile（语义就是覆盖保存）不同，create 必须先挡一道，
        // 不依赖调用方自查（参考 TemplateManager 的去重循环是另一条路径）。
        guard !fm.fileExists(atPath: url.path) else {
            throw FileServiceError.alreadyExists(url)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func createDirectory(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func moveItem(from source: URL, to destination: URL) throws {
        try fm.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    func fileExists(at url: URL, isDirectory: inout Bool) -> Bool {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        isDirectory = isDir.boolValue
        return exists
    }

    func attributes(at url: URL) -> [FileAttributeKey: Any]? {
        try? fm.attributesOfItem(atPath: url.path)
    }

    // MARK: - Private

    private func sortItems(_ items: [FileItem]) -> [FileItem] {
        // 预取 name：`FileItem.name` 是 `url.lastPathComponent` 计算属性，比较器里直接
        // 取会每次比较现算两次（4,500 项 ≈ 10.8 万次比较 × 2 次 String 构造），
        // 实测 91.7ms → 13.4ms。ICU 的 localizedStandardCompare 本身只占 13ms。
        let keyed = items.map { (item: $0, name: $0.name) }
        return keyed.sorted { a, b in
            if a.item.isDirectory != b.item.isDirectory { return a.item.isDirectory && !b.item.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.map(\.item)
    }
}
