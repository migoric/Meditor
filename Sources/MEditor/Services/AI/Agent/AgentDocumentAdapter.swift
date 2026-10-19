import Foundation

// MARK: - Protocol

/// AppState 交互的抽象 — 封装所有对 Tab / 编辑器 / 文件树 / Toast 的操作。
/// 工具不直接感知此协议；AgentContext 把它与 AgentFileRepository 组合后暴露 AgentContextProtocol。
@MainActor
protocol AgentDocumentAdapter: AnyObject {
    var currentDocument: String?     { get }
    var currentDocumentName: String? { get }
    var workspaceURL: URL?           { get }
    var currentTabURL: URL?          { get }   // 供 resolveFile 优先级排序用
    /// 当前激活 tab 的稳定身份（tab 锁定校验用，见 DocumentContext.currentTabID）
    var currentTabID: UUID?          { get }

    // 当前文档（Tab）操作
    func writeDocument(_ content: String) throws
    func patchDocument(find: String, replace: String, all: Bool) throws -> Int
    func insertIntoDocument(_ text: String)

    // Tab 查询 & 操作
    func contentForTab(at url: URL) -> String?  // 返回 nil 表示未打开或尚未加载
    func openFile(at url: URL) -> Bool
    /// 是否有已打开的 Tab 对应此文件（写入 confinement 的散文件例外）
    func hasOpenTab(at url: URL) -> Bool

    // 文件操作完成后的通知（由 AgentContext 在磁盘 IO 后回调）
    func notifyFileCreated(_ url: URL)
    func notifyFileWritten(_ url: URL, content: String, isNew: Bool)
    func notifyDirectoryCreated(_ url: URL)

    // 命令授权
    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool
    /// 取消挂起的命令确认（Runner 超时/正常结束时触发），恢复工具内挂起的 continuation。
    func cancelPendingCommandConfirmation()

    // 文件写入授权（与命令确认同一范式）
    /// 向用户展示确认条，询问是否允许 agent 写入/修改该文件。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool
    /// 携带 diff 预览的写入确认（协议要求，保证 existential 动态分发；
    /// 默认实现转发旧签名，见下方 extension）。
    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool
    /// 写前审阅（改前 diff 预览的默认主流程）：返回用户批准后的最终内容，
    /// nil = 用户拒绝/取消（协议要求；默认实现退化为 confirmFileWrite 的 Bool 语义）。
    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String?
    /// 取消挂起的文件写入确认（Runner 超时/正常结束时触发），语义与
    /// cancelPendingCommandConfirmation 完全对齐。
    func cancelPendingWriteConfirmation()
    /// 本次 agent run 的「全部允许」开关（确认条点过「本次运行全部允许」后为 true）。
    var isFileWriteAllowedForRun: Bool { get }
}

extension AgentDocumentAdapter {
    /// 默认无打开 Tab——mock / 测试实现无需关心此方法。
    func hasOpenTab(at url: URL) -> Bool { false }
    /// 默认无 tab 身份——mock / 测试实现的 tab 锁定校验按「未切换」通过。
    var currentTabID: UUID? { nil }
    /// 默认无挂起确认——mock / 测试实现无需关心此方法。
    func cancelPendingCommandConfirmation() {}
    /// 默认放行——mock / headless 实现无需感知写入确认流程，不破坏既有 conformer。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool { true }
    /// 默认丢弃 diff、转发旧签名——只实现 path/summary 版本的 conformer 语义不变。
    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        await confirmFileWrite(preview.path, summary: preview.summary)
    }
    /// 默认退化为 Bool 确认条语义——未接入审阅 UI 的 conformer（mock / headless）行为不变。
    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String? {
        await confirmFileWrite(preview) ? newContent : nil
    }
    /// 默认无挂起确认——与 cancelPendingCommandConfirmation 的默认实现同理。
    func cancelPendingWriteConfirmation() {}
    /// 默认无「全部允许」状态——未接入 UI 的实现每次写都走 confirmFileWrite（其默认实现放行）。
    var isFileWriteAllowedForRun: Bool { false }
}

// MARK: - AppState Implementation

@MainActor
final class AppStateDocumentAdapter: AgentDocumentAdapter {

    weak var appState: AppState?

