import Foundation
import Observation

// MARK: - AgentRunCheckpoint（run 级文件快照，一键回滚的数据层）
//
// 设计取舍：
//   - 快照只存内存（单次 run 级别，App 重启后不恢复）。run 快照挂在 AgentRunState 上，
//     而 AgentRunState 本身就是内存态（不落盘），生命周期天然一致；要做持久化回滚
//     得解决「磁盘文件在两次启动间被外部改动」的校验问题，复杂度与收益不对等。
//   - 文本文件内存开销可控，单文件快照设 1MB 上限：超出则不快照（notSnapshotable），
//     回滚时跳过该文件并明确提示，绝不恢复一个残缺快照。
//   - 收集点不在各写工具里，而在 AgentContext 的写路径（唯一汇聚点）：
//     createFile / writeFile / patchFile / writeDocument / patchDocument 统一在此
//     记录快照，工具层与 adapter 层无感知。

/// 单个被写文件的快照：写前状态 + run 最后一次写入后的内容。
struct AgentFileSnapshot: Equatable {

    /// 写前状态
    enum PreWriteState: Equatable {
        /// 文件已存在，记录原内容（回滚 = 恢复为该内容）
        case existed(String)
        /// 文件原本不存在（create_file / write_file 新建；回滚 = 删除该文件）
        case didNotExist
        /// 未快照（超过大小上限或读盘/解码失败）——回滚时跳过该文件并明确提示
        case notSnapshotable(String)
    }

    /// 目标文件（standardized 后的绝对路径 URL）
    let url: URL
    let preWrite: PreWriteState
    /// run 最后一次写入后的完整内容，回滚安全校验基准：回滚时文件当前内容必须等于它，
    /// 否则说明 run 结束后用户又改过，跳过该文件（绝不覆盖用户编辑——红线）。
    /// nil = 快照后写入未成功（工具抛错），文件实际未被改动，回滚时忽略。
    var postWriteContent: String?
}

/// 回滚动作（planRollback 的产出，纯数据，便于单测与 UI 渲染）。
enum AgentRollbackAction: Equatable, Sendable {
    /// 恢复文件到写前内容
    case restore(url: URL, content: String)
    /// 删除本次 run 新建的文件
    case deleteCreated(url: URL)
    /// 跳过该文件（原因供 UI 明确提示）
    case skip(url: URL, reason: AgentRollbackSkipReason)
}

/// 跳过原因（结构化而非文案字符串：UI 层负责本地化，测试断言不依赖文案）。
enum AgentRollbackSkipReason: Equatable, Sendable {
    /// run 结束后文件内容又有变化（用户手动编辑 / 外部进程改动），为避免覆盖而跳过
    case editedAfterRun
    /// 文件已不存在（用户已自行删除，无需也无法处理）
    case fileMissing
    /// 当初未快照（过大 / 读取失败），无恢复依据
    case notSnapshotable(String)
}

/// 一次 agent run 的文件快照集合。run 期间由 AgentContext 写路径逐步填充，
/// run 结束后挂到 AgentRunState 上供 UI 提供「撤销本次运行的全部修改」入口。
@MainActor
@Observable
final class AgentRunCheckpoint {

    /// 单文件快照大小上限（1 MB）。超出不快照——宁可回滚时跳过并提示，
    /// 也不为大文件付出常驻内存，更不恢复残缺内容。
    static let maxSnapshotBytes = 1_000_000

    /// 按写入先后有序保存（回滚按同序执行，先写先恢复）。
    private(set) var snapshots: [AgentFileSnapshot] = []
    /// 已快照文件的路径集合（standardized path），保证同一文件只记一次写前状态。
    private var capturedKeys: Set<String> = []

    /// 是否已执行过回滚（幂等保护 + UI「已回滚」态）。
    private(set) var isRolledBack = false
    /// 回滚结果摘要（由执行方写入，UI 展示）。
    private(set) var rollbackSummary: String?

    /// 本次 run 是否有成功写入的文件（决定 UI 是否展示回滚入口）。
    var hasWrites: Bool { snapshots.contains { $0.postWriteContent != nil } }

    /// 可回滚文件数（写入成功的快照条数），供入口文案展示。
    var rollbackableCount: Int { snapshots.count(where: { $0.postWriteContent != nil }) }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    // MARK: - 快照采集（AgentContext 写路径调用；同一文件只首次生效）

