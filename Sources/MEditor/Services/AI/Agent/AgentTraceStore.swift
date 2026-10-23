import Foundation

// MARK: - AgentTraceStore

/// 运行轨迹的落盘与读取。
///
/// 布局：`<base>/traces/<yyyyMMdd-HHmmss>-<runID>.json`，一次 run 一个文件。
/// 为什么不用单个大文件：轨迹是追加型日志，单文件需要读改写全文，一次崩溃就可能
/// 截断历史；独立小文件还能直接丢给外部工具比对。
///
/// 容量：只保留最近 `maxFiles` 个（默认 50）。轨迹是排障材料，不该无限增长占用户磁盘。
///
/// 可测性：`baseDir` 可注入（与 `LocalHistoryStore` / `TemplateStore` 同一约定），
/// 否则单测只能写真实 Application Support 目录。
final class AgentTraceStore: @unchecked Sendable {

    static let shared = AgentTraceStore()

    private let baseDir: URL?
    private let maxFiles: Int
    private let lock = NSLock()

    init(baseDir: URL? = nil, maxFiles: Int = 50) {
        self.baseDir = baseDir
        self.maxFiles = maxFiles
    }

    /// `.../MEditor/traces`。`firstURL` 自带 App Support → 临时目录的兜底，
    /// 所以这里恒有值（不需要 optional，省掉调用方一层解包）。
    var directory: URL {
        let base = baseDir ?? FileManager.default.firstURL(for: .applicationSupportDirectory)
        return base.appendingPathComponent("traces", isDirectory: true)
    }

    // MARK: - Write

    /// 写入一条轨迹。失败返回 false（调用方只记日志，绝不让排障设施影响 run 收尾）。
    @discardableResult
    func save(_ trace: AgentRunTrace) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(trace)
            try data.write(to: dir.appendingPathComponent(Self.fileName(for: trace)), options: .atomic)
            pruneLocked(in: dir)
            return true
        } catch {
            MCPLog.info("trace write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Read

    func loadAll() -> [AgentRunTrace] {
        lock.lock()
        defer { lock.unlock() }
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                // 结构版本不认识就跳过：宁可少一条，不要按错的语义解读
                guard let trace = try? decoder.decode(AgentRunTrace.self, from: data),
                      trace.schemaVersion <= AgentRunTrace.currentSchemaVersion else { return nil }
                return trace
            }
    }

    // MARK: - Prune

    nonisolated static func fileName(for trace: AgentRunTrace) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: trace.createdAt))-\(trace.runID.uuidString.prefix(8)).json"
    }

    /// 文件名以时间开头 ⇒ 字典序即时间序，删最老的一批。
    private func pruneLocked(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let files = names.filter { $0.hasSuffix(".json") }.sorted()
        guard files.count > maxFiles else { return }
        for name in files.prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
