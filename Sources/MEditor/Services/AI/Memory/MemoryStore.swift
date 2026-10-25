import Foundation

/// 一层记忆的落盘存储（工作区级或全局级各一个实例）。
///
/// 两份文件：`MEDITOR.md`（人可读的正文，真相源）+ `memory-state.json`（机器计数）。
/// 拆成两份的理由见 `MemoryCounter` 的注释。
///
/// 并发模型照 `AgentSkillStore` 的成例：`@unchecked Sendable` + `NSLock` 护住状态。
/// 记忆的读写量级是「一次对话几次」，不是热路径，锁足够；换成 actor 会让 UI 侧
/// 全部变 async，收益不抵成本。
final class MemoryStore: @unchecked Sendable {

    /// 捕获结果。三种结局都要能说清，模型才知道下一步该干什么。
    enum RecordOutcome: Equatable {
        case added(MemoryEntry)
        /// 已经有高度相似的一条 ⇒ 不重复添加，只把它的使用次数 +1。
        case duplicate(id: String, text: String)
        /// 被规则拒绝（超长 / 本 run 条数超限 / 不可写）。
        case rejected(reason: String)
    }

    let fileURL: URL
    let stateURL: URL

    private let lock = NSLock()
    private var document: MemoryDocument
    private var counters: [String: MemoryCounter]
    /// 上次读到/写出这份 `MEDITOR.md` 时它的修改时间。
    ///
    /// 用来判「文件被外部改过」：用户在编辑器里改约定、`git pull` 拿到团队约定，
    /// 都是在 App 之外改的文件。没有这个哨兵，内存里的副本会一直压着磁盘上的新内容，
    /// 直到重启 —— 注入的约定和你眼前看到的文件不一致，而且没有任何报错。
    private var loadedMTime: Date?
    /// 载入时遇到的问题（文件不可读 / 状态文件损坏）。面板用它提示，不静默吞。
    private(set) var loadWarning: String?
    /// 本进程内这条记忆被新增几条 —— 用于 `newEntriesPerRunLimit` 的 run 级限额。
    private var sessionAddCount = 0

    // MARK: - 初始化

    /// - Parameters:
    ///   - fileURL: `MEDITOR.md` 的位置。
    ///   - stateURL: 旁挂 JSON 的位置。
    ///   - fallbackDate: 条目没有时间信息时用的兜底（一般传文件修改时间）。
    init(fileURL: URL, stateURL: URL, fallbackDate: Date = Date()) {
        self.fileURL = fileURL
        self.stateURL = stateURL

        let loaded = Self.load(fileURL: fileURL, stateURL: stateURL, fallbackDate: fallbackDate)
        self.document = loaded.document
        self.counters = loaded.counters
        self.loadWarning = loaded.warning
        self.loadedMTime = Self.modificationDate(of: fileURL)
    }