    /// 用于 patchDocument / currentDocument 在 Tab 尚未加载时的读盘 fallback
    let fileRepo: any AgentFileRepository

    init(appState: AppState, fileRepo: any AgentFileRepository) {
        self.appState = appState
        self.fileRepo = fileRepo
    }

    // MARK: - State

    var currentDocument: String? {
        guard let tab = appState?.selectedTab else { return nil }
        // Tab 刚打开，内容异步加载中：回退读盘，避免 agent 误判"文件为空"
        if tab.awaitingInitialContent {
            return (try? fileRepo.readFileSyncFallback(at: tab.url)) ?? tab.content
        }
        return tab.content
    }

    var currentDocumentName: String? { appState?.selectedTab?.name }
    var workspaceURL: URL?           { appState?.rootURL }
    var currentTabURL: URL?          { appState?.selectedTab?.url.standardizedFileURL }
    var currentTabID: UUID?          { appState?.selectedTab?.id }

    // MARK: - Document ops

    func writeDocument(_ content: String) throws {
        guard let state = appState,
              let tab = state.selectedTab else { throw AgentContextError.noActiveDocument }
        state.updateTabContent(tab.id, content: content)
        // 写后自检：内容已应用到 tab（最下游统一点），防抖合并后自动跑诊断
        state.agentWriteSelfCheck.notifyAgentWrite(url: tab.url, content: content)
    }

    func patchDocument(find: String, replace: String, all: Bool = false) throws -> Int {
        guard let state = appState,
              let tab = state.selectedTab else { throw AgentContextError.noActiveDocument }
        let original = tab.awaitingInitialContent
            ? ((try? fileRepo.readFileSyncFallback(at: tab.url)) ?? tab.content)
            : tab.content
        let (updated, count) = PatchEngine.apply(to: original, find: find, replace: replace, all: all)
        if count == 0 {
            throw PatchNotFoundError(
                find: find,
                nearbyContext: PatchEngine.nearbyContext(in: original, around: find)
            )
        }
        state.updateTabContent(tab.id, content: updated)
        // 写后自检：内容已应用到 tab（最下游统一点），防抖合并后自动跑诊断
        state.agentWriteSelfCheck.notifyAgentWrite(url: tab.url, content: updated)
        return count
    }

    func insertIntoDocument(_ text: String) {
        guard let state = appState else { return }
        let tabID = state.selectedTab?.id
        state.insertIntoEditor(text)
        // 写后自检：与 writeDocument / patchDocument 同一通知点，否则插入后没有诊断条。
        // 插入走编辑器 nonce 路径（NSTextView 稍后才应用），此刻 tab.content 可能还是旧值，
        // 所以让出一个 runloop 再取内容——拿旧文本跑诊断只会给出错位的报告。
        Task { @MainActor in
            guard let tab = state.openTabs.first(where: { $0.id == tabID }) else { return }
            state.agentWriteSelfCheck.notifyAgentWrite(url: tab.url, content: tab.content)
        }
    }

    // MARK: - Tab

    func contentForTab(at url: URL) -> String? {
        appState?.openTabs.first {
            $0.url.standardizedFileURL == url.standardizedFileURL && !$0.awaitingInitialContent
        }?.content
    }

    func hasOpenTab(at url: URL) -> Bool {
        appState?.openTabs.contains {
            $0.url.standardizedFileURL == url.standardizedFileURL
        } ?? false
    }

    func openFile(at url: URL) -> Bool {
        guard let state = appState,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        state.openFile(FileItem(url: url, isDirectory: false))
        return true
    }

    // MARK: - Notifications

    func notifyFileCreated(_ url: URL) {
        guard let state = appState else { return }
        state.reloadFileTree()
        // 已在 @MainActor，无需 DispatchQueue.main.async
        state.openFile(FileItem(url: url, isDirectory: false))
        state.showToast("已创建 \(url.lastPathComponent)", icon: "doc.badge.plus")
    }

