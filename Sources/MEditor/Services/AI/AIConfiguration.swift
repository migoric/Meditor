import Foundation

// MARK: - Provider kind

enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case openai      // OpenAI-compatible /chat/completions（OpenAI, Ollama, OpenRouter, 各类代理…）
    case anthropic   // Anthropic Messages API 直连（api.anthropic.com 或兼容实现）
    case claudeCLI   // 本地 claude CLI 子进程（复用 Claude Code auth，降级方案）

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .disabled:   return "ai.provider.disabled"
        case .openai:     return "ai.provider.openai"
        case .anthropic:  return "ai.provider.anthropic"
        case .claudeCLI:  return "ai.provider.claudeCLI"
        }
    }
}

// MARK: - Provider presets

/// Common OpenAI-compatible vendors with their base URL and a handful of
/// commonly-used model names (best-effort; "Refresh" fetches the live list).
struct AIProviderPreset: Identifiable {
    let id: String
    let name: String
    let kind: AIProviderKind  // 选中此 Preset 时自动设置 provider kind
    let baseURL: String
    let models: [String]

    init(id: String, name: String, kind: AIProviderKind = .openai, baseURL: String, models: [String]) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.models = models
    }
}

enum AIPresets {
    static var all: [AIProviderPreset] { [
        .init(id: "anthropic", name: "Anthropic Claude", kind: .anthropic,
              baseURL: "https://api.anthropic.com/v1",
              models: ["claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-3-5"]),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
              models: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o3", "o3-mini", "o1"]),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
              models: ["deepseek-v4-flash", "deepseek-v4-pro"]),
        .init(id: "moonshot", name: "Moonshot · Kimi", baseURL: "https://api.moonshot.cn/v1",
              models: ["kimi-k2-0711-preview", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]),
        .init(id: "zhipu", name: "智谱 · GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
              models: ["glm-4.6", "glm-4-plus", "glm-4-air", "glm-4-flash"]),
        .init(id: "qwen", name: "通义千问 · DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              models: ["qwen-max", "qwen-plus", "qwen-turbo", "qwen2.5-72b-instruct"]),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
              models: ["openai/gpt-4o", "anthropic/claude-3.7-sonnet", "google/gemini-2.0-flash-001", "deepseek/deepseek-v4-flash"]),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
              models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"]),
        .init(id: "ollama", name: L("ai.preset.ollama"), baseURL: "http://localhost:11434/v1",
              models: ["llama3.1", "qwen2.5", "mistral", "gemma2", "phi3"])
    ] }

    /// Preset whose base URL matches the given one, if any.
    static func match(_ baseURL: String) -> AIProviderPreset? {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        return all.first { $0.baseURL == b }
    }

    /// 选中某个预设时，设置里**应当写入的三个字段**。
    ///
    /// 为什么要有这个函数：`AIProviderPreset.kind` 的注释写着「选中此 Preset 时自动
    /// 设置 provider kind」，但设置页此前只写了 baseURL 和 model —— 于是选
    /// 「Anthropic Claude」之后 provider 仍是 `.openai`，请求按 OpenAI 线格式打
    /// `api.anthropic.com/v1/chat/completions`（不存在）⇒ 发送必然 404，而
    /// 「测试连接」因为按 baseURL 嗅探反而通过。把「写哪些字段」抽成纯函数，
    /// 才能被单测钉住（视图里内联的赋值没法测）。
    ///
    /// - Parameter currentModel: 当前模型名；命中预设列表就保留，否则回退首选。
    static func apply(id: String, currentModel: String) -> AIProviderPresetApplied? {
        guard let p = all.first(where: { $0.id == id }) else { return nil }
        let keep = p.models.contains(currentModel)
        return AIProviderPresetApplied(
            kind: p.kind,
            baseURL: p.baseURL,
            model: keep ? currentModel : (p.models.first ?? currentModel)
        )
    }
}

/// `AIPresets.apply` 的结果。用 struct 而不是三元组：项目 SwiftLint 的
/// `large_tuple` 是 error 级（≥3 成员即违规），命名元组也一样。
struct AIProviderPresetApplied: Equatable {
    let kind: AIProviderKind
    let baseURL: String
    let model: String
}

// MARK: - Message
struct AIMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

// MARK: - Errors

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case server(Int, String)
    case cliNotFound(String)
    case cliFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return L("ai.error.notConfigured")
        case .badURL:               return L("ai.error.badURL")
        case .server(let c, let m): return L("ai.error.server", c, m)
        case .cliNotFound(let p):   return L("ai.error.cliNotFound", p)
        case .cliFailed(let m):     return L("ai.error.cliFailed", m)
        case .network(let m):       return L("ai.error.network", m)
        }
    }
}

// MARK: - Config

/// 使用 AI 的场景，决定选哪个模型。
enum AIScene {
    case chat       // AI 助手面板（流式聊天）
    case agent      // AgentRunner（工具调用）
    case inline     // 内联编辑（改写/精简/翻译）
    case beautify   // HTML 美化
}