    /// 文件修改时间。文件不存在返回 nil —— 把「取不到」和「某个具体时间」分开，
    /// 否则一条 stat 失败会被当成「文件刚被改过」而无限重读。
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// 磁盘上的 `MEDITOR.md` 是否已经和内存里的副本不一致。
    func isStaleOnDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.modificationDate(of: fileURL) != loadedMTime
    }

    // MARK: - 载入

    private struct Loaded {
        var document: MemoryDocument
        var counters: [String: MemoryCounter]
        var warning: String?
    }

    private static func load(fileURL: URL, stateURL: URL, fallbackDate: Date) -> Loaded {
        var warning: String?

        var document = MemoryDocument.empty
        if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
            document = MemoryDocument.parse(text)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            warning = "记忆文件读不出来（编码异常或无权限），当前以空记忆启动。原文件未被修改。"
        }

        var counters: [String: MemoryCounter] = [:]
        if let data = try? Data(contentsOf: stateURL) {
            if let decoded = try? JSONDecoder.memory.decode([String: MemoryCounter].self, from: data) {
                counters = decoded
            } else {
                // 坏文件不能让记忆本身失效：改名留档，计数归零重来。
                let backup = stateURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: stateURL, to: backup)
                warning = (warning.map { $0 + " " } ?? "") + "记忆计数文件损坏，已备份为 \(backup.lastPathComponent)，计数已重置（正文未丢）。"
            }
        }

        // 文件里有、JSON 里没有的条目：补一条计数器。
        // 时间用兜底（文件修改时间）而不是 now —— 否则每次冷启动都会把「新鲜度」刷满。
        for entry in document.entries + document.archived where counters[entry.id] == nil {
            counters[entry.id] = MemoryCounter(createdAt: fallbackDate, updatedAt: fallbackDate)
        }

        return Loaded(document: document, counters: counters, warning: warning)
    }

    // MARK: - 读

    /// 当前全部活跃条目（含计数），按文件顺序。
    func records(scope: MemoryScope) -> [MemoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return document.entries.map {
            MemoryRecord(entry: $0, counter: counters[$0.id] ?? MemoryCounter(), scope: scope)
        }
    }

    func archivedRecords(scope: MemoryScope) -> [MemoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return document.archived.map {
            MemoryRecord(entry: $0, counter: counters[$0.id] ?? MemoryCounter(), scope: scope)
        }
    }

    var conventionText: String {
        lock.lock()
        defer { lock.unlock() }
        return document.conventionText
    }

    var isWritable: Bool {
        // 文件不存在看父目录，存在看文件本身。
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return fm.isWritableFile(atPath: fileURL.path) }
        return fm.isWritableFile(atPath: fileURL.deletingLastPathComponent().path)
    }

    // MARK: - 写

    /// 捕获一条记忆。
    ///
    /// 幂等性靠两层：归一化文本完全相同 ⇒ 直接判重；高度相似（Jaccard ≥ 0.8）⇒ 也判重。
    /// 判重时不新增条目、只把既有条目的 `useCount` +1 —— 「模型反复想记同一件事」
    /// 本身就是这条记忆重要的信号。
    @discardableResult
    func record(
        kind: MemoryKind,
        text rawText: String,
        source: String? = nil,
        now: Date = Date()
    ) -> RecordOutcome {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MemoryEntry.maxTextLength))
        guard !text.isEmpty else { return .rejected(reason: "正文为空") }

        lock.lock()
        defer { lock.unlock() }

        guard sessionAddCount < MemorySelector.newEntriesPerRunLimit else {
            return .rejected(reason: "本次运行已记录 \(MemorySelector.newEntriesPerRunLimit) 条，请先合并再记")
        }
        guard isWritableLocked() else {
            return .rejected(reason: "记忆文件不可写（工作区只读？）")
        }

        let existing = document.entries.map {
            MemoryRecord(entry: $0, counter: counters[$0.id] ?? MemoryCounter(), scope: .workspace)
        }
        if let duplicate = MemorySelector.duplicate(of: text, in: existing) {
            counters[duplicate.id, default: MemoryCounter()].useCount += 1
            counters[duplicate.id]?.lastUsedAt = now
            return .duplicate(id: duplicate.id, text: duplicate.entry.text)
        }

        let entry = MemoryEntry(id: MemoryEntry.makeID(text: text), kind: kind, text: text)
        document.upsert(entry)
        counters[entry.id] = MemoryCounter(source: source, createdAt: now, updatedAt: now)
        sessionAddCount += 1
        saveLocked()
        return .added(entry)
    }

    /// 检索命中后回写计数。只更新内存 + 落盘一次，不逐条写。
    func touch(ids: [String], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            counters[id, default: MemoryCounter()].useCount += 1
            counters[id]?.lastUsedAt = now
        }
        saveStateLocked()
    }

    func setPinned(_ pinned: Bool, id: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard counters[id] != nil else { return }
        counters[id]?.pinned = pinned
        counters[id]?.updatedAt = now
        saveLocked()
    }

    func update(id: String, text: String? = nil, kind: MemoryKind? = nil, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return }
        if let text {
            let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MemoryEntry.maxTextLength))
            guard !trimmed.isEmpty else { return }
            document.entries[index].text = trimmed
        }
        if let kind { document.entries[index].kind = kind }
        counters[id]?.updatedAt = now
        saveLocked()
    }

    /// 真删除（用户在面板里点删除 = 显式意图）。老化走的是 `archiveStale`，那条不删。
    func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        document.remove(id: id)
        counters[id] = nil
        saveLocked()
    }

    /// 归档过老且从未被用过的条目。返回归档条数。
    @discardableResult
    func archiveStale(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let records = document.entries.map {
            MemoryRecord(entry: $0, counter: counters[$0.id] ?? MemoryCounter(), scope: .workspace)
        }
        let stale = MemorySelector.archivable(records, now: now)
        guard !stale.isEmpty else { return 0 }
        for record in stale {
            document.archive(id: record.id)
            counters[record.id]?.updatedAt = now
        }
        saveLocked()
        return stale.count
    }

    @discardableResult
    func restore(id: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard document.restore(id: id) else { return false }
        counters[id]?.updatedAt = now
        saveLocked()
        return true
    }

    /// 巩固：合并同 kind 下高度相似的条目。
    @discardableResult
    func consolidate(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let records = document.entries.map {
            MemoryRecord(entry: $0, counter: counters[$0.id] ?? MemoryCounter(), scope: .workspace)
        }
        let merged = MemorySelector.consolidate(records)
        guard merged.count < records.count else { return 0 }
        let removed = records.count - merged.count
        document.entries = merged.map(\.entry)
        for record in merged { counters[record.id] = record.counter }
        saveLocked()
        return removed
    }

    /// 供「本 run 已记几条」在 run 开始时重置。
    func resetSessionAddCount() {
        lock.lock()
        defer { lock.unlock() }
        sessionAddCount = 0
    }

    // MARK: - 落盘

    private func isWritableLocked() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return fm.isWritableFile(atPath: fileURL.path) }
        return fm.isWritableFile(atPath: fileURL.deletingLastPathComponent().path)
    }

    private func saveLocked() {
        saveContentLocked()
        saveStateLocked()
    }

    /// 只写计数。检索命中后的回写走这条：正文没变，重写 Markdown 是白费 I/O
    /// （而且会让文件的修改时间每轮都跳，用户在 Finder / git 里看着很吵）。
    private func saveStateLocked() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.memory.encode(counters) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func saveContentLocked() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            loadWarning = "记忆目录建不出来：\(error.localizedDescription)"
            return
        }
        // Markdown 先写：正文是真相源。JSON 写失败最多丢计数，反过来会丢内容。
        guard let data = document.render().data(using: .utf8) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // 自己写完要同步哨兵，否则下一轮会把自己的写入误判成「外部改动」而重读，
            // 白做一次 parse 还会把 run 级限额计数清零。
            loadedMTime = Self.modificationDate(of: fileURL)
        } catch {
            loadWarning = "记忆文件写不进去：\(error.localizedDescription)"
        }
    }
}

// MARK: - 编解码口径

extension JSONEncoder {
    /// 记忆状态文件的统一编码口径。日期用 ISO8601：JSON 里的可读时间，
    /// 出问题时人眼能直接看出「这条到底多久没用了」。
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
