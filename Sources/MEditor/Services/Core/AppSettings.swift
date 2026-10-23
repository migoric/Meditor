import AppKit
import CryptoKit
import Foundation
import Observation

extension Notification.Name {
    static let autoSaveSettingsChanged    = Notification.Name("MEditor.autoSaveSettingsChanged")
    static let previewFontSizeChanged     = Notification.Name("MEditor.previewFontSizeChanged")
    static let editorFontSizeChanged      = Notification.Name("MEditor.editorFontSizeChanged")
    static let docPathChanged             = Notification.Name("MEditor.docPathChanged")
    static let claudeMonitorSettingsChanged = Notification.Name("MEditor.claudeMonitorSettingsChanged")
    static let spotlightIndexContentChanged = Notification.Name("MEditor.spotlightIndexContentChanged")
}

/// Centralized app preferences, persisted via UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let sharePort = "MEditor.sharePort"
        static let previewFontSize = "MEditor.previewFontSize"
        static let editorFontSize = "MEditor.editorFontSize"
        static let editorFontName = "MEditor.editorFontName"
        static let showEditorOnLaunch = "MEditor.showEditorOnLaunch"
        static let showPreviewOnLaunch = "MEditor.showPreviewOnLaunch"
        static let showSidebarOnLaunch = "MEditor.showSidebarOnLaunch"
        static let autoSave = "MEditor.autoSave"
        static let autoSaveInterval = "MEditor.autoSaveInterval"
        static let githubGistPublic = "MEditor.githubGistPublic"
        static let shareBaseURL = "MEditor.shareBaseURL"
        static let aiAccentStyle = "MEditor.aiAccentStyle"
        static let aiProvider = "MEditor.aiProvider"
        static let aiBaseURL = "MEditor.aiBaseURL"
        static let aiModel = "MEditor.aiModel"
        static let aiCLIPath = "MEditor.aiCLIPath"
        static let aiCLIModel    = "MEditor.aiCLIModel"
        static let aiAgentModel     = "MEditor.aiAgentModel"
        static let aiAgentMaxSteps    = "MEditor.aiAgentMaxSteps"
        static let aiRequestTimeout   = "MEditor.aiRequestTimeout"
        static let aiInlineModel      = "MEditor.aiInlineModel"
        static let aiCustomSystemPrompt = "MEditor.aiCustomSystemPrompt"
        static let aiAutoAttachContext  = "MEditor.aiAutoAttachContext"
        static let aiAgentAutoApplyWrites = "MEditor.aiAgentAutoApplyWrites"
        // 端侧智能（Apple Foundation Models）
        static let aiOnDevicePasteCleanup = "MEditor.aiOnDevicePasteCleanup"
        /// 运行轨迹落盘（默认关，见 AgentTraceStore：只存元数据，不存正文）
        static let aiTraceEnabled = "MEditor.aiTraceEnabled"
        // 设置页 AI tab「高级」区展开状态（默认收起，首屏只留一个决策）
        static let aiAdvancedExpanded = "MEditor.aiAdvancedExpanded"
        static let userDocPathBookmark = "MEditor.userDocPathBookmark"
        static let appDocPathBookmark  = "MEditor.appDocPathBookmark"
        // Claude Code 监听
        static let claudeMonitorEnabled   = "MEditor.claudeMonitorEnabled"
        static let claudeMonitorCustomPath = "MEditor.claudeMonitorCustomPath"
        static let claudeMonitorFileExts  = "MEditor.claudeMonitorFileExts"
        // 导出
        static let exportPreflightEnabled = "MEditor.exportPreflightEnabled"
        static let pdfPaperSize  = "MEditor.pdfPaperSize"
        static let pdfMargins    = "MEditor.pdfMargins"
        static let pdfShowHeader = "MEditor.pdfShowHeader"
        static let pdfShowFooter = "MEditor.pdfShowFooter"
        static let pdfCoverPage  = "MEditor.pdfCoverPage"
        // 工作区级 MCP 配置信任记录（防止 clone 不可信仓库即执行任意命令）
        static let trustedWorkspaceMCP = "MEditor.trustedWorkspaceMCP"
        // Spotlight 是否索引文档正文内容（默认关：只索引文件名/标题）
        static let spotlightIndexContent = "MEditor.spotlightIndexContent"
        // Pro 资格（定价线：免费 = 编辑器 + 手动 agent + 单篇导出；Pro = 定时自动化 + 无限托管）
        static let proLicenseKey = "MEditor.proLicenseKey"
        static let proKeyVerdict = "MEditor.proKeyVerdict"
        /// 旧格式：判定所属 key 的明文（已废弃，迁移后删除——见 proKeyVerdictKeyHash）。
        static let proKeyVerdictKey = "MEditor.proKeyVerdictKey"
        static let proKeyVerdictKeyHash = "MEditor.proKeyVerdictKeyHash"
        static let proKeyVerifiedAt = "MEditor.proKeyVerifiedAt"
    }

    /// LAN share server port (default 8899).
    var sharePort: UInt16 {
        didSet { defaults.set(Int(sharePort), forKey: Key.sharePort) }
    }

    /// Preview font size in px (default 15).
    var previewFontSize: Int {
        didSet {
            defaults.set(previewFontSize, forKey: Key.previewFontSize)
            NotificationCenter.default.post(name: .previewFontSizeChanged, object: nil)
        }
    }

    /// Editor font size in pt (default 14).
    var editorFontSize: Int {
        didSet {
            defaults.set(editorFontSize, forKey: Key.editorFontSize)
            NotificationCenter.default.post(name: .editorFontSizeChanged, object: nil)
        }
    }

    /// 编辑器正文字体（EditorFont.rawValue，默认 system）。与字号共用同一变更通知。
    var editorFontName: String {
        didSet {
            defaults.set(editorFontName, forKey: Key.editorFontName)
            NotificationCenter.default.post(name: .editorFontSizeChanged, object: nil)
        }
    }

    /// Show editor panel on launch.
    var showEditorOnLaunch: Bool {
        didSet { defaults.set(showEditorOnLaunch, forKey: Key.showEditorOnLaunch) }
    }

    /// Show preview panel on launch.
    var showPreviewOnLaunch: Bool {
        didSet { defaults.set(showPreviewOnLaunch, forKey: Key.showPreviewOnLaunch) }
    }

    /// Show sidebar on launch.
    var showSidebarOnLaunch: Bool {
        didSet { defaults.set(showSidebarOnLaunch, forKey: Key.showSidebarOnLaunch) }
    }

    /// Enable auto-save.
    var autoSave: Bool {
        didSet {
            defaults.set(autoSave, forKey: Key.autoSave)
            NotificationCenter.default.post(name: .autoSaveSettingsChanged, object: nil)
        }
    }

    /// Auto-save interval in seconds (default 30). 钳制到 5...3600：
    /// 0/负值会让重复 Timer 空转烧 CPU（UI 只提供 10/20/30/120）。
    var autoSaveInterval: Int {
        didSet {
            let clamped = min(max(autoSaveInterval, 5), 3600)
            guard clamped == autoSaveInterval else {
                autoSaveInterval = clamped   // 触发下一轮 didSet 完成落盘与通知
                return
            }
            defaults.set(autoSaveInterval, forKey: Key.autoSaveInterval)
            NotificationCenter.default.post(name: .autoSaveSettingsChanged, object: nil)
        }
    }

    /// Whether new GitHub Gists are created as public (true) or secret (false).
    var githubGistPublic: Bool {
        didSet { defaults.set(githubGistPublic, forKey: Key.githubGistPublic) }
    }

    /// 在线分享服务的 Base URL（默认 workers.dev；发布前换成自定义域名，只改这一处）。
    var shareBaseURL: String {
        didSet { defaults.set(shareBaseURL, forKey: Key.shareBaseURL) }
    }

    /// AI assistant accent style: "system" (app accent) or "shadcn" (mono black/white).
    var aiAccentStyle: String {
        didSet { defaults.set(aiAccentStyle, forKey: Key.aiAccentStyle) }
    }

    /// AI provider mode: "disabled" | "openai" | "anthropic" | "claudeCLI".
    var aiProvider: String {
        didSet { defaults.set(aiProvider, forKey: Key.aiProvider) }
    }

    /// OpenAI-compatible base URL (e.g. https://api.openai.com/v1, http://localhost:11434/v1).
    var aiBaseURL: String {
        didSet { defaults.set(aiBaseURL, forKey: Key.aiBaseURL) }
    }

    /// Model name (e.g. gpt-4o-mini, llama3.1, qwen2.5).
    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Key.aiModel) }
    }

    /// Absolute path to the local `claude` CLI binary.
    var aiCLIPath: String {
        didSet { defaults.set(aiCLIPath, forKey: Key.aiCLIPath) }
    }

    /// Claude CLI 使用的模型（空则使用 CLI 默认）。e.g. "claude-opus-4-5"
    var aiCLIModel: String {
        didSet { defaults.set(aiCLIModel, forKey: Key.aiCLIModel) }
    }

    /// Agent 工具调用专用模型（空则回退到 aiModel）。
    var aiAgentModel: String {
        didSet { defaults.set(aiAgentModel, forKey: Key.aiAgentModel) }
    }

    /// Agent 最大执行步数（默认 30）。
    var aiAgentMaxSteps: Int {
        didSet { defaults.set(aiAgentMaxSteps, forKey: Key.aiAgentMaxSteps) }
    }

    /// 单次 HTTP 请求超时（秒）。默认 300s，适配推理模型长思考。
    var aiRequestTimeout: TimeInterval {
        didSet { defaults.set(aiRequestTimeout, forKey: Key.aiRequestTimeout) }
    }

    /// 内联编辑（改写/扩写/精简/翻译）专用模型（空则回退到 aiModel）。
    var aiInlineModel: String {
        didSet { defaults.set(aiInlineModel, forKey: Key.aiInlineModel) }
    }

    /// 用户自定义系统提示词：追加到 AI 助手/Agent 的系统提示词末尾（空则不注入）。
    var aiCustomSystemPrompt: String {
        didSet { defaults.set(aiCustomSystemPrompt, forKey: Key.aiCustomSystemPrompt) }
    }

    /// 发送聊天时自动把当前激活 tab 的文档作为默认上下文注入（默认开）。
    /// 输入栏 chip 可针对单次发送移除；此开关为全局总开关。
    var aiAutoAttachContext: Bool {
        didSet { defaults.set(aiAutoAttachContext, forKey: Key.aiAutoAttachContext) }
    }

    /// Agent 写操作跳过改前 diff 审阅、确认后直接落盘（默认关 = 预览优先，
    /// 写文档/打补丁先进入逐块审阅态，用户接受后才写盘）。给信任度高的用户。
    var aiAgentAutoApplyWrites: Bool {
        didSet { defaults.set(aiAgentAutoApplyWrites, forKey: Key.aiAgentAutoApplyWrites) }
    }

    /// 每次 agent run 结束后把**元数据**轨迹写进
    /// `~/Library/Application Support/MEditor/traces/`（默认关）。
    ///
    /// 关着的理由：轨迹是排障/评测资料，不是产品功能。写盘属于"用户没要求的事"，
    /// 默认做就等于替他决定。开着的价值：出问题时有工具序列、成败、耗时、token
    /// 可复盘；评测侧也能拿它做回归比对。只记元数据（工具名/字节数/成败），
    /// 不记参数与结果正文——那里可能有文档内容。
    var aiTraceEnabled: Bool {
        didSet { defaults.set(aiTraceEnabled, forKey: Key.aiTraceEnabled) }
    }

    // MARK: - 端侧智能（Apple Foundation Models）

    /// 粘贴网页内容时用端侧模型清理广告/推广/追踪参数（默认关）。
    /// 端侧不可用或清理失败时静默回退原始转换结果，不联网。
    var aiOnDevicePasteCleanup: Bool {
        didSet { defaults.set(aiOnDevicePasteCleanup, forKey: Key.aiOnDevicePasteCleanup) }
    }

    /// 设置页 AI tab「高级」区是否展开（默认收起：首屏只保留「CLI 还是 API key」一个决策）。
    var aiAdvancedExpanded: Bool {
        didSet { defaults.set(aiAdvancedExpanded, forKey: Key.aiAdvancedExpanded) }
    }

    // MARK: - Claude Code 监听

    /// 是否启用 Claude Code 会话文件监听功能。
    var claudeMonitorEnabled: Bool {
        didSet {
            defaults.set(claudeMonitorEnabled, forKey: Key.claudeMonitorEnabled)
            NotificationCenter.default.post(name: .claudeMonitorSettingsChanged, object: nil)
        }
    }

    /// 自定义监听目录路径（空则使用默认的 ~/.claude/projects/）。
    var claudeMonitorCustomPath: String {
        didSet {
            defaults.set(claudeMonitorCustomPath, forKey: Key.claudeMonitorCustomPath)
            NotificationCenter.default.post(name: .claudeMonitorSettingsChanged, object: nil)
        }
    }

    /// 要监听的文件扩展名，逗号分隔（默认 "md,txt")。
    var claudeMonitorFileExts: String {
        didSet {
            defaults.set(claudeMonitorFileExts, forKey: Key.claudeMonitorFileExts)
            NotificationCenter.default.post(name: .claudeMonitorSettingsChanged, object: nil)
        }
    }

    // MARK: - 导出

    /// 导出 PDF/HTML 前是否先跑文档诊断（死链/缺图/标题/代码块）。
    var exportPreflightEnabled: Bool {
        didSet { defaults.set(exportPreflightEnabled, forKey: Key.exportPreflightEnabled) }
    }

    /// PDF 纸张大小（PDFExportOptions.PaperSize.rawValue，默认 a4）。
    var pdfPaperSize: String {
        didSet { defaults.set(pdfPaperSize, forKey: Key.pdfPaperSize) }
    }

    /// PDF 页边距档位（PDFExportOptions.MarginPreset.rawValue，默认 normal）。
    var pdfMargins: String {
        didSet { defaults.set(pdfMargins, forKey: Key.pdfMargins) }
    }

    /// PDF 页眉（文档标题）。
    var pdfShowHeader: Bool {
        didSet { defaults.set(pdfShowHeader, forKey: Key.pdfShowHeader) }
    }

    /// PDF 页脚（页码）。
    var pdfShowFooter: Bool {
        didSet { defaults.set(pdfShowFooter, forKey: Key.pdfShowFooter) }
    }

    /// PDF 封面页（标题 + 日期）。
    var pdfCoverPage: Bool {
        didSet { defaults.set(pdfCoverPage, forKey: Key.pdfCoverPage) }
    }

    /// 当前持久化值聚合成的 PDF 导出选项（非法 rawValue 回退默认）。
    var pdfExportOptions: PDFExportOptions {
        PDFExportOptions(
            paperSize: PDFExportOptions.PaperSize(rawValue: pdfPaperSize) ?? .a4,
            margins: PDFExportOptions.MarginPreset(rawValue: pdfMargins) ?? .normal,
            showHeader: pdfShowHeader,
            showFooter: pdfShowFooter,
            coverPage: pdfCoverPage
        )
    }

    /// 解析 `claudeMonitorFileExts` 为扩展名数组（小写无点）。
    var claudeMonitorExtensions: [String] {
        claudeMonitorFileExts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    /// 实际监听目录：自定义路径优先，空则回退到默认 ~/.claude/projects/。
    var claudeMonitorDirectory: URL {
        let custom = claudeMonitorCustomPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: - Document paths

    /// User's preferred document directory (security-scoped bookmark).
    var userDocPath: URL? {
        get { resolveBookmark(forKey: Key.userDocPathBookmark) }
    }

    func setUserDocPath(_ url: URL?) throws {
        if let url {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Key.userDocPathBookmark)
        } else {
            defaults.removeObject(forKey: Key.userDocPathBookmark)
        }
        NotificationCenter.default.post(name: .docPathChanged, object: nil)
    }

    /// App document output directory (default: Application Support/MEditor/Documents).
    var appDocPath: URL {
        get {
            if let url = resolveBookmark(forKey: Key.appDocPathBookmark) { return url }
            return defaultAppDocPath
        }
    }

    func setAppDocPath(_ url: URL?) throws {
        if let url {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Key.appDocPathBookmark)
        } else {
            defaults.removeObject(forKey: Key.appDocPathBookmark)
        }
        NotificationCenter.default.post(name: .docPathChanged, object: nil)
    }

    // MARK: - Spotlight

    /// 是否把文档**正文内容**索引进系统 Spotlight。默认关：只索引文件名/标题与修改时间。
    ///
    /// 正文进 Spotlight 意味着系统上任何能查询 Spotlight 的进程都能检索到私有笔记内容，
    /// 属明确的隐私取舍，必须用户显式开启。
    var spotlightIndexContent: Bool {
        didSet {
            defaults.set(spotlightIndexContent, forKey: Key.spotlightIndexContent)
            NotificationCenter.default.post(name: .spotlightIndexContentChanged, object: nil)
        }
    }

    // MARK: - Pro 资格

    /// Pro 密钥（官网赞助渠道发放，即 worker PRO_TOKENS 之一）。
    /// 本仓 MIT 开源——本地门控本质是「官方分发二进制的荣誉系统」：
    /// 自己编译的人拦不住，也不试图拦；这里只为官方构建提供付费边界。
    ///
    /// **存 Keychain，不存 UserDefaults。** 该值同时是**发布凭证**
    /// （worker 把 `PRO_TOKENS` 既用于 `/api/share` 的 Pro 判定，也用于
    /// `/api/pro/verify`），明文躺在 `~/Library/Preferences/com.meditor.app.plist`
    /// 里等于任何能读该文件的进程都能白嫖无限发布。此前 GitHub token、
    /// 发布 token 都走 Keychain，唯独这一条走 UserDefaults —— 与 Keychain.swift
    /// 自己写的「密钥只存 Keychain」策略自相矛盾。
    var proLicenseKey: String {
        didSet {
            // 老版本可能已经把明文写进过 defaults：每次改动顺手清掉。
            defaults.removeObject(forKey: Key.proLicenseKey)
            scheduleProKeyPersist()
        }
    }

    /// Pro key 落 Keychain 的防抖任务（见 `scheduleProKeyPersist`）。
    @ObservationIgnored private var proKeyPersistTask: Task<Void, Never>?

    /// 终止前 flush 防抖写入的观察者（见 `flushProKeyPersist`）。
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    private static let proKeychain = Keychain(service: "com.meditor.app.pro", account: "license")

    /// 设置页的 SecureField 每敲一个字符就会写一次 `proLicenseKey`；
    /// 直接同步落 Keychain 等于每键一次 `SecItemAdd`（几十毫秒，会卡输入框）。
    /// 合并到 400ms 空闲后再写，语义不变（key 生效不靠这一毫秒）。
    private func scheduleProKeyPersist() {
        proKeyPersistTask?.cancel()
        let value = proLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        proKeyPersistTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Self.proKeychain.save(value)   // 空串 = 清除（Keychain.save 的既有语义）
        }
    }

    /// 终止前把防抖窗口内待写的 Pro key 同步落 Keychain。
    /// 没有这一步时，didSet 已删掉 defaults 里的旧明文、Keychain 写入却排在
    /// 400ms 后的 Task 里——用户在输入框敲完最后几字符后 400ms 内退出（或崩溃），
    /// key 两头都不在，静默丢失。
    private func flushProKeyPersist() {
        guard let task = proKeyPersistTask else { return }
        task.cancel()
        proKeyPersistTask = nil
        Self.proKeychain.save(proLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 读 Pro key：Keychain 优先，其次把老版本的 UserDefaults 明文迁过去。
    private static func loadProLicenseKey(from defaults: UserDefaults) -> String {
        if let stored = proKeychain.load(), !stored.isEmpty { return stored }
        guard let legacy = defaults.string(forKey: Key.proLicenseKey),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        proKeychain.save(legacy)
        defaults.removeObject(forKey: Key.proLicenseKey)
        return legacy
    }

    /// `proKeyVerdictKeyHash` 对应 key 的最近一次在线验证判定（"" = 从未验证 / "valid" / "invalid"）。
    /// 离线宽限的基础：门控只读这份缓存，不联网（见 ProEntitlementService）。
    var proKeyVerdict: String {
        didSet { defaults.set(proKeyVerdict, forKey: Key.proKeyVerdict) }
    }

    /// 缓存判定所属的 key 的 SHA-256——key 一改，旧判定自然失效（防止换 key 继承 valid）。
    /// **只持久化哈希**：该值与 `proLicenseKey` 等值，明文落 plist 等于把发布凭证
    /// 在 Keychain 之外又存了一份（proLicenseKey 迁 Keychain 就白做了）。
    var proKeyVerdictKeyHash: String {
        didSet { defaults.set(proKeyVerdictKeyHash, forKey: Key.proKeyVerdictKeyHash) }
    }

    /// 最近一次在线验证成功到达服务端的时间（nil = 从未验证过；UI 展示 + 刷新节流用）。
    var proKeyVerifiedAt: Date? {
        didSet { defaults.set(proKeyVerifiedAt, forKey: Key.proKeyVerifiedAt) }
    }

    // MARK: - Workspace MCP trust
    /// 工作区级 MCP 配置（`<workspace>/.meditor/mcp.json`）的信任记录。
    ///
    /// key = 工作区标准化路径，value = 该配置文件的 SHA-256。默认不信任：工作区配置文件
    /// 可声明任意 `command`，agent 启动时会被 spawn 执行——clone 一个不可信仓库即可 RCE。
    /// 只有用户显式授权后才加载；配置文件内容变更后 hash 不再匹配，信任自动失效，需重新授权。
    private(set) var trustedWorkspaceMCP: [String: String] {
        didSet { defaults.set(trustedWorkspaceMCP, forKey: Key.trustedWorkspaceMCP) }
    }

    func isWorkspaceMCPTrusted(workspacePath: String, configHash: String) -> Bool {
        trustedWorkspaceMCP[workspacePath] == configHash
    }

    func trustWorkspaceMCP(workspacePath: String, configHash: String) {
        trustedWorkspaceMCP[workspacePath] = configHash
    }

    func revokeWorkspaceMCP(workspacePath: String) {
        trustedWorkspaceMCP.removeValue(forKey: workspacePath)
    }

    // MARK: - Theme token overrides

    /// Returns the user's saved override for a CSS token in a given theme, or nil if using the default.
    func themeToken(_ token: String, forTheme themeId: String) -> String? {
        defaults.string(forKey: "MEditor.themeToken.\(themeId).\(token)")
    }

    /// Saves (or clears, when value is nil) the user's override for a CSS token in a given theme.
    func setThemeToken(_ value: String?, token: String, forTheme themeId: String) {
        let key = "MEditor.themeToken.\(themeId).\(token)"
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    var defaultAppDocPath: URL {
        let base = FileManager.default.firstURL(for: .applicationSupportDirectory)
        let dir = base.appendingPathComponent("MEditor/Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolveBookmark(forKey key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private init() {
        let d = UserDefaults.standard
        sharePort = UInt16(d.integer(forKey: Key.sharePort) != 0 ? d.integer(forKey: Key.sharePort) : 8899)
        previewFontSize = d.integer(forKey: Key.previewFontSize) != 0 ? d.integer(forKey: Key.previewFontSize) : 15
        editorFontSize = d.integer(forKey: Key.editorFontSize) != 0 ? d.integer(forKey: Key.editorFontSize) : 14
        editorFontName = d.string(forKey: Key.editorFontName) ?? EditorFont.system.rawValue
        showEditorOnLaunch = d.object(forKey: Key.showEditorOnLaunch) != nil ? d.bool(forKey: Key.showEditorOnLaunch) : false
        showPreviewOnLaunch = d.object(forKey: Key.showPreviewOnLaunch) != nil ? d.bool(forKey: Key.showPreviewOnLaunch) : true
        showSidebarOnLaunch = d.object(forKey: Key.showSidebarOnLaunch) != nil ? d.bool(forKey: Key.showSidebarOnLaunch) : true
        autoSave = d.bool(forKey: Key.autoSave)
        autoSaveInterval = d.integer(forKey: Key.autoSaveInterval) != 0 ? d.integer(forKey: Key.autoSaveInterval) : 30
        githubGistPublic = d.bool(forKey: Key.githubGistPublic)  // default false = secret
        shareBaseURL = d.string(forKey: Key.shareBaseURL) ?? "https://meditor-app.863129776.workers.dev"
        aiAccentStyle = d.string(forKey: Key.aiAccentStyle) ?? "system"
        aiProvider = d.string(forKey: Key.aiProvider) ?? "disabled"
        aiBaseURL = d.string(forKey: Key.aiBaseURL) ?? "https://api.openai.com/v1"
        // 迁移：DeepSeek 旧模型已下线，映射到 v4 系列。
        let rawAIModel = d.string(forKey: Key.aiModel) ?? "gpt-4o-mini"
        aiModel = rawAIModel == "deepseek-chat" ? "deepseek-v4-flash"
                : rawAIModel == "deepseek-reasoner" ? "deepseek-v4-pro"
                : rawAIModel
        aiCLIPath    = d.string(forKey: Key.aiCLIPath)    ?? "/usr/local/bin/claude"
        aiCLIModel   = d.string(forKey: Key.aiCLIModel)   ?? ""
        aiAgentModel    = d.string(forKey: Key.aiAgentModel) ?? ""
        let rawMaxSteps = d.integer(forKey: Key.aiAgentMaxSteps)
        aiAgentMaxSteps = (rawMaxSteps >= 5 && rawMaxSteps <= 100) ? rawMaxSteps : 30
        let rawTimeout  = d.double(forKey: Key.aiRequestTimeout)
        aiRequestTimeout = rawTimeout >= 30 ? rawTimeout : 300   // 默认 300s
        aiInlineModel = d.string(forKey: Key.aiInlineModel) ?? ""
        aiCustomSystemPrompt = d.string(forKey: Key.aiCustomSystemPrompt) ?? ""
        aiAutoAttachContext = d.object(forKey: Key.aiAutoAttachContext) != nil
            ? d.bool(forKey: Key.aiAutoAttachContext) : true
        aiAgentAutoApplyWrites = d.bool(forKey: Key.aiAgentAutoApplyWrites)  // 默认关 = 预览优先
        aiTraceEnabled = d.bool(forKey: Key.aiTraceEnabled)                  // 默认关 = 不写盘
        // 端侧智能（默认关：用户显式开启后才过端侧模型）
        aiOnDevicePasteCleanup = d.bool(forKey: Key.aiOnDevicePasteCleanup)
        // AI 设置「高级」区（默认收起）
        aiAdvancedExpanded = d.bool(forKey: Key.aiAdvancedExpanded)
        // Claude Code 监听
        claudeMonitorEnabled    = d.object(forKey: Key.claudeMonitorEnabled) != nil ? d.bool(forKey: Key.claudeMonitorEnabled) : false
        claudeMonitorCustomPath = d.string(forKey: Key.claudeMonitorCustomPath) ?? ""
        claudeMonitorFileExts   = d.string(forKey: Key.claudeMonitorFileExts) ?? "md,txt"
        // 导出
        exportPreflightEnabled = d.object(forKey: Key.exportPreflightEnabled) != nil ? d.bool(forKey: Key.exportPreflightEnabled) : true
        pdfPaperSize  = d.string(forKey: Key.pdfPaperSize) ?? PDFExportOptions.PaperSize.a4.rawValue
        pdfMargins    = d.string(forKey: Key.pdfMargins) ?? PDFExportOptions.MarginPreset.normal.rawValue
        pdfShowHeader = d.object(forKey: Key.pdfShowHeader) != nil ? d.bool(forKey: Key.pdfShowHeader) : false
        pdfShowFooter = d.object(forKey: Key.pdfShowFooter) != nil ? d.bool(forKey: Key.pdfShowFooter) : false
        pdfCoverPage  = d.bool(forKey: Key.pdfCoverPage)   // default false
        trustedWorkspaceMCP = (d.dictionary(forKey: Key.trustedWorkspaceMCP) as? [String: String]) ?? [:]
        spotlightIndexContent = d.bool(forKey: Key.spotlightIndexContent)   // default false（隐私优先）
        // Pro 资格（key 存 Keychain；老版本的 UserDefaults 明文在这里一次性迁移）
        proLicenseKey = Self.loadProLicenseKey(from: d)
        proKeyVerdict = d.string(forKey: Key.proKeyVerdict) ?? ""
        // 判定所属 key 只存哈希。旧格式存的是明文（与 proLicenseKey 等值，
        // 等于凭证在 plist 又躺一份）：迁移为哈希并持久化，旧键无论是否有值都删掉。
        // init 里的赋值不触发 didSet，所以迁移分支要显式 defaults.set。
        if let hashed = d.string(forKey: Key.proKeyVerdictKeyHash), !hashed.isEmpty {
            proKeyVerdictKeyHash = hashed
        } else if let legacy = d.string(forKey: Key.proKeyVerdictKey), !legacy.isEmpty {
            let migrated = ProKeyCacheHash.hash(legacy)
            proKeyVerdictKeyHash = migrated
            d.set(migrated, forKey: Key.proKeyVerdictKeyHash)
        } else {
            proKeyVerdictKeyHash = ""
        }
        d.removeObject(forKey: Key.proKeyVerdictKey)
        proKeyVerifiedAt = d.object(forKey: Key.proKeyVerifiedAt) as? Date
        // 防抖窗口内退出不丢 key（见 flushProKeyPersist）。
        // willTerminate 在 .main 队列派发，assumeIsolated 在此成立——不是消音器。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushProKeyPersist() }
        }
    }
}

/// Pro 判定缓存的 key 关联哈希：缓存要按 key 绑定（换 key 旧判定失效），
/// 但持久化的只能是哈希，不能是 key 明文。
enum ProKeyCacheHash {
    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 编辑器正文字体候选，持久化存 rawValue（见 AppSettings.editorFontName）。
/// 菜单显示名直接用字体本名（不本地化），system 的文案在设置页取 L("settings.editorFont.system")。
enum EditorFont: String, CaseIterable {
    case system           // 系统默认（SF，对 CJK 渲染最稳）
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case newYork = "New York"
    case pingFang = "PingFang SC"

    var displayName: String { rawValue }
}
