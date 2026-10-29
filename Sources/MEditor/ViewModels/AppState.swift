import Foundation
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

enum EditorLanguage: String {
    case markdown
    case html
}

/// What the preview pane is currently showing.
enum PreviewMode: Equatable {
    case empty
    case markdown
    case html
}

/// Central coordinator / thin facade.
///
/// Owns cross-cutting state (rootURL, selectedFileID) and wires together
/// five domain Managers. Forwarding API is split into extension files:
///
///   AppState+Tabs.swift        → Tab lifecycle forwarding
///   AppState+FileTree.swift    → File tree, CRUD, open-folder, coordination
///   AppState+Preview.swift     → Preview forwarding
///   AppState+Session.swift     → Session persistence
///   AppState+ExternalMod.swift → External file-change detection + auto-save
@MainActor
@Observable
final class AppState {

    // MARK: - Managers

    let tabManager: TabManager
    let fileTreeManager: FileTreeManager
    let previewManager: PreviewManager
    let shareManager: ShareManager
    let githubGistManager: GitHubGistManager
    let shareLinkPublisher: ShareLinkPublisher
    let templateManager: TemplateManager
    let pluginManager: PluginManager
    let presentationManager: PresentationManager

    /// 工作区 Git 状态（侧边栏文件树 M/A/? 标记）；非 git 工作区静默为空。
    let gitStatusService = GitStatusService()

    /// Agent 命令审批缓存（App 会话级）：safe 命令批准一次，整个会话内
    /// 不再逐轮弹框——缓存从 per-context（每轮消息新建即失效）提升到共享实例。
    let commandApprovals = CommandApprovalStore()

    /// MCP 客户端管理器（App 会话级单例）：内置 Agent 连接外部 MCP server，
    /// 把远端工具纳入工具目录。懒连接——agent run 开始时才真正拉起 server。
    let mcpClientManager = MCPClientManager()

    /// AI assistant conversation store (multi-session, persisted).
    /// Lazy so disk I/O is deferred until the AI panel is first opened.
    @ObservationIgnored
    private(set) lazy var aiConversation: AIConversation = AIConversation()

    #if os(macOS)
    /// Pro 资格（macOS-only）：定时任务门控 + 设置页 Pro key 管理。
    /// 门控只读缓存判定、不联网；联网验证由设置页按钮与此处的启动保守刷新触发。
    let proEntitlement = ProEntitlementService.shared
    /// 后台 Agent 任务（macOS-only）：脱离聊天 UI 独立运行 agent run，
    /// 完成后 toast + 系统通知。lazy：首次发起后台任务时才创建。
    @ObservationIgnored
    private(set) lazy var backgroundAgentTasks = BackgroundAgentTaskService(host: self)
    /// 定时任务调度（macOS-only）：cron 命中时复用 backgroundAgentTasks 发起后台 run。
    /// lazy + init 末尾主动触碰：随 App 启动生效，首次访问前不占资源。
    @ObservationIgnored
    private(set) lazy var agentScheduler = AgentSchedulerService(host: self)
    #endif

    /// 全局待办状态，两个 Todo 视图共享同一份数据。
    let todoStore = TodoStore()

    // MARK: - Core shared state

    var rootURL: URL? {
        didSet {
            shareManager.sync(rootURL: rootURL, openTabs: tabManager.openTabs)
            if !isRestoringSession { scheduleSessionPersist() }
            // 工作区切换 → 重建三方索引（一次枚举分发）；关闭（nil）→ 释放
            if rootURL?.standardizedFileURL != oldValue?.standardizedFileURL {
                rebuildWorkspaceIndex(root: rootURL)
                if rootURL == nil { gitStatusService.clear() }
                #if os(macOS)
                // 工作区切换 → 重载定时任务配置（全局 + 工作区合并）
                agentScheduler.reload(workspaceURL: rootURL)
                #endif
            }
        }
    }

    var selectedFileID: URL?

    // MARK: - AI UI State

    let aiUI = AIUIState()

    // MARK: - Diff Review State

    let diffReview = DiffReviewState()

    /// Agent 写后自检：写工具内容生效后防抖合并跑本地诊断，有问题在 AI 面板报告。
    let agentWriteSelfCheck = AgentWriteSelfCheck()
    /// 多一层直接属性，避免嵌套 @Observable 被 SwiftUI 漏追踪的问题
    var showingDiffReview: Bool {
        get { diffReview.isPresented }
        set { diffReview.isPresented = newValue }
    }
    /// 每次 mentionItems 更新时递增，供 AtMentionPickerView .task(id:) 追踪变化
    var mentionItemsVersion: Int = 0

