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
        static let customSystemPrompt = "meditor.mobile.aiCustomSystemPrompt"
        /// 旧版明文存储 key，仅用于一次性迁移（迁移后删除）。
        static let legacyApiKey = "meditor.mobile.aiApiKey"
    }

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
    /// `cliPath`/`cliModel` 恒为空：iOS 端没有 Claude CLI 可调（桌面端专属能力），
    /// 共享代码对空 cliPath 的语义是「不走 CLI 后端」，不是缺失配置。
    /// `requestTimeoutSeconds` 恒为 300：移动端未暴露超时设置项，与桌面端默认值
    /// （AppSettings.requestTimeout）对齐；将来若开放设置，改这一处常量即可。
    func makeConfig() -> AIConfig {
        AIConfig(
            kind: provider,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            model: model.trimmingCharacters(in: .whitespaces),
            cliPath: "",
            cliModel: "",
            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
            requestTimeoutSeconds: Self.defaultRequestTimeoutSeconds
        )
    }

    /// 移动端固定请求超时（秒）：桌面端 AppSettings.requestTimeout 的默认值。
    static let defaultRequestTimeoutSeconds = 300
}
