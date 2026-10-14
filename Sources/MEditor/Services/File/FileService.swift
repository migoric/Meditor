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
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
            options: []
        ) else { return [] }

        let items = urls.compactMap { url -> FileItem? in
            let name = url.lastPathComponent
            guard !Self.hiddenNames.contains(name) else { return nil }
            // iCloud Drive 占位符（.xxx.icloud）不进文件树，下载完成后真实文件才会出现
            guard url.pathExtension.lowercased() != "icloud" else { return nil }

            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = values.isDirectory
            else { return nil }

            if !isDir && !FileTypeConfiguration.shared.supportedExtensions.contains(url.pathExtension.lowercased()) {
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

    /// 递归返回所有文件 + 目录（供 @mention 搜索用）。
    /// 目录本身包含在列表中，但不过滤扩展名。
    func loadAllItems(under directory: URL) -> [FileItem] {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: indexedResourceKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var items: [FileItem] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if Self.hiddenNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // iCloud Drive 占位符（.xxx.icloud）不进索引，见 loadImmediateChildren
            if url.pathExtension.lowercased() == "icloud" { continue }
            guard let values = try? url.resourceValues(forKeys: Set(indexedResourceKeys)) else { continue }
            if values.isDirectory == true {
                items.append(FileItem(url: url, isDirectory: true, childrenLoaded: true))
            } else if values.isRegularFile == true,
                      FileTypeConfiguration.shared.supportedExtensions.contains(url.pathExtension.lowercased()) {
                items.append(FileItem(url: url, isDirectory: false, childrenLoaded: true))
            }
        }
        return sortItems(items)
    }

    func loadAllFiles(under directory: URL) -> [FileItem] {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: indexedResourceKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [FileItem] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if Self.hiddenNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // iCloud Drive 占位符（.xxx.icloud）不进索引，见 loadImmediateChildren
            if url.pathExtension.lowercased() == "icloud" { continue }
            guard let values = try? url.resourceValues(forKeys: Set(indexedResourceKeys)) else { continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            guard FileTypeConfiguration.shared.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            files.append(FileItem(url: url, isDirectory: false, childrenLoaded: true))
        }
        return sortItems(files)
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
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
