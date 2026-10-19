import Foundation

/// 文件解析结果（区分唯一找到、多个同名、未找到）
enum FileResolveResult {
    case found(URL)
    case ambiguous([URL])   // 多个同名文件，按优先级排序
    case notFound

    /// 「找到 N 个同名文件」提示的统一格式（各工具调用点共用，勿再各写一遍）。
    /// 仅在 .ambiguous 分支有意义；其余分支返回 nil，调用点应先匹配分支再使用。
    func promptMessage(forQuery name: String) -> String? {
        guard case .ambiguous(let urls) = self else { return nil }
        let list = urls.prefix(5).map { "  - \($0.path)" }.joined(separator: "\n")
        return "[!] 找到 \(urls.count) 个同名文件「\(name)」，请提供更精确的路径：\n\(list)"
    }
}

// MARK: - 窄接口拆分

/// 写入免确认策略（定时任务 `autoApprove` 用，见 ScheduledTaskConfig）。
///
/// 只跳过确认条 / diff 审阅态，**不放宽任何其他边界**：写入仍被工具层限制在
/// 工作区内（resolveFile / writeFile 的工作区约束不变），run 级快照回滚照常记录
/// （checkpoint 在写工具落盘前 capture，与本策略无关）。交互式聊天 run 恒为 `.none`，
/// 确认条链路与此前完全一致。
enum WriteAutoApproval: Sendable, Equatable {
    /// 默认：每步写入都要确认（现状）。
    case none
    /// 本 run 内所有工作区写入免确认（= 预设的「本次运行全部允许」）。
    case all
    /// 仅白名单目录（工作区相对前缀）内的写入免确认；白名单外仍走确认。
    case dirs([String])

    /// 指定路径（工具层拿到的原始形态：裸文件名 / 工作区相对 / 绝对路径）是否免确认。
    func allows(path: String, workspaceRoot: URL?) -> Bool {
        switch self {
        case .none:
            return false
        case .all:
            return true
        case .dirs(let prefixes):
            guard let workspaceRoot, !prefixes.isEmpty else { return false }
            let target = Self.normalize(path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : workspaceRoot.appendingPathComponent(path))
            for prefix in prefixes {
                let dir = Self.normalize(workspaceRoot.appendingPathComponent(prefix))
                // 目录前缀比较：补尾斜杠，防止 "weekly" 误命中 "weekly-old"
                if target == dir || target.hasPrefix(dir + "/") { return true }
            }
            return false
        }
    }

    /// 归一化路径文本：标准化 + 解析符号链接。目标尚不存在时 symlink 解析可能
    /// 整体放弃（macOS 只对完整存在的路径解析），此时前缀比较失败——失败方向是
    /// 回落到确认条（保守），不会把白名单外的写入放行。
    private static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 当前文档读写操作。
@MainActor
protocol DocumentContext: AnyObject, Sendable {
    var currentDocument: String? { get }
    var currentDocumentName: String? { get }
    /// 当前激活 tab 的稳定身份标识：写工具启动时捕获、写入前校验——diff 审阅
    /// 挂起期间用户切 tab 时能识别目标已变，绝不把内容写进别的文档
    /// （与 SlashAICommandExecutor 的 sourceTabID 同一模式）。nil = 无激活 tab。
    var currentTabID: UUID? { get }
    func writeDocument(_ content: String) throws
    @discardableResult
    func patchDocument(find: String, replace: String, all: Bool) throws -> Int
    func insertIntoDocument(_ text: String)
    /// 文件级精准 patch（不依赖激活 tab）。返回替换次数；文件不存在时抛错。
    @discardableResult
    func patchFile(name: String, find: String, replace: String, all: Bool) async throws -> Int
}

extension DocumentContext {
    /// 默认无 tab 概念——mock / headless 实现恒 nil，「写入前 tab 未变」校验按通过处理。
    var currentTabID: UUID? { nil }
}

/// 工作区文件操作。
@MainActor
protocol WorkspaceContext: AnyObject, Sendable {
    var workspaceURL: URL? { get }
    func listWorkspaceFiles(extensions: [String]) async -> [URL]
    func readFile(at url: URL) async throws -> String
    /// 文件"当前最准确"的完整内容（开着的 Tab 内存内容优先，否则完整读盘；不截断）。
    func fileContentFull(at url: URL) async throws -> String
    @discardableResult func createFile(name: String, content: String) throws -> URL
    @discardableResult func writeFile(name: String, content: String) throws -> URL
    @discardableResult func createDirectory(name: String) throws -> URL
    @discardableResult func openFile(named name: String) -> Bool
    func searchWorkspace(query: String, extensions: [String]) async -> [String]
    func resolveFile(_ name: String) -> FileResolveResult
}

/// 命令沙箱与权限控制。
@MainActor
protocol ShellContext: AnyObject, Sendable {
    /// 向用户展示确认对话框，询问是否允许执行该命令。
    func confirmCommandExecution(_ command: String, cwd: String?) async -> Bool
    /// 取消挂起的命令确认（Runner 在超时/正常结束时调用）：拒绝并恢复工具内
    /// 挂起的 continuation，防止确认框弹出期间超时导致 continuation 永不恢复。
    func cancelPendingCommandConfirmation()
    func isCommandApproved(_ key: String) -> Bool
    func markCommandApproved(_ key: String)
    /// 当前 skill 声明的可执行命令前缀白名单。nil 表示无限制。
    var allowedCommandPatterns: [String]? { get }
    func setAllowedCommandPatterns(_ patterns: [String]?)