struct AIConfig: Sendable {
    var kind: AIProviderKind
    var baseURL: String
    var model: String
    var cliPath: String
    var cliModel: String    // Claude CLI --model 参数（空则用 CLI 默认）
    var apiKey: String      // resolved from Keychain
    /// 单次 HTTP 请求超时（秒）。推理模型可能需要较长的思考时间。默认 300s。
    var requestTimeoutSeconds: TimeInterval
    /// CLI 请求级超时（秒）。超时后终止 claude 子进程并报错。默认 120s。
    var cliTimeoutSeconds: TimeInterval = 120

    /// 按场景解析模型名：场景专属模型为空（或纯空白）时回退到通用模型。
    ///
    /// 抽成 `nonisolated static` 纯函数是为了让两个平台壳共用同一条回退规则——
    /// 桌面端读 `AppSettings`，iOS 读 `MobileAISettings`，但"哪个字段优先、
    /// 空串算什么"只能有一份定义。iOS 侧没有测试 target，这层抽出来后才能被
    /// `Tests/MEditorTests` 直接覆盖（见 `AIConfigSceneModelTests`）。
    ///
    /// ⚠️ 去空白必须连换行一起去掉：粘贴一个尾部带换行的模型名时，
    /// 只去空格会把 `"\n"` 当成合法模型名发出去，API 侧回 Model not found——
    /// 而用户看到的是一个空字段。`whitespacesAndNewlines` 是 `whitespaces` 的超集，
    /// 对正常输入无行为差异。
    nonisolated static func resolveModel(
        scene: AIScene,
        fallback: String,
        agent: String,
        inline: String
    ) -> String {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch scene {
        case .agent:
            let scoped = trimmed(agent)
            return scoped.isEmpty ? trimmed(fallback) : scoped
        case .inline:
            let scoped = trimmed(inline)
            return scoped.isEmpty ? trimmed(fallback) : scoped
        case .chat, .beautify:
            return trimmed(fallback)
        }
    }

    /// 由设置里的原始字段解析出最终配置（纯函数，唯一口径）。
    ///
    /// 抽出来的理由与 `resolveModel` 相同：视图里内联的赋值没法测，而「provider
    /// 字符串 + baseURL → 用哪种线格式」这条规则一旦散落就会各自漂移。
    /// iOS 的 `MobileAISettings` 不经过这里——它的 provider 是 `AIProviderKind`
    /// 枚举而非字符串，没有"设置里存了半个状态"的入口（见该方法注释）。
    ///
    /// ## 自愈：`openai` + Anthropic 预设 baseURL
    ///
    /// 历史版本选「Anthropic Claude」预设时只写了 baseURL 与 model，没写 provider
    /// （见 `AIPresets.apply` 的注释）。这些用户的设置里就是 `openai` +
    /// `https://api.anthropic.com/v1` 这个组合，按 OpenAI 线格式打过去必然 404。
    /// 我们没法要求他们手动改回来，所以在这里纠正一次：**baseURL 精确命中
    /// 某个预设、且该预设的 kind 是 anthropic** 时改判 anthropic。
    ///
    /// 保守边界（都有测试钉住）：
    /// - 只认**精确**命中预设的 baseURL。自建反代 / 中转站不改判，否则会把
    ///   兼容层当官方端点用。
    /// - `.disabled` 是显式意图，任何自愈都不越过它。
    /// - 只纠正 openai → anthropic 这一个方向：反向没有对应的历史数据，
    ///   而且把 anthropic 降成 openai 只会让本来能用的配置变坏。
    nonisolated static func resolve(
        providerRaw: String,
        baseURL: String,
        model: String,
        cliPath: String,
        cliModel: String,
        apiKey: String,
        requestTimeoutSeconds: TimeInterval
    ) -> AIConfig {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        var kind = AIProviderKind(rawValue: providerRaw) ?? .disabled
        if kind == .openai, AIPresets.match(trimmedBase)?.kind == .anthropic {
            kind = .anthropic
        }
        return AIConfig(
            kind:                  kind,
            baseURL:               trimmedBase,
            model:                 model,
            cliPath:               cliPath.trimmingCharacters(in: .whitespaces),
            cliModel:              cliModel.trimmingCharacters(in: .whitespaces),
            apiKey:                apiKey,
            requestTimeoutSeconds: requestTimeoutSeconds
        )
    }
    @MainActor
    static func current(_ s: AppSettings, scene: AIScene = .chat) -> AIConfig {
        // 根据场景决定模型
        let model = resolveModel(
            scene: scene,
            fallback: s.aiModel,
            agent: s.aiAgentModel,
            inline: s.aiInlineModel
        )
        return resolve(
            providerRaw:           s.aiProvider,
            baseURL:               s.aiBaseURL,
            model:                 model,
            cliPath:               s.aiCLIPath,
            cliModel:              s.aiCLIModel,
            apiKey:                AIAPIKeyStore.load() ?? "",
            requestTimeoutSeconds: s.aiRequestTimeout
        )
    }

    var isConfigured: Bool {
        switch kind {
        case .disabled:   return false
        case .openai:     return !baseURL.isEmpty && !model.isEmpty
        case .anthropic:  return !apiKey.isEmpty && !model.isEmpty
        case .claudeCLI:  return !cliPath.isEmpty
        }
    }
}