    /// @mention 搜索用的文件+目录全量列表。
    /// 作为 AppState 的真正存储属性（非 computed 转发），确保 @Observable 能追踪变化，
    /// 由 fileTreeManager.onMentionItemsUpdated 回调同步。
    var mentionItems: [FileItem] = []

    // MARK: - Cursor / Status bar

    var cursorLine: Int = 1
    var cursorColumn: Int = 1
    /// 最近一次保存成功的时间，用于状态栏短暂显示"已保存"提示。
    var lastSavedAt: Date? = nil
    /// NativeEditorView 出现时置 true，消失时置 false。
    /// 用于 insertIntoEditor 判断走光标插入路径还是追加路径。
    var isEditorMounted: Bool = false
    var editorVisibleLine: Int = 0
    var previewVisibleLine: Int = 0
    var editorScrollCommand: ScrollSyncCommand = .idle
    var previewScrollCommand: ScrollSyncCommand = .idle

    // MARK: - Editor selection tracking (NSRange, updated by EditorCoordinator)
    var editorSelectedRange: NSRange = NSRange(location: 0, length: 0)

    // Computed wrappers keep View layer unchanged while delegating to AIUIState.
    var editorSelectedText: String {
        get { aiUI.editorSelectedText }
        set { aiUI.editorSelectedText = newValue }
    }
    var editorInsertText: String { aiUI.editorInsertText }
    var editorInsertNonce: Int { aiUI.editorInsertNonce }

    var editorReplaceText: String { aiUI.editorReplaceText }
    var editorReplaceNonce: Int { aiUI.editorReplaceNonce }
    var editorWriteBackContent: String { aiUI.editorWriteBackContent }
    var editorWriteBackNonce: Int { aiUI.editorWriteBackNonce }
    var pendingReplaceRange: NSRange? {
        get { aiUI.pendingReplaceRange }
        set { aiUI.pendingReplaceRange = newValue }
    }

    /// AI 写回的统一入口：编辑器挂载且目标是当前 tab 时走编辑器可撤销写回
    /// （最小化替换，保留滚动位置/光标/undo 链）；否则退回整体替换路径
    /// （预览独占等场景，updateTabContent 内部已处理预览同步与防抖保存）。
    func applyAIWriteBack(_ tabID: UUID, content: String) {
        if tabID == selectedTab?.id, isEditorMounted {
            aiUI.requestWriteBack(content)
        } else {
            updateTabContent(tabID, content: content)
        }
    }

    func insertIntoEditor(_ text: String) {
        guard let tab = selectedTab else { return }

        if isEditorMounted {
            // 编辑器可见：走 nonce 路径，在光标处插入（保留光标位置）
            aiUI.requestInsert(text)
        } else {
            // 编辑器隐藏（纯预览 / AI 模式）：先算出新内容，再统一走 updateTabContent。
            // 不能直接改 tab.content —— 那样不会置 isModified，saveTab 的
            // `guard tab.isModified` 与自动保存过滤都会跳过，导致内容永不落盘，
            // closeTab 也会当作干净 tab 直接关闭（静默丢数据）。
            let newContent: String
            if tab.language == .html {
                // HTML 文件：插入到 </body> 之前，保持结构合法
                let bodyClose = "</body>"
                if let range = tab.content.range(of: bodyClose, options: .caseInsensitive) {
                    newContent = tab.content.replacingCharacters(
                        in: range, with: "\n" + text + "\n" + bodyClose)
                } else {
                    newContent = tab.content + "\n" + text
                }
            } else {
                // Markdown 及其他文本：追加到末尾
                let separator = tab.content.isEmpty ? "" : "\n\n"
                newContent = tab.content + separator + text
            }
            // updateTabContent：置 isModified、递增 contentRevision、同步预览、
            // 并在开启自动保存时安排防抖落盘。
            updateTabContent(tab.id, content: newContent)
        }
    }

    func replaceInEditor(_ text: String) {
        aiUI.requestReplace(text)
    }

    var previewSelectedText: String {
        get { aiUI.previewSelectedText }
        set { aiUI.previewSelectedText = newValue }
    }

