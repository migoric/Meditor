import Foundation
@testable import MEditor

/// @unchecked Sendable：测试替身，可跨线程被 AppState 的后台保存路径访问；
/// 内部通过锁保护写盘计数（见下方 _writeCount）。
class MockFileService: FileServiceProtocol, @unchecked Sendable {
    var fileExistsResult = true
    var readResult: String = "# Test"
    var readError: Error? = nil
    var writtenContent: String? = nil
    /// 测试用：写盘前人为延迟，模拟慢速写盘造成的乱序窗口。
    var writeDelay: TimeInterval = 0
    private var _writeCount = 0
    /// 已完成的写盘次数（线程安全）。
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }
    var createdFiles: [URL] = []
    var createdDirectories: [URL] = []
    var mockAttributes: [URL: [FileAttributeKey: Any]] = [:]
    private var files: [URL: String] = [:]
    private var children: [URL: [FileItem]] = [:]
    private let lock = NSLock()

    func setFile(_ url: URL, content: String) {
        lock.lock()
        files[url] = content
        lock.unlock()
    }

    func fileContent(at url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return files[url]
    }

    func setChildren(_ items: [FileItem], for directory: URL) {
        lock.lock()
        children[directory] = items
        lock.unlock()
    }

    func loadImmediateChildren(of directory: URL) -> [FileItem] {
        lock.lock()
        defer { lock.unlock() }
        return children[directory] ?? []
    }

    func loadChildren(for item: FileItem) -> [FileItem] {
        lock.lock()
        let childs = children[item.url] ?? []
        lock.unlock()
        item.children = childs
        return childs
    }

    func loadAllFiles(under directory: URL) -> [FileItem] {
        lock.lock()
        defer { lock.unlock() }
        _separateScanCalls += 1
        return children[directory] ?? []
    }

    func loadAllItems(under directory: URL) -> [FileItem] {
        lock.lock()
        defer { lock.unlock() }
        _separateScanCalls += 1
        return children[directory] ?? []
    }

    func loadAll(under directory: URL) -> (files: [FileItem], items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        _combinedScanCalls += 1
        let items = children[directory] ?? []
        // 与生产实现同口径：files/items 都过扩展名白名单（FileService.loadAll
        // 另过滤隐藏名与 .icloud 占位符——mock 的 children 由测试手工构造，
        // 不存在这两类）。
        let supported = FileTypeConfiguration.shared.supportedExtensions
        let visible = items.filter { $0.isDirectory || supported.contains($0.fileExtension) }
        return (visible.filter { !$0.isDirectory }, visible)
    }

    // MARK: - 枚举次数观测（守卫「建索引只扫一遍目录树」）

    private var _separateScanCalls = 0
    private var _combinedScanCalls = 0

    /// 两个单列表方法被调用的次数。建索引只该走 `loadAll`，这里是 0。
    var separateScanCallCount: Int { lock.lock(); defer { lock.unlock() }; return _separateScanCalls }
    /// `loadAll` 被调用的次数。
    var combinedScanCallCount: Int { lock.lock(); defer { lock.unlock() }; return _combinedScanCalls }

    func readFile(at url: URL) throws -> String {
        if let error = readError { throw error }
        if let content = fileContent(at: url) { return content }
        return readResult
    }

    func writeFile(at url: URL, content: String) throws {
        if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }
        writtenContent = content
        setFile(url, content: content)
        lock.lock()
        _writeCount += 1
        lock.unlock()
    }

    func createFile(at url: URL, content: String) throws {
        createdFiles.append(url)
        setFile(url, content: content)
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url)
    }

    func moveItem(from source: URL, to destination: URL) throws {
        lock.lock()
        if let content = files[source] {
            files[destination] = content
            files.removeValue(forKey: source)
        }
        lock.unlock()
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        files.removeValue(forKey: url)
        lock.unlock()
    }

    func fileExists(at url: URL) -> Bool {
        if fileContent(at: url) != nil { return true }
        if mockAttributes[url] != nil || children[url] != nil { return true }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return fileExistsResult
    }

    func fileExists(at url: URL, isDirectory: inout Bool) -> Bool {
        if fileContent(at: url) != nil || mockAttributes[url] != nil {
            isDirectory = false
            return true
        }
        if children[url] != nil {
            isDirectory = true
            return true
        }
        var realIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &realIsDir) {
            isDirectory = realIsDir.boolValue
            return true
        }
        isDirectory = false
        return fileExistsResult
    }

    func attributes(at url: URL) -> [FileAttributeKey: Any]? {
        if let attrs = mockAttributes[url] { return attrs }
        if let content = fileContent(at: url) { return [.size: Int64(content.utf8.count)] }
        return try? FileManager.default.attributesOfItem(atPath: url.path)
    }
}
