import Foundation

/// 文件 IO 服务。实现为无状态磁盘操作，允许跨线程调用，故要求 Sendable
/// （Swift 6 下 Task.detached 捕获服务实例需要它 Sendable）。
protocol FileServiceProtocol: AnyObject, Sendable {
    // Directory scanning
    func loadImmediateChildren(of directory: URL) -> [FileItem]
    func loadChildren(for item: FileItem) -> [FileItem]
    func loadAllFiles(under directory: URL) -> [FileItem]
    func loadAllItems(under directory: URL) -> [FileItem]
    /// 一次枚举同时产出上面两个列表。建索引时只要这两份数据，
    /// 分两次调用等于把整棵目录树枚举两遍。
    func loadAll(under directory: URL) -> (files: [FileItem], items: [FileItem])
    /// 一次枚举产出全部消费方的产物（树索引 + 内容索引 + Spotlight 子集）。
    /// 打开工作区时由组合根调用一次并分发，替代三方各自枚举整树。
    func scanWorkspace(under directory: URL) -> WorkspaceScanResult

    // File I/O
    func readFile(at url: URL) throws -> String
    func writeFile(at url: URL, content: String) throws

    // Filesystem operations
    func createFile(at url: URL, content: String) throws
    func createDirectory(at url: URL) throws
    func moveItem(from source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func fileExists(at url: URL, isDirectory: inout Bool) -> Bool
    func attributes(at url: URL) -> [FileAttributeKey: Any]?
}