    func notifyFileWritten(_ url: URL, content: String, isNew: Bool) {
        guard let state = appState else { return }
        state.reloadFileTree()
        // 刷新已打开的同名 Tab
        if let tab = state.openTabs.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) {
            state.updateTabContent(tab.id, content: content)
            tab.isModified = false
        }
        state.reloadHTMLPreviewIfShowing(url)
        let filename = url.lastPathComponent
        if isNew {
            // 已在 @MainActor，无需 DispatchQueue.main.async
            state.openFile(FileItem(url: url, isDirectory: false))
            state.showToast("已创建 \(filename)", icon: "doc.badge.plus")
        } else {
            state.showToast("已更新 \(filename)", icon: "checkmark.circle")
        }
        // 写后自检：文件写入/新建的最终通知点（含 diff 确认后的落盘与 tab 刷新），
        // 覆盖 writeFile/patchFile/createFile 三条路径，防抖合并后自动跑诊断
        state.agentWriteSelfCheck.notifyAgentWrite(url: url, content: content)
    }

    func notifyDirectoryCreated(_ url: URL) {
        guard let state = appState else { return }
        state.reloadFileTree()
        let displayName: String
        if let root = state.rootURL?.path, url.path.hasPrefix(root) {
            displayName = String(url.path.dropFirst(root.count + 1))
        } else {
            displayName = url.lastPathComponent
        }
        state.showToast("已创建目录 \(displayName)", icon: "folder.badge.plus")
    }

    // MARK: - Command confirmation

    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool {
        guard let convo = appState?.aiConversation else { return false }
        // 注意：不在此处做会话级缓存判断。
        // 缓存策略（per-command-key）由 RunCommandTool 通过 AgentContext 管理，
        // 此方法仅负责 UI 层展示确认对话框。
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            convo.pendingCommand = PendingCommand(command: command, cwd: cwd) { approved in
                convo.pendingCommand = nil
                cont.resume(returning: approved)
            }
        }
    }

    /// Runner 超时/正常结束时拒绝挂起的命令确认，恢复工具内 withCheckedContinuation。
    /// PendingCommand.reject 幂等（answered 标记），与 AIConversation.cancelStreaming 的
    /// 补救路径不冲突（先到先生效，后到的是 no-op）。
    func cancelPendingCommandConfirmation() {
        guard let convo = appState?.aiConversation else { return }
        convo.pendingCommand?.reject()
        convo.pendingCommand = nil
    }

    // MARK: - File write confirmation

    /// 「本次运行全部允许」开关。作用域 = 本 adapter 实例：
    /// macOS 每次 run 由 AIChatCoordinator 经 AgentContext.make 新建 adapter，
    /// 因此实例级标志天然是 run 级——新 run 自动重置，无需 Runner 显式清零。
    /// 不做 per-path 缓存的理由见 PendingWrite.approveAll 注释。
    private var fileWriteAllowedForRun = false
    var isFileWriteAllowedForRun: Bool { fileWriteAllowedForRun }

    /// 旧签名入口：无 diff 数据，按「写前内容不可得」构造 preview 转发。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool {
        await confirmFileWrite(FileWritePreview(path: path, summary: summary, diff: .unavailable))
    }

    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        guard let convo = appState?.aiConversation else { return false }
        // 与 confirmCommandExecution 同范式：此方法仅负责 UI 层确认，
        // 「是否跳过确认」由工具层经 isFileWriteAllowedForRun 判断。
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            convo.pendingWrite = PendingWrite(
                path: preview.path,
                summary: preview.summary,
                diff: preview.diff,
                allowAllForRun: { [weak self] in self?.fileWriteAllowedForRun = true }
            ) { approved in
                convo.pendingWrite = nil
                cont.resume(returning: approved)
            }
        }
    }

    /// Runner 超时/正常结束/用户停止时拒绝挂起的写入确认（PendingWrite.reject 幂等，
    /// 与 AIConversation.cancelStreaming 的补救路径不冲突）。
    func cancelPendingWriteConfirmation() {
        if let convo = appState?.aiConversation {
            convo.pendingWrite?.reject()
            convo.pendingWrite = nil
        }
        // 挂起的写审阅同样取消：dismiss 触发 DiffReviewState.onCancel，
        // 恢复工具内挂起的 continuation（resume 幂等，双通道先到先生效）。
        // 先取出再调：dismiss 链上可能重入本方法（dismiss → activeRunner.cancel
        // → cancelPendingWriteConfirmation），先清空保证重入是 no-op。
        let cancel = pendingReviewCancel
        pendingReviewCancel = nil
        cancel?()
    }

    // MARK: - 写前 diff 审阅（默认主流程）

    /// 挂起的写审阅取消闭包（Runner 结束/超时/用户停止时恢复工具内 continuation）。
    private var pendingReviewCancel: (() -> Void)?

    /// 改前 diff 审阅：写工具不落盘，先把「写前 vs 写后」挂到 DiffReviewState 审阅态，
    /// 用户全部接受 / 逐块接受后返回合并内容；全部拒绝或关闭 = 主动取消（nil，不落盘）。
    /// 「自动应用」开关打开、审阅数据不可得（超大/读失败）、审阅视图被占用时，
    /// 退回原确认条安全网——审阅是默认主流程，不是唯一通路。
    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String? {
        // 设置里开了「自动应用」（高信任用户）：保持确认条流程，不进审阅态
        guard !AppSettings.shared.aiAgentAutoApplyWrites, let appState else {
            return await confirmFileWrite(preview) ? newContent : nil
        }
        // 审阅态需要完整写前内容 + 段落级 diff；新文件按纯新增审阅
        let original: String
        switch base {
        case .existing(let content): original = content
        case .newFile:               original = ""
        case .unavailable:
            return await confirmFileWrite(preview) ? newContent : nil
        }
        guard case .hunks(let hunks) = preview.diff else {
            // 超大文件（.tooLarge）：不算段落 diff，退回确认条（与快照上限同取舍）
            return await confirmFileWrite(preview) ? newContent : nil
        }
        // 无实质改动：不打扰用户，直接放行
        if hunks.isEmpty { return newContent }
        // 审阅视图被占用（如行内编辑进行中）：不抢占，退回确认条
        guard !appState.diffReview.isPresented else {
            return await confirmFileWrite(preview) ? newContent : nil
        }
        let path = preview.path
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            // resume 幂等：finalize / onCancel / cancelPendingWriteConfirmation 多通道先到先生效；
            // 生效后清掉 pendingReviewCancel——审阅已结束，run 收尾的兜底取消不得再
            // dismiss 别的（可能是行内编辑后续打开的）审阅视图。
            var resumed = false
            let resume: (String?) -> Void = { [weak self] value in
                guard !resumed else { return }
                resumed = true
                self?.pendingReviewCancel = nil
                cont.resume(returning: value)
            }
            pendingReviewCancel = { [weak appState] in
                appState?.diffReview.dismiss()   // dismiss 触发 onCancel → resume(nil)
                resume(nil)
            }
            appState.diffReview.present(
                original: original, modified: newContent,
                onFinalize: { [weak appState] merged in
                    let diffs = appState?.diffReview.diffs ?? []
                    // 逐块全部拒绝 = 用户主动取消：不落盘、不算错误。
                    // 不能用 merged == original 判定——mergedContent() 经段落
                    // 归一化（trim/重拼），对真实文件几乎永不相等
                    guard diffs.contains(where: { $0.status == .accepted }) else {
                        resume(nil)
                        return
                    }
                    // 全部接受且快照未过期：直通模型原文（字节保真），不经过段落
                    // 归一化；快照已过期（rebase）时必须用 merged 保住用户在他处的编辑
                    let snapshotCurrent = appState?.diffReview.currentContentProvider?()
                        .map { $0 == original } ?? true
                    if diffs.allSatisfy({ $0.status == .accepted }), snapshotCurrent {
                        resume(newContent)
                    } else {
                        resume(merged)
                    }
                }
            )
            // present 会重置以下闭包，必须在 present 之后注入。
            // 快照过期防护（与行内编辑同一机制）：写回时以目标 tab 当前内容重定位合并，
            // 目标段落已被用户改动则拒绝覆盖、保留审阅界面。目标不在已打开 tab 中
            // 时无 provider，保持快照索引合并。
            appState.diffReview.currentContentProvider = { [weak appState] in
                guard let appState else { return nil }
                if let tab = appState.selectedTab, tab.name == path { return tab.content }
                return appState.openTabs.first { $0.url.path == path }?.content
            }
            appState.diffReview.onRebaseConflict = { [weak appState] in
                appState?.showToast(L("ai.inline.targetLost"), icon: "exclamationmark.triangle")
            }
            appState.diffReview.onCancel = { resume(nil) }
        }
    }
}