    /// 新建文件（create_file / write_file 落到不存在的路径）：记「原本不存在」。
    func captureCreatedFile(url: URL) {
        let key = Self.key(for: url)
        guard !capturedKeys.contains(key) else { return }
        capturedKeys.insert(key)
        snapshots.append(AgentFileSnapshot(url: url.standardizedFileURL, preWrite: .didNotExist, postWriteContent: nil))
    }

    /// 覆盖写前记录：调用方已掌握写前内容（tab 内存原文 / patch 前读出的原文）。
    func captureBeforeWrite(url: URL, knownContent: String) {
        let key = Self.key(for: url)
        guard !capturedKeys.contains(key) else { return }
        capturedKeys.insert(key)
        let state: AgentFileSnapshot.PreWriteState =
            knownContent.utf8.count > Self.maxSnapshotBytes
            ? .notSnapshotable("文件超过快照大小上限（\(Self.maxSnapshotBytes / 1_000_000)MB）")
            : .existed(knownContent)
        snapshots.append(AgentFileSnapshot(url: url.standardizedFileURL, preWrite: state, postWriteContent: nil))
    }

    /// 覆盖写前记录：写前内容未知时的兜底采集。打开的 tab 内存内容优先
    /// （用户视角的最新内容，可能含未保存编辑——与 fileContentFull 的取舍一致）；
    /// 否则同步读盘（小文件同步读的取舍与 `TabManager.openFile` 一致，那边阈值 512KB；
    /// 这里的上限是快照自己的 `maxSnapshotBytes`，1MB）。
    func captureBeforeWrite(url: URL, tabContent: String?) {
        if let tabContent {
            captureBeforeWrite(url: url, knownContent: tabContent)
            return
        }
        let std = url.standardizedFileURL
        let key = Self.key(for: std)
        guard !capturedKeys.contains(key) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: std.path) else {
            // 走到这里说明调用方判断失误（以为存在实则不存在），按新建语义记录
            captureCreatedFile(url: std)
            return
        }
        capturedKeys.insert(key)
        let state: AgentFileSnapshot.PreWriteState
        if let size = try? std.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxSnapshotBytes {
            state = .notSnapshotable("文件超过快照大小上限（\(Self.maxSnapshotBytes / 1_000_000)MB）")
        } else if let data = try? Data(contentsOf: std), let text = TextFileDecoder.decode(data) {
            state = .existed(text)
        } else {
            state = .notSnapshotable("读取原内容失败")
        }
        snapshots.append(AgentFileSnapshot(url: std, preWrite: state, postWriteContent: nil))
    }

    /// 写入成功后更新基准内容（同文件多次写只移动 postWrite，不动写前快照）。
    func markWritten(url: URL, content: String) {
        let key = Self.key(for: url)
        guard let idx = snapshots.firstIndex(where: { Self.key(for: $0.url) == key }) else { return }
        snapshots[idx].postWriteContent = content
    }

    // MARK: - 回滚规划（纯函数：无副作用，执行在 AppState+AgentRollback）

    /// 生成回滚动作序列。
    /// - Parameter currentContent: 返回文件「当前最准确」内容的闭包
    ///   （调用方实现：打开的 tab 内存内容优先，否则读盘；文件不存在返回 nil）。
    /// 安全校验（与 DiffReviewState 的 rebase 校验同一思路）：当前内容必须等于
    /// postWriteContent 才恢复/删除，否则跳过——run 结束后的用户编辑绝不被覆盖。
    func planRollback(currentContent: (URL) -> String?) -> [AgentRollbackAction] {
        snapshots.compactMap { snap in
            // 写入未成功的快照无改动可回滚，直接忽略（不算跳过，不打扰用户）
            guard let post = snap.postWriteContent else { return nil }
            switch snap.preWrite {
            case .notSnapshotable(let reason):
                return .skip(url: snap.url, reason: .notSnapshotable(reason))
            case .existed(let pre):
                guard let current = currentContent(snap.url) else {
                    return .skip(url: snap.url, reason: .fileMissing)
                }
                return current == post
                    ? .restore(url: snap.url, content: pre)
                    : .skip(url: snap.url, reason: .editedAfterRun)
            case .didNotExist:
                guard let current = currentContent(snap.url) else {
                    return .skip(url: snap.url, reason: .fileMissing)
                }
                return current == post
                    ? .deleteCreated(url: snap.url)
                    : .skip(url: snap.url, reason: .editedAfterRun)
            }
        }
    }

    /// 执行方完成回滚后调用：置位已回滚态并记录摘要（幂等，重复调用无效）。
    func markRolledBack(summary: String) {
        guard !isRolledBack else { return }
        isRolledBack = true
        rollbackSummary = summary
    }
}
