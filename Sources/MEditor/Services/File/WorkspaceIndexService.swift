import Foundation

// MARK: - Search Match

/// 单条工作区搜索结果：相对路径 + 1-based 行号 + 行原文。
/// lineNumber == 0 表示「文件名匹配」（无行内容，仅供 UI 全局搜索展示文件行）。
struct WorkspaceSearchMatch: Sendable, Equatable {
    let relativePath: String
    let lineNumber: Int
    let line: String
}

// MARK: - WorkspaceIndexService

/// 工作区全文内容索引（macOS / iOS 共享层，纯 Foundation，无外部依赖）。
///
/// 生命周期：打开工作区时 `buildIndex` 全量建立 → 文件变化（FSEvents / 保存）
/// 走 `scheduleRefresh` / `updateFile` 增量更新 → 关闭工作区 `clear` 释放。
/// 消费方：全局搜索 UI（⌘⇧F）与 Agent 的 search_workspace 工具共用同一实例。
///
/// 数据结构取舍：不建倒排索引，而是把每个文件的「原文行 + 小写行」整表驻留内存，
/// 查询时逐行子串扫描。理由：
///   - Markdown 工作区千级文件总量在 ~10MB 量级，逐行扫描实测百毫秒级（见下），
///     配合 UI 200ms 防抖与 actor 后台执行，输入即搜体验达标；
///   - CJK 文本没有空白分词，倒排索引对短语查询会退化成回表扫描，复杂度不值；
///   - 子串语义与 grep fallback 完全一致，索引/非索引路径的 Agent 结果可对齐。
/// 代价：内存约为文本总量 2 倍（原文 + 小写缓存），靠 512KB 单文件上限兜底。
///
/// 线程模型：actor。索引读写全部在 actor 内串行执行，IO 天然离开主线程；
/// 调用方（AppState / Agent repository）以 async 方式访问。
actor WorkspaceIndexService {

    /// 单文件索引上限：超过则跳过（大文件多为导出产物/数据文件，搜索价值低，
    /// 且全量驻留内存会放大常驻占用）。
    static let maxIndexedFileBytes = 512_000

    private struct IndexedFile {
        var relativePath: String
        var modificationDate: Date?
        var lines: [String]         // 原文行（结果预览）
        var loweredLines: [String]  // 逐行小写缓存（大小写不敏感搜索免重复分配）
        // 取舍记录：曾试过「小写全文一次 range(of:) 扫描 + 行号二分」，实测 debug/release
        // 均比逐行 contains 慢 3 倍以上（String 全文 range(of:) 常数项很大），已回退。
    }

    private var root: URL?
    /// 任何增删改都会让 didSet 把 sortedFilesCache 置 nil——缓存键序随索引自动失效。
    private var files: [URL: IndexedFile] = [:] {
        didSet { sortedFilesCache = nil }
    }
    /// 按 relativePath 排序的遍历键序缓存：search 每次查询都全量排序一次千级字典
    /// 是纯浪费（结果集上限提前退出也排在排序之后），索引不变时序也不变。
    private var sortedFilesCache: [(url: URL, file: IndexedFile)]?
    /// 测试观测口：排序键序的重建次数（缓存生效时多次 search 只应重建一次）。
    private(set) var sortedOrderBuildCount = 0
    /// 防抖/代际标记：scheduleRefresh 连发时只保留最后一次；buildIndex/clear 会取消未执行的 refresh。
    private var refreshGeneration = 0

    // isReady 走独立锁盒而非 actor 隔离：Agent 搜索在「索引构建中」时需要零等待
    // 直接回退 grep 路径，不能排在 actor 队列里等整个构建完成。
    // let 属性允许 nonisolated 访问，无需 nonisolated(unsafe)。
    private final class ReadyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
    private let readyFlag = ReadyFlag()
    private final class BuildRequestFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _root: URL?
        var root: URL? {
            get { lock.lock(); defer { lock.unlock() }; return _root }
            set { lock.lock(); _root = newValue; lock.unlock() }
        }
    }
    private let buildRequestFlag = BuildRequestFlag()

    /// 在工作区扫描开始前登记最新 root 并让旧索引立即失效，晚到的旧构建会被拒绝。
    nonisolated func prepareBuild(root: URL?) {
        buildRequestFlag.root = root
        readyFlag.value = false
    }

    /// 首次全量构建是否已完成。构建中/已清空为 false。
    nonisolated var isReady: Bool { readyFlag.value }

    private func setReady(_ value: Bool) { readyFlag.value = value }

    /// 已索引文件数（诊断/测试用）。
    var indexedFileCount: Int { files.count }

    // MARK: - 全量构建

    /// 打开工作区时的全量重建。整个构建在 actor 内同步完成（IO 在后台执行），
    /// 期间到达的 search 调用会排队到构建结束后执行——UI 输入即搜自然得到最新结果。
    func buildIndex(root: URL) {
        prepareBuild(root: root)
        buildIndex(root: root, enumeratedFiles: Self.enumerateWorkspaceFiles(root: root),
                   requireCurrentRequest: true)
    }

    /// 枚举结果已由组合根（AppState 的工作区扫描合一）提供时的构建入口：
    /// 消费方不再自行枚举整树。`enumeratedFiles` 必须满足与本服务
    /// `enumerateWorkspaceFiles` 相同的谓词（由 FileService.scanWorkspace 保证）。
    func buildIndex(root: URL, enumeratedFiles: [URL], requireCurrentRequest: Bool = false) {
        refreshGeneration &+= 1   // 取消未执行的增量刷新
        guard !requireCurrentRequest || buildRequestFlag.root == root else { return }
        self.root = root
        setReady(false)
        var newFiles: [URL: IndexedFile] = [:]
        for url in enumeratedFiles {
            if let file = Self.loadFile(at: url, root: root) {
                newFiles[url] = file
            }
        }
        guard !requireCurrentRequest || buildRequestFlag.root == root else {
            setReady(false)
            return
        }
        files = newFiles
        setReady(true)
    }

    /// 关闭/切换工作区时释放索引。
    func clear() {
        prepareBuild(root: nil)
        refreshGeneration &+= 1
        root = nil
        files = [:]
        setReady(false)
    }

    // MARK: - 增量更新

    /// FSEvents 变化入口（内部 300ms 防抖合并连续事件）。
    /// 采用「枚举 diff」而非逐事件路径：当前 FileWatcherService 回调不带路径信息，
    /// 且枚举 + modDate 比较对千级文件是毫秒级，简单且不会漏（移动/重命名天然覆盖）。
    func scheduleRefresh(root: URL) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        refresh(root: root)
    }

    /// 与磁盘做一次 diff：新文件入库、modDate 变化的重读、已删除的移除。
    private func refresh(root: URL) {
        guard self.root == root else { return }   // 只刷新当前工作区；切换走 buildIndex
        let diskURLs = Set(Self.enumerateWorkspaceFiles(root: root))
        files = files.filter { diskURLs.contains($0.key) }
        for url in diskURLs {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let existing = files[url], existing.modificationDate == modDate { continue }
            // 新增/已修改：重读入库；变得不可读或超限时移出索引
            if let file = Self.loadFile(at: url, root: root) {
                files[url] = file
            } else {
                files.removeValue(forKey: url)
            }
        }
    }

    /// 单文件 upsert（Tab 保存 / Agent 写盘回调）。文件不在当前工作区内时忽略。
    func updateFile(at url: URL) {
        guard let root, url.path.hasPrefix(root.path + "/") else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            files.removeValue(forKey: url)
            return
        }
        if let file = Self.loadFile(at: url, root: root) {
            files[url] = file
        } else {
            files.removeValue(forKey: url)
        }
    }

    /// 单文件移除（删除回调；FSEvents diff 也会兜住，此为即时路径）。
    func removeFile(at url: URL) {
        files.removeValue(forKey: url)
    }

    // MARK: - 搜索

    /// 子串搜索（大小写不敏感），语义与 grep -i 一致：query 整体作为短语匹配。
    /// - Parameters:
    ///   - extensions: 扩展名过滤（小写、不带点）；空数组 = 全部已索引文件。
    ///   - includeFileNames: 是否额外产出「文件名匹配」行（lineNumber == 0），UI 专用。
    ///   - maxTotal / maxPerFile: 结果上限（与 grep 路径的 --max-count=5 / 100 条对齐）。
    func search(
        query: String,
        extensions: [String] = [],
        includeFileNames: Bool = false,
        maxTotal: Int = 100,
        maxPerFile: Int = 5
    ) -> [WorkspaceSearchMatch] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let exts = Set(extensions.map { $0.lowercased() })
        var results: [WorkspaceSearchMatch] = []
        // 按相对路径排序遍历：结果顺序稳定，UI 与 Agent 输出可预期、可断言。
        // 排序结果按索引代际缓存——didSet 保证任何增删都会失效重建。
        let ordered: [(url: URL, file: IndexedFile)]
        if let cached = sortedFilesCache {
            ordered = cached
        } else {
            ordered = files.sorted(by: { $0.value.relativePath < $1.value.relativePath })
                          .map { (url: $0.key, file: $0.value) }
            sortedFilesCache = ordered
            sortedOrderBuildCount &+= 1
        }
        for (url, file) in ordered {
            guard results.count < maxTotal else { break }
            if !exts.isEmpty, !exts.contains(url.pathExtension.lowercased()) { continue }
            var perFile = 0
            if includeFileNames, url.lastPathComponent.lowercased().contains(q) {
                results.append(WorkspaceSearchMatch(relativePath: file.relativePath, lineNumber: 0, line: ""))
                perFile += 1
            }
            for (index, lowered) in file.loweredLines.enumerated() {
                guard perFile < maxPerFile, results.count < maxTotal else { break }
                if lowered.contains(q) {
                    results.append(WorkspaceSearchMatch(
                        relativePath: file.relativePath, lineNumber: index + 1, line: file.lines[index]))
                    perFile += 1
                }
            }
        }
        return results
    }

    // MARK: - 内部：枚举与加载

    /// 与 AgentFileRepository 同一套枚举规则（跳过 node_modules/.git 等噪音目录、隐藏文件）。
    private static func enumerateWorkspaceFiles(root: URL) -> [URL] {
        DefaultAgentFileRepository.enumerate(
            root: root, extensions: [], noiseDirectories: DefaultAgentFileRepository.noiseDirectories)
    }

    /// 读盘 + 解码 + 切行。返回 nil 的情形：超大小上限、iCloud 占位符（触发后台下载）、
    /// 读盘失败、无法按文本解码（二进制/未知编码——与 Agent 读盘路径同一套 TextFileDecoder）。
    private static func loadFile(at url: URL, root: URL) -> IndexedFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size <= maxIndexedFileBytes else { return nil }
        if UbiquitousFileHelper.isUbiquitousItemNotDownloaded(url) {
            UbiquitousFileHelper.startDownloadingIfNeeded(url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 二进制判定：头部 8KB 内含 NUL 字节即跳过。UTF-16/32 文本天然含大量 0x00，
        // 因此带 BOM 的文件豁免，交给 TextFileDecoder 正常解码；
        // 无 BOM 的 UTF-16 会被误判为二进制——少见，取舍接受。
        let head = data.prefix(8192)
        let hasBOM = head.starts(with: [0xEF, 0xBB, 0xBF])          // UTF-8
            || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])  // UTF-16/32
        if !hasBOM, head.contains(0x00) { return nil }
        guard let text = TextFileDecoder.decode(data) else { return nil }
        let rootPath = root.path
        let relativePath = url.path.hasPrefix(rootPath + "/")
            ? String(url.path.dropFirst(rootPath.count + 1))
            : url.lastPathComponent
        let lines = text.components(separatedBy: .newlines)
        return IndexedFile(
            relativePath: relativePath,
            modificationDate: values.contentModificationDate,
            lines: lines,
            loweredLines: lines.map { $0.lowercased() }
        )
    }
}
