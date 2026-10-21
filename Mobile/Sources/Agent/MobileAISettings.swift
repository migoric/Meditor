import Foundation
import Observation

/// 移动端 AI 配置：provider / baseURL / model 存 UserDefaults，启动时构造 AIConfig。
/// API Key 存 Keychain（复用 macOS 的共享 Keychain.swift，Security framework）；
/// 旧版明文存 UserDefaults 的 key 在首次启动时迁移进 Keychain 并删除明文。
@MainActor
@Observable
final class MobileAISettings {

    private enum Key {
        static let provider = "meditor.mobile.aiProvider"
        static let baseURL  = "meditor.mobile.aiBaseURL"
        static let model    = "meditor.mobile.aiModel"
        static let agentModel   = "meditor.mobile.aiAgentModel"
        static let agentMaxSteps = "meditor.mobile.aiAgentMaxSteps"
        static let customSystemPrompt = "meditor.mobile.aiCustomSystemPrompt"
        /// 旧版明文存储 key，仅用于一次性迁移（迁移后删除）。
        static let legacyApiKey = "meditor.mobile.aiApiKey"
    }

    /// Agent 步数预算的合法区间：与桌面端 `AppSettings.aiAgentMaxSteps` 的读取校验一致
    /// （低于 5 步几乎必然半途而废，高于 100 步只会烧 token）。
    static let agentMaxStepsRange: ClosedRange<Int> = 5...100
    /// 步数默认值：与 `AgentRunner` 的 init 默认值同源。
    static let defaultAgentMaxSteps = 30

    private static let keychain = Keychain(service: "com.meditor.mobile.ai", account: "api-key")

    var provider: AIProviderKind {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Key.provider) }
    }
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Key.baseURL) }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Key.model) }
    }
    var apiKey: String {
        didSet { Self.keychain.save(apiKey) }   // 空字符串等同清除
    }

    /// Agent（工具调用）专用模型；空则回退到 `model`。
    /// 与桌面端「分场景模型」同一语义，解析规则收在 `AIConfig.resolveModel`。
    /// 桌面端的第三个场景（内联编辑）iOS 没有对应入口，故不设字段：
    /// 留一个没人读的设置项比不提供更糟。
    var agentModel: String {
        didSet { UserDefaults.standard.set(agentModel, forKey: Key.agentModel) }
    }

    /// Agent 单次运行的最大步数。写入时夹到 `agentMaxStepsRange`：
    /// 设置页是数字键盘输入，用户可能敲出 0 或 9999，越界值会让 runner
    /// 立刻报「超过最大步数」或长时间不收敛。
    var agentMaxSteps: Int {
        didSet {
            let clamped = min(max(agentMaxSteps, Self.agentMaxStepsRange.lowerBound),
                              Self.agentMaxStepsRange.upperBound)
            // 在自己的 didSet 里回写不会再次触发观察（Swift 语义：观察器只在
            // 外部写入时调用），所以可以直接把越界值改小/改大再落盘。
            if clamped != agentMaxSteps { agentMaxSteps = clamped }
            UserDefaults.standard.set(clamped, forKey: Key.agentMaxSteps)
        }
    }

    /// 用户自定义系统提示词：追加到 AI 对话的系统提示词末尾（空则不注入）。
    var customSystemPrompt: String {
        didSet { UserDefaults.standard.set(customSystemPrompt, forKey: Key.customSystemPrompt) }
    }

    init() {
        let d = UserDefaults.standard
        provider = AIProviderKind(rawValue: d.string(forKey: Key.provider) ?? "") ?? .disabled
        baseURL  = d.string(forKey: Key.baseURL) ?? "https://api.openai.com/v1"
        // 迁移：DeepSeek 旧模型已下线，映射到 v4 系列。
        let rawModel = d.string(forKey: Key.model) ?? "gpt-4o-mini"
        model    = rawModel == "deepseek-chat" ? "deepseek-v4-flash"
                 : rawModel == "deepseek-reasoner" ? "deepseek-v4-pro"
                 : rawModel
        // 迁移：旧版明文存 UserDefaults 的 API Key 搬进 Keychain 并删除明文。
        if let legacy = d.string(forKey: Key.legacyApiKey) {
            if !legacy.isEmpty { Self.keychain.save(legacy) }
            d.removeObject(forKey: Key.legacyApiKey)
        }
        apiKey = Self.keychain.load() ?? ""
        customSystemPrompt = d.string(forKey: Key.customSystemPrompt) ?? ""
        agentModel  = d.string(forKey: Key.agentModel) ?? ""
        // 与桌面端同一套校验：不在 5...100 内（含从未写过）一律回落到默认值。
        let rawMaxSteps = d.integer(forKey: Key.agentMaxSteps)
        agentMaxSteps = Self.agentMaxStepsRange.contains(rawMaxSteps)
            ? rawMaxSteps
            : Self.defaultAgentMaxSteps
    }

    /// 选中预设：自动填 provider / baseURL，并给出一个默认模型。
    func applyPreset(_ preset: AIProviderPreset) {
        provider = preset.kind
        baseURL  = preset.baseURL
        if let first = preset.models.first { model = first }
    }

    /// 当前选中的预设（baseURL 匹配则视为该预设）。
    var matchedPreset: AIProviderPreset? { AIPresets.match(baseURL) }

    /// 构造共享代码使用的 AIConfig。
    ///
    /// `scene` 决定用哪个模型：`.agent` 用 `agentModel`（空则回退到 `model`），
    /// 其余场景一律用 `model`。回退规则走共享的 `AIConfig.resolveModel`，
    /// 与桌面端「分场景模型」逐字一致——此前 iOS 只有单一模型，换聊天模型会
    /// 把 agent 一起换掉。`inline:` 恒传空串：iOS 没有内联编辑入口。
    ///
    /// `cliPath`/`cliModel` 恒为空：iOS 端没有 Claude CLI 可调（桌面端专属能力），
    /// 共享代码对空 cliPath 的语义是「不走 CLI 后端」，不是缺失配置。
    /// `requestTimeoutSeconds` 恒为 300：移动端未暴露超时设置项，与桌面端默认值
    /// （AppSettings.requestTimeout）对齐；将来若开放设置，改这一处常量即可。
    func makeConfig(scene: AIScene = .chat) -> AIConfig {
        AIConfig(
            kind: provider,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            model: AIConfig.resolveModel(
                scene: scene,
                fallback: model,
                agent: agentModel,
                inline: ""
            ),
            cliPath: "",
            cliModel: "",
            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
            requestTimeoutSeconds: Self.defaultRequestTimeoutSeconds
        )
    }

    /// 移动端固定请求超时（秒）：对齐桌面端默认值。
    ///
    /// ⚠️ 必须显式标注 `Double`：共享的 `AIConfig.requestTimeoutSeconds` 是
    /// `TimeInterval`（`Sources/MEditor/Services/AI/AIService.swift:116`，两端唯一
    /// 定义），写整数字面量会走整型字面量推断而编译失败。
    static let defaultRequestTimeoutSeconds: TimeInterval = 300
}
