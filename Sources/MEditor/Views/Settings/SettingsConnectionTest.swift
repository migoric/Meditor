import SwiftUI

// MARK: - Connection test / model refresh

extension SettingsView {
    @MainActor
    func runConnectionTest() async {
        connectionTesting = true
        connectionTestResult = nil
        // 与聊天/Agent 走**同一个** resolver：测试通过必须意味着真发消息也通过。
        // （此前这里按 baseURL 是否含 "anthropic" 嗅探线格式，而生产路径用 provider
        // 字段 ⇒ 选了 Anthropic 预设时测试走 anthropic、发送走 openai，测试绿、一发 404。）
        let config = AIConfig.resolve(
            providerRaw: settings.aiProvider,
            baseURL: settings.aiBaseURL,
            model: settings.aiModel,
            cliPath: "",
            cliModel: "",
            apiKey: AIAPIKeyStore.load() ?? "",
            requestTimeoutSeconds: 10
        )

        do {
            let resultModel = try await performConnectionTest(config: config)
            connectionTestOK = true
            connectionTestResult = L("settings.test.okModel", resultModel)
        } catch {
            connectionTestOK = false
            connectionTestResult = L("settings.test.failed", error.localizedDescription)
        }
        connectionTesting = false
    }

    private func performConnectionTest(config: AIConfig) async throws -> String {
        guard !config.baseURL.isEmpty else { throw URLError(.badURL) }
        // 连接测试与聊天/Agent 共用 RestAgentBackend 的请求构造（wire format 唯一来源）；
        // 仅收紧超时（10s）与负载（单条 "hi"，非流式）。
        var config = config
        config.requestTimeoutSeconds = 10
        // 模型留空时按线格式给一个该格式认得的默认值：Anthropic 端点不认识
        // gpt-4o-mini，会回 Model not found —— 那看起来像 key 错了。
        var model = config.model.trimmingCharacters(in: .whitespaces)
        if model.isEmpty {
            model = config.kind == .anthropic ? "claude-sonnet-4-5" : "gpt-4o-mini"
            config.model = model
        }
        let backend = AgentBackendFactory.make(config: config)
        _ = try await backend.complete(
            messages: [AgentMessage(role: .user, content: "hi")],
            tools: []
        )
        return model
    }

    /// Claude CLI 连接测试：真实发一条 "hi"（30s 超时），错误文案复用 AIError 分类。
    /// 与首启引导里的就绪校验共用 AIClient.testClaudeCLI。
    @MainActor
    func runCLITest() async {
        connectionTesting = true
        connectionTestResult = nil
        if let error = await AIClient.testClaudeCLI(cliPath: settings.aiCLIPath, cliModel: settings.aiCLIModel) {
            connectionTestOK = false
            connectionTestResult = L("settings.test.failed", error)
        } else {
            connectionTestOK = true
            connectionTestResult = L("settings.test.okCLI")
        }
        connectionTesting = false
    }

    func refreshModels() {
        aiLoadingModels = true
        let base = settings.aiBaseURL
        let key = AIAPIKeyStore.load() ?? ""
        Task {
            let models = await AIClient.fetchModels(baseURL: base, apiKey: key)
            await MainActor.run {
                aiModels = models
                aiLoadingModels = false
            }
        }
    }
}