    var previewSelectedRect: CGRect {
        get { aiUI.previewSelectedRect }
        set { aiUI.previewSelectedRect = newValue }
    }

    @discardableResult
    func replaceInMarkdownSource(original: String, replacement: String) -> Bool {
        guard let tab = selectedTab else { return false }
        let content = tab.content

        // 找到所有出现位置
        var ranges: [Range<String.Index>] = []
        var searchStart = content.startIndex
        while let found = content.range(of: original, range: searchStart..<content.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
            // 超过 2 个就没必要继续找了
            if ranges.count > 1 { break }
        }

        guard !ranges.isEmpty else { return false }

        if ranges.count > 1 {
            // 文本在文档中出现多次，无法精确定位，提示用户手动处理
            let msg = L("ai.error.replaceAmbiguous")
            setError(msg)
            return false
        }

        // 统一走 updateTabContent：置 isModified、递增 revision、同步预览、按需防抖保存。
        // 直接改 tab.content 会绕过 isModified，导致替换永不落盘。
        let newContent = content.replacingCharacters(in: ranges[0], with: replacement)
        updateTabContent(tab.id, content: newContent)
        return true
    }

    var currentFileSize: String {
        guard let tab = selectedTab else { return "" }
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(tab.content.utf8.count))
    }

    // MARK: - UI overlay

    var errorMessage: String?
    var toastMessage: ToastMessage?

    /// 打开 AI 面板，并把选中文本作为「引用选段」带入（显示为输入框上方的引用卡片）。
    func openAssistantWithSelection(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        aiUI.quotedContext = t.isEmpty ? nil : t
        aiUI.showingAssistant = true
    }

    func showToast(_ text: String, icon: String? = nil) {
        withAnimation(DS.Motion.fast) {
            toastMessage = ToastMessage(text, icon: icon)
        }
    }

    var showingQuickOpen = false {
        didSet {
            if showingQuickOpen {
                showingBeautifySheet = false
                showingGlobalSearch = false
                // Lazily build the file index only when QuickOpen is actually opened.
                if let root = rootURL { fileTreeManager.ensureIndexReady(rootURL: root) }
            }
        }
    }
    /// 全局搜索面板（⌘⇧F）：基于 workspaceIndex 的内容搜索浮层。
    var showingGlobalSearch = false {
        didSet { if showingGlobalSearch { showingQuickOpen = false } }
    }
    var showingSettings = false
    /// 请求设置页打开时定位到的 tab（首启引导的「配置 AI 服务」深链到 AI tab）；
    /// 一次性消费，SettingsHeroOverlay 展示后清零。
    var settingsRequestedTab: SettingsView.SettingsTab? = nil
    /// SettingsHeroOverlay 遮罩/面板展开的真实动画状态（与 showingSettings 不同：
    /// 后者立即置位驱动 overlay 的挂载/卸载，这个值才是 spring 动画实际驱动的
    /// 那个开合状态）。EditorTabBar 的 tab 条暗化需要跟这个值同步，不能读
    /// showingSettings，否则两处动画时序错位。
    var settingsOverlayShown = false
    var showingCloseProjectConfirmation = false
    var showingAIAssistant: Bool {
        get { aiUI.showingAssistant }
        set { aiUI.showingAssistant = newValue }
    }
    var showingBeautifySheet = false {
        didSet { if showingBeautifySheet { showingQuickOpen = false } }
    }
    /// 文档诊断面板（工具菜单）：本地规则引擎扫描工作区死链/缺图/标题问题。
    var showingDiagnostics = false {
        didSet {
            if showingDiagnostics {
                showingQuickOpen = false
                showingGlobalSearch = false
            }
        }
    }
    /// 「让 Agent 修复」写回发生时记录的工作区问题基线数；诊断面板重开后
    /// 完成首次扫描时据此生成「修了几条、剩几条」对比横幅并清零。
    var diagnosticsFixBaseline: Int? = nil
    /// 文件历史面板（工具菜单）：当前文件的本地保存快照列表 + diff + 恢复。
    var showingLocalHistory = false {
        didSet {
            if showingLocalHistory {
                showingQuickOpen = false
                showingGlobalSearch = false
            }
        }
    }
    /// 导出前检查清单（功能7）：非 nil 时 ContentView 弹检查 sheet。
    var exportPreflight: ExportPreflightContext? = nil
    /// PDF 导出选项 sheet（功能9）：确认后以持久化选项导出。
    var showingPDFExportOptions = false
    /// 记住触发 PDF 导出时的建议文件名，选项 sheet 确认后使用。
    var pdfExportSuggestedName = "Untitled"
    var showingInlineEdit = false

    // MARK: - Services

    let fileService: FileServiceProtocol
    let fileWatcher: any FileWatcherServiceProtocol
    let themeStore: PreviewThemeStore
    let sessionStore: SessionStore
    let filePickerService: FilePickerServiceProtocol
    /// 本地历史快照存取（保存时落快照、历史面板读取与恢复）。
    /// 可注入：测试传临时目录的 store，避免 init 的后台清理碰到真实 ~/Library。
    let historyStore: LocalHistoryStore

    // MARK: - 工作区内容索引（全局搜索 UI 与 Agent search_workspace 共用）

    let workspaceIndex = WorkspaceIndexService()

    /// 首启引导的一键演示流程（临时目录写示例文档 + 自动发 Agent 指令）
    let agentDemoFlow = AgentDemoFlow()
    /// 首次全量构建完成标记（@Observable 可追踪），搜索 UI 用它显示「索引构建中…」。
    private(set) var workspaceIndexReady = false
    @ObservationIgnored private var workspaceScanGeneration = 0

    /// rootURL 变化时重建/释放索引；枚举与构建均在后台执行，不占主线程。
    ///
    /// 三方索引（文件树 QuickOpen/@mention、WorkspaceIndexService 内容索引、
    /// 系统 Spotlight）共用 `FileService.scanWorkspace` 的一次目录枚举——
    /// 此前三方各自为政，打开工作区要把整棵树扫三遍（性能方案批 4）。
    /// 扫描谓词取三方并集、按消费方原谓词过滤，各方可见集合不变
    /// （谓词对齐的取舍见 scanWorkspace 注释）。
    private func rebuildWorkspaceIndex(root: URL?) {
        workspaceScanGeneration &+= 1
        let generation = workspaceScanGeneration
        workspaceIndexReady = false
        let index = workspaceIndex
        index.prepareBuild(root: root)
        let spotlight = SpotlightIndexManager.shared
        guard let root else {
            Task { await index.clear() }
            // 关闭工作区：按 domain 清理 Spotlight 索引项
            Task { await spotlight.clearWorkspace() }
            return
        }
        // 正文是否进 Spotlight 索引由用户显式设置（默认只索引文件名/标题）。
        let includeContent = AppSettings.shared.spotlightIndexContent
        let service = fileService
        let tree = fileTreeManager
        Task { [weak self] in
            // 只有目录扫描离开 MainActor（FileService 是 Sendable）；
            // 三方 Manager/Service 的 actor 调用留在原 actor 上，不做跨域捕获。
            let scan = await Task.detached(priority: .utility) {
                service.scanWorkspace(under: root)
            }.value
            guard let self, self.workspaceScanGeneration == generation,
                  self.rootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            tree.applyScannedIndex(files: scan.treeFiles, items: scan.treeItems, rootURL: root)
            guard self.workspaceScanGeneration == generation,
                  self.rootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            await index.buildIndex(root: root, enumeratedFiles: scan.contentFileURLs,
                                   requireCurrentRequest: true)
            guard self.workspaceScanGeneration == generation,
                  self.rootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            self.workspaceIndexReady = true
            // 系统 Spotlight 全量索引（批量后台写入；切换工作区时旧 domain 由 reindex 内部清理）。
            await spotlight.reindex(root: root, enumeratedFiles: scan.markdownFileURLs,
                                    includeContent: includeContent)
        }
    }

    /// FSEvents 变化后的索引增量刷新（服务内部防抖；首次构建未完成时由 buildIndex 全量兜底）。
    func scheduleWorkspaceIndexRefresh(root: URL) {
        let index = workspaceIndex
        Task { await index.scheduleRefresh(root: root) }
    }

    // MARK: - 散文件 & Claude 监听

    let looseFiles = LooseFilesStore()

    /// Claude 创建文件时弹出的提示（有按钮的 Toast）
    var claudeFilePrompt: ClaudeFilePrompt? = nil

    @ObservationIgnored private let claudeMonitor = ClaudeSessionMonitor()
    @ObservationIgnored private var claudeMonitorObserver: Any?

    // MARK: - Internal bookkeeping

    @ObservationIgnored private(set) var accessRefCounts: [URL: Int] = [:]
    @ObservationIgnored var isRestoringSession = false
    @ObservationIgnored private var sessionPersistScheduled = false
    // deinit 是 nonisolated，访问 Timer/Any 这类非 Sendable 的主 actor 属性在 Swift 6 下
    // 会报错；这些资源只在主线程创建/使用、且在 deinit（唯一引用）中清理，标注 unsafe 即可。
    @ObservationIgnored nonisolated(unsafe) var autoSaveTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) var autoSaveObserver: Any?
    /// Spotlight 正文索引开关变更的观察者（切换后立即按新口径重建当前工作区索引）。
    @ObservationIgnored nonisolated(unsafe) private var spotlightContentObserver: Any?
    /// 输入停止后 2 秒触发保存的防抖计时器。
    @ObservationIgnored nonisolated(unsafe) var debounceSaveTimer: Timer?
    /// Mod-dates for open files; used by AppState+ExternalMod.
    @ObservationIgnored var externalModDates: [URL: Date] = [:]

    // MARK: - Init

    init(
        fileService: FileServiceProtocol = FileService(),
        fileWatcher: any FileWatcherServiceProtocol = FileWatcherService(),
        themeStore: PreviewThemeStore = PreviewThemeStore(),
        sessionStore: SessionStore = SessionStore(),
        filePicker: FilePickerServiceProtocol? = nil,
        historyStore: LocalHistoryStore = LocalHistoryStore()
    ) {
        self.fileService     = fileService
        self.fileWatcher     = fileWatcher
        self.themeStore      = themeStore
        self.sessionStore    = sessionStore
        self.filePickerService = filePicker ?? MacFilePickerService()
        self.historyStore    = historyStore
        self.tabManager      = TabManager(fileService: fileService)
        self.fileTreeManager = FileTreeManager(fileService: fileService)
        self.previewManager  = PreviewManager()
        self.shareManager    = ShareManager()
        self.githubGistManager = GitHubGistManager()
        // 发布在线链接的 HTML 取自预览 webview（PreviewExporter 持有弱引用）
        let exporter = self.previewManager.exporter
        self.shareLinkPublisher = ShareLinkPublisher(webViewProvider: { [weak exporter] in exporter?.webView })
        self.templateManager = TemplateManager()
        self.pluginManager   = PluginManager()
        self.presentationManager = PresentationManager()
        wireTabManagerCallbacks()
        setupAutoSaveTimer()
        pluginManager.load()
        setupClaudeMonitor()
        setupSpotlightContentObserver()
        fileTreeManager.onMentionItemsUpdated = { [weak self] in
            guard let self else { return }
            self.mentionItems = self.fileTreeManager.mentionItems
            self.mentionItemsVersion &+= 1
        }
        scheduleHistoryPrune()
        // 写后自检接线：Agent run 进行时顺延防抖窗口（不拿中途态误报）；
        // 发现问题时 toast 通知（AI 面板内的报告条由 UI 直接读 pendingReport）。
        agentWriteSelfCheck.shouldDefer = { [weak self] in
            self?.aiConversation.isResponding ?? false
        }
        agentWriteSelfCheck.onReport = { [weak self] report in
            self?.showToast(L("ai.selfcheck.toast", report.totalCount), icon: "stethoscope")
        }
        #if os(macOS)
        // 启动时即生效定时任务（无工作区时也会触发全局条目）
        _ = agentScheduler
        // 有 Pro key 且缓存判定过期时后台联网复核（门控本身不联网，只读缓存）
        proEntitlement.refreshIfNeeded()
        #endif
    }

    deinit {
        autoSaveTimer?.invalidate()
        debounceSaveTimer?.invalidate()
        if let obs = autoSaveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = spotlightContentObserver { NotificationCenter.default.removeObserver(obs) }
        for url in accessRefCounts.keys { url.stopAccessingSecurityScopedResource() }
    }

    /// Spotlight 正文索引开关变更：立即按新口径重建当前工作区索引。
    private func setupSpotlightContentObserver() {
        spotlightContentObserver = NotificationCenter.default.addObserver(
            forName: .spotlightIndexContentChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let root = self.rootURL else { return }
                await SpotlightIndexManager.shared.reindex(
                    root: root, includeContent: AppSettings.shared.spotlightIndexContent)
            }
        }
    }

    // MARK: - Claude 监听配置

    private func setupClaudeMonitor() {
        // 注册事件回调（无论开关状态如何均只注册一次）
        claudeMonitor.onFileCreated = { [weak self] event in
            guard let self else { return }
            self.handleClaudeFileCreated(event)
        }

        // 仅开启时启动
        let settings = AppSettings.shared
        if settings.claudeMonitorEnabled {
            claudeMonitor.start(
                directory: settings.claudeMonitorDirectory,
                extensions: settings.claudeMonitorExtensions
            )
        }

        // 设置变更时重启监听（只注册一次，存储 token 防止重复注册）
        claudeMonitorObserver = NotificationCenter.default.addObserver(
            forName: .claudeMonitorSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartClaudeMonitorIfNeeded() }
        }
    }

    private func restartClaudeMonitorIfNeeded() {
        let settings = AppSettings.shared
        claudeMonitor.stop()
        if settings.claudeMonitorEnabled {
            claudeMonitor.start(
                directory: settings.claudeMonitorDirectory,
                extensions: settings.claudeMonitorExtensions
            )
        }
    }

    private func handleClaudeFileCreated(_ event: ClaudeFileEvent) {
        // 如果文件已经在散文件列表，不重复提示
        guard !looseFiles.contains(event.fileURL) else { return }
        withAnimation(DS.Motion.fast) {
            claudeFilePrompt = ClaudeFilePrompt(
                fileURL: event.fileURL,
                onAccept: { [weak self] in
                    guard let self else { return }
                    self.claudeFilePrompt = nil
                    self.looseFiles.add(event.fileURL, source: .claude)
                    self.openLooseFile(event.fileURL)
                },
                onDismiss: { [weak self] in
                    self?.claudeFilePrompt = nil
                }
            )
        }
    }

    /// 打开一个散文件（Tab 已打开则跳转，否则新建 Tab）。
    func openLooseFile(_ url: URL) {
        // 如果已有 Tab 则跳转
        if let existing = openTabs.first(where: { $0.url == url }) {
            selectedTabID = existing.id
            return
        }
        let item = FileItem(url: url, isDirectory: false)
        openFile(item)
        // 确保在散文件列表中有记录
        looseFiles.add(url, source: .manual)
    }

    // MARK: - TabManager callback wiring

    private func wireTabManagerCallbacks() {
        tabManager.onOpenTabsChanged = { [weak self] in
            guard let self else { return }
            self.shareManager.sync(rootURL: self.rootURL, openTabs: self.tabManager.openTabs)
            if !self.isRestoringSession { self.scheduleSessionPersist() }
        }
        tabManager.onSelectedTabIDChanged    = { [weak self] in
            guard let self, !self.isRestoringSession else { return }
            self.scheduleSessionPersist()
        }
        tabManager.onScheduleSessionPersist  = { [weak self] in self?.scheduleSessionPersist() }
        tabManager.onSyncPreview             = { [weak self] tab in self?.previewManager.sync(from: tab) }
        tabManager.onClearPreview            = { [weak self] in self?.previewManager.clear() }
        tabManager.onSyncSidebarSelection    = { [weak self] tab in self?.syncSidebarSelectionToTab(tab) }
        tabManager.onSetSelectedFileID       = { [weak self] url in self?.selectedFileID = url }
        tabManager.onBeginAccessing          = { [weak self] url in self?.beginAccessing(url) }
        tabManager.onEndAccessing            = { [weak self] url in self?.endAccessing(url) }
        tabManager.onRequiresDirectFileAccess = { [weak self] url in self?.requiresDirectFileAccess(url) ?? true }
        tabManager.onRecordModDate           = { [weak self] url in self?.recordModDate(for: url) }
        tabManager.onReport                  = { [weak self] err in self?.report(err) }
        tabManager.onDidSave                 = { [weak self] in self?.lastSavedAt = Date() }
        tabManager.onDidWriteContent         = { [weak self] url, content in
            self?.recordHistorySnapshot(url: url, content: content)
        }
        tabManager.onDidWriteToDisk          = { [weak self] url in
            self?.previewManager.reloadHTML(url: url)
            // 保存落盘后即时刷新内容索引（FSEvents diff 路径之外的就地快路径）
            guard let self else { return }
            let index = self.workspaceIndex
            Task { await index.updateFile(at: url) }
            let spotlight = SpotlightIndexManager.shared
            Task { await spotlight.updateFile(at: url, includeContent: AppSettings.shared.spotlightIndexContent) }
        }
    }

    // MARK: - Shared helpers (used by multiple extensions)

    func scheduleSessionPersist() {
        guard !sessionPersistScheduled else { return }
        sessionPersistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionPersistScheduled = false
            self.persistSession()
        }
    }

    /// 所有经 setError 的错误统一落一条日志——此前大量调用点只把
    /// localizedDescription 糊给用户，出错后无任何可观测记录。
    func setError(_ message: String) {
        AppLog.app.error("setError: \(message, privacy: .public)")
        errorMessage = message
    }

    func report(_ error: AppError, logger: Logger = AppLog.app) {
        AppLog.error(error, in: logger)
        if error.severity == .user { errorMessage = error.errorDescription }
    }

    func beginAccessing(_ url: URL) {
        let s = url.standardizedFileURL
        if let c = accessRefCounts[s] { accessRefCounts[s] = c + 1; return }
        if s.startAccessingSecurityScopedResource() { accessRefCounts[s] = 1 }
    }

    func endAccessing(_ url: URL) {
        let s = url.standardizedFileURL
        guard let c = accessRefCounts[s] else { return }
        if c > 1 { accessRefCounts[s] = c - 1; return }
        accessRefCounts.removeValue(forKey: s)
        s.stopAccessingSecurityScopedResource()
    }

    /// 测试可见：当前 security-scoped 访问的引用计数（生产代码不用）。
    func accessRefCount(for url: URL) -> Int? { accessRefCounts[url.standardizedFileURL] }

    func requiresDirectFileAccess(_ url: URL) -> Bool {
        guard let rootURL else { return true }
        return !fileTreeManager.isSameOrDescendant(url, of: rootURL)
    }

    func updateCursorPosition(line: Int, column: Int) { cursorLine = line; cursorColumn = column }

    func requestEditorScroll(to line: Int, select: Bool = false) {
        guard line >= 0 else { return }
        editorScrollCommand = editorScrollCommand.advanced(to: line, select: select)
    }

    func requestPreviewScroll(to line: Int) {
        guard line >= 0 else { return }
        previewScrollCommand = previewScrollCommand.advanced(to: line)
    }

    // MARK: - ShareManager forwarding

    var shareServer: ShareManager { shareManager }
    func syncShareServerState() { shareManager.sync(rootURL: rootURL, openTabs: openTabs) }

    // MARK: - TemplateManager forwarding

    var showingTemplatePicker: Bool {
        get { templateManager.showingPicker }
        set { templateManager.showingPicker = newValue }
    }
    var showingSaveTemplate: Bool {
        get { templateManager.showingSaveAs }
        set { templateManager.showingSaveAs = newValue }
    }
    var saveTemplateName: String {
        get { templateManager.saveAsName }
        set { templateManager.saveAsName = newValue }
    }
    var templateCreateParentURL: URL? {
        get { templateManager.pendingParentURL }
        set { templateManager.pendingParentURL = newValue }
    }

    func createFromTemplate(_ template: DocumentTemplate) {
        templateManager.createFromTemplate(
            template, rootURL: rootURL, fileService: fileService,
            onSuccess: { [weak self] item in self?.reloadFileTree(); self?.openFile(item) },
            onError:   { [weak self] err  in self?.report(err, logger: AppLog.file) }
        )
    }

    func saveCurrentAsTemplate(name: String) {
        guard let tab = selectedTab else { return }
        do    { try templateManager.saveAs(name: name, content: tab.content) }
        catch { setError(error.localizedDescription) }
    }

    // MARK: - Todo helpers

    /// 将一条新待办写入当前编辑文件末尾（md）；无打开文件时写入 rootURL/inbox.md。
    /// 磁盘写入在后台执行，完成后同步编辑器内容。
    func appendTodoToCurrentFile(_ text: String) {
        let targetURL: URL
        if let tab = selectedTab, tab.url.pathExtension.lowercased() == "md" {
            targetURL = tab.url
        } else if let root = rootURL {
            targetURL = root.appendingPathComponent("inbox.md")
        } else {
            showToast(L("toast.noWorkspace"), icon: "exclamationmark.triangle")
            return
        }
        Task {
            do {
                let newContent = try await todoStore.addTodo(text: text, to: targetURL)
                // 同步编辑器
                if let tab = selectedTab, tab.url == targetURL {
                    tab.content = newContent
                    tab.contentRevision &+= 1
                }
                showToast(L("toast.todoAdded", targetURL.lastPathComponent), icon: "checkmark.circle")
            } catch {
                report(.fileWrite(targetURL, underlying: error), logger: AppLog.file)
            }
        }
    }

    // MARK: - Presentation Mode

    /// 是否正在演讲模式放映中。
    var isPresenting: Bool { presentationManager.isPresenting }

    /// 放映期间的主题跟踪是否已注册（withObservationTracking 单次触发，防止重复挂链）。
    @ObservationIgnored private var isObservingPresentationTheme = false

    /// 以当前选中的 Markdown 文档进入演讲模式（无选中或非 Markdown 时无操作）。
    func startPresentation() {
        guard let tab = selectedTab, tab.language == .markdown else { return }
        presentationManager.start(markdown: tab.content, sourceURL: tab.url, theme: themeStore.current)
        // 放映期间跟踪预览主题切换，实时同步到放映页
        if presentationManager.isPresenting {
            observePresentationThemeChanges()
        }
    }

    /// 把当前 Markdown 文档导出为演讲稿（无选中或非 Markdown 时无操作）。
    /// 保存面板带格式弹窗：自包含 HTML（浏览器放映）或 .pptx（PowerPoint/Keynote/WPS）。
    /// 两种格式共用 `SlideSplitter` 的同一份分页结果。
    func exportPresentation() {
        guard let tab = selectedTab, tab.language == .markdown else { return }
        let slides = SlideSplitter.split(tab.content)
        let baseName = tab.url.deletingPathExtension().lastPathComponent + "-slides"
        let pptxType = UTType(filenameExtension: "pptx", conformingTo: .compositeContent) ?? .data

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.title = L("export.presentation.title")
        savePanel.nameFieldStringValue = baseName + ".html"
        savePanel.allowedContentTypes = [.html]

        let popup = FormatPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        popup.addItems(withTitles: [L("export.presentation.formatHTML"), L("export.presentation.formatPPTX")])
        popup.onChange = { [weak savePanel] index in
            guard let savePanel else { return }
            let isPPTX = index == 1
            savePanel.allowedContentTypes = isPPTX ? [pptxType] : [.html]
            let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
            savePanel.nameFieldStringValue = base + (isPPTX ? ".pptx" : ".html")
        }

        let label = NSTextField(labelWithString: L("export.presentation.format"))
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        savePanel.accessoryView = accessory

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                if popup.indexOfSelectedItem == 1 {
                    let data = PPTXExporter.makePPTX(
                        slides: slides,
                        title: tab.url.deletingPathExtension().lastPathComponent
                    )
                    try data.write(to: url)
                } else {
                    // file:// 形式的 <base href>，使导出的 HTML 在浏览器中能加载相对路径图片
                    let baseHref = tab.url.deletingLastPathComponent().absoluteString
                    guard let html = PresentationExporter.makeHTML(
                        slides: slides, theme: self.themeStore.current, baseHref: baseHref
                    ) else {
                        self.showToast(L("toast.presentationResourcesMissing"), icon: "exclamationmark.triangle")
                        return
                    }
                    try html.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                let format = popup.indexOfSelectedItem == 1 ? "PPTX" : "HTML"
                self.report(.exportFailed(format: format, underlying: error), logger: AppLog.exporter)
            }
        }
    }

    /// 放映期间用 withObservationTracking 跟踪预览主题并转发给放映窗口。
    /// 该跟踪单次触发，因此每次变化后需要续订，直到放映结束。
    private func observePresentationThemeChanges() {
        guard !isObservingPresentationTheme else { return }
        isObservingPresentationTheme = true
        withObservationTracking {
            _ = themeStore.current
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingPresentationTheme = false
                guard self.presentationManager.isPresenting else { return }
                self.presentationManager.applyTheme(self.themeStore.current)
                self.observePresentationThemeChanges()
            }
        }
    }
}

/// 保存面板格式弹窗：自承载 target/action，把选中变化转成闭包回调。
/// （NSControl.target 是弱引用，独立 target 对象还得找地方 retain；自 target 最省事。）
private final class FormatPopUpButton: NSPopUpButton {
    var onChange: ((Int) -> Void)?

    override init(frame frameRect: NSRect, pullsDown flag: Bool) {
        super.init(frame: frameRect, pullsDown: flag)
        target = self
        action = #selector(selectionDidChange)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectionDidChange() {
        onChange?(indexOfSelectedItem)
    }
}