    // MARK: 文件写入确认（与命令确认同一范式）

    /// 向用户展示确认条，询问是否允许 agent 写入/修改该文件。
    /// - path：展示用目标路径（解析后的文件路径或当前文档名）；
    /// - summary：一句话变更描述（如「写入 docs/a.md（约 120 行）」）。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool
    /// 携带 diff 预览的写入确认（写工具在确认前预算好「写前 vs 写入」的段落级 diff）。
    /// 是协议要求而非扩展方法：保证 existential 调用动态分发到 conformer 的实现。
    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool
    /// 写前审阅（改前 diff 预览的默认主流程）：把「写前 vs 写后」交给用户逐块审阅，
    /// 返回用户批准后的最终内容（可能与 newContent 不同——逐块接受后的合并结果）。
    /// 返回 nil = 用户拒绝 / 全部拒绝 / 主动取消，调用方不得写入、也不应视为错误。
    /// 「是否需要审阅」由 context 决定（GUI 默认进审阅态，headless / 全部允许直接放行），
    /// 工具层不感知 UI 策略。是协议要求而非扩展方法：保证 existential 动态分发。
    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String?
    /// 取消挂起的文件写入确认（Runner 超时/正常结束时调用），语义与
    /// cancelPendingCommandConfirmation 完全对齐：拒绝并恢复工具内挂起的 continuation。
    func cancelPendingWriteConfirmation()
    /// 本次 agent run 的「全部允许」开关：用户在确认条点过「本次运行全部允许」后
    /// 为 true，之后本 run 的写工具直接放行、不再挂起确认。run 级作用域，新 run 重置。
    var isFileWriteAllowedForRun: Bool { get }
    /// 指定路径的写入是否免确认：「全部允许」为 true 时任何路径都免确认；
    /// 定时任务 autoApprove 条目的白名单命中时该路径免确认（见 WriteAutoApproval）。
    /// path 为工具层拿到的原始形态（裸文件名 / 工作区相对 / 绝对路径）。
    /// 是协议要求而非扩展方法：保证 existential 调用动态分发。
    func isFileWritePreApproved(path: String) -> Bool
}

extension ShellContext {
    /// 默认无挂起确认——mock / 测试实现无需关心此方法。
    func cancelPendingCommandConfirmation() {}
    /// 默认放行——测试 / 无 UI（headless）场景无需感知确认流程，不破坏既有 conformer。
    func confirmFileWrite(_ path: String, summary: String) async -> Bool { true }
    /// 默认丢弃 diff、转发给 path/summary 版本——只实现旧签名的既有 conformer
    /// （mock / headless）语义不变，diff 预览只有接入 UI 的实现才消费。
    func confirmFileWrite(_ preview: FileWritePreview) async -> Bool {
        await confirmFileWrite(preview.path, summary: preview.summary)
    }
    /// 默认退化为 Bool 确认条语义：批准则原样写 newContent，拒绝则 nil。
    /// 未接入审阅 UI 的 conformer（mock / headless / 移动端）行为与此前完全一致。
    func reviewFileWrite(_ preview: FileWritePreview, base: WriteBaseContent, newContent: String) async -> String? {
        await confirmFileWrite(preview) ? newContent : nil
    }
    /// 默认无挂起确认——与 cancelPendingCommandConfirmation 的默认实现同理。
    func cancelPendingWriteConfirmation() {}
    /// 默认无「全部允许」状态——未接入 UI 的实现每次写都走 confirmFileWrite（其默认实现放行）。
    var isFileWriteAllowedForRun: Bool { false }
    /// 默认只看「全部允许」——mock / headless / 移动端无 autoApprove 概念，行为与此前一致。
    func isFileWritePreApproved(path: String) -> Bool { isFileWriteAllowedForRun }
}

/// 向后兼容别名：组合三个窄接口，现有代码无需改动。
typealias AgentContextProtocol = DocumentContext & WorkspaceContext & ShellContext

// MARK: - WorkspaceContext 便利扩展
// Swift typealias 不支持 extension，resolveExistingFile 放到 WorkspaceContext 里。

extension WorkspaceContext {
    /// 把文件名 / 工作区相对路径 / 绝对路径解析为"已存在"的文件 URL。
    /// 委托给 resolveFile，取 found 或 ambiguous 的首个结果。
    func resolveExistingFile(_ name: String) -> URL? {
        switch resolveFile(name) {
        case .found(let url):       return url
        case .ambiguous(let urls):  return urls.first
        case .notFound:             return nil
        }
    }
}
