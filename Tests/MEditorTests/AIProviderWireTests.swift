import XCTest
@testable import MEditor

/// 「provider 字符串 + baseURL → 线格式」的契约测试。
///
/// 背景（真实缺陷）：设置页的预设下拉只写 baseURL 与 model，**从不写 provider**。
/// 于是选「Anthropic Claude」之后 `aiProvider` 仍是 `"openai"`，请求按 OpenAI 线格式
/// 打 `api.anthropic.com/v1/chat/completions` —— 那个端点不存在，首发必然 404；
/// 而「测试连接」按 baseURL 嗅探成 anthropic，所以测试通过、一发就失败。
/// 连带后果：`RestAgentBackend` 里那 3 个 `cache_control` 断点（prompt caching）
/// 只在 anthropic 线格式下发，等于一次都没跑过。
///
/// 这里钉住两件事：
/// 1. `AIPresets.apply` 必须把 kind 一起交出来（视图照抄三个字段）；
/// 2. `AIConfig.resolve` 必须对「老版本设置留下的 openai + anthropic baseURL」
///    自愈成 anthropic —— 那些用户的设置我们没法要求他们手动改回来。
final class AIProviderWireTests: XCTestCase {

    // MARK: - 预设应用

    func test_anthropicPreset_appliesAnthropicKind() {
        let applied = AIPresets.apply(id: "anthropic", currentModel: "gpt-4o")
        XCTAssertEqual(applied?.kind, .anthropic, "选 Anthropic 预设必须把 provider 一起切过去，否则线格式仍是 OpenAI")
        XCTAssertEqual(applied?.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(applied?.model, "claude-opus-4-5", "旧模型不在新预设列表里，回退到该预设首选模型")
    }

    func test_anthropicPreset_keepsModelStillInPreset() {
        let applied = AIPresets.apply(id: "anthropic", currentModel: "claude-sonnet-4-5")
        XCTAssertEqual(applied?.model, "claude-sonnet-4-5", "仍合法的模型名不该被覆盖")
    }

    func test_openAIPreset_appliesOpenAIKind() {
        XCTAssertEqual(AIPresets.apply(id: "openai", currentModel: "")?.kind, .openai)
    }

    func test_unknownPresetID_returnsNil() {
        XCTAssertNil(AIPresets.apply(id: "custom", currentModel: "x"))
    }

    // MARK: - 自愈：老版本留下的 openai + anthropic baseURL

    func test_anthropicBaseURL_withOpenAIProvider_healsToAnthropic() {
        let cfg = Self.resolve(provider: "openai", baseURL: "https://api.anthropic.com/v1")
        XCTAssertEqual(cfg.kind, .anthropic, "baseURL 命中 Anthropic 预设时必须用 anthropic 线格式，否则首发 404")
    }

    func test_anthropicBaseURL_healsAgentBackendToAnthropicWire() throws {
        let cfg = Self.resolve(provider: "openai", baseURL: "https://api.anthropic.com/v1")
        let backend = try XCTUnwrap(AgentBackendFactory.make(config: cfg) as? RestAgentBackend)
        guard case .anthropic = backend.wire else {
            return XCTFail("Agent 后端必须走 anthropic 线格式（否则 cache_control / messages 端点全错）")
        }
    }

    func test_anthropicProvider_isNotDowngraded() {
        let cfg = Self.resolve(provider: "anthropic", baseURL: "https://api.anthropic.com/v1")
        XCTAssertEqual(cfg.kind, .anthropic)
    }

    func test_otherPresetBaseURL_isNotHealed() {
        let cfg = Self.resolve(provider: "openai", baseURL: "https://api.deepseek.com/v1")
        XCTAssertEqual(cfg.kind, .openai, "只有 Anthropic 预设需要纠正；其它 OpenAI 兼容服务不该被动")
    }

    func test_customProxyBaseURL_isNotHealed() {
        // 自建反代 / 中转站：baseURL 不等于任何预设 ⇒ 维持用户显式选择的 provider。
        let cfg = Self.resolve(provider: "openai", baseURL: "https://proxy.example.com/v1")
        XCTAssertEqual(cfg.kind, .openai)
    }

    func test_disabledProvider_staysDisabledEvenWithAnthropicBaseURL() {
        // 「关闭」是显式意图，任何自愈都不该把它变成可用 provider。
        let cfg = Self.resolve(provider: "disabled", baseURL: "https://api.anthropic.com/v1")
        XCTAssertEqual(cfg.kind, .disabled)
    }

    func test_baseURLWhitespace_isTrimmedBeforeMatching() {
        let cfg = Self.resolve(provider: "openai", baseURL: "  https://api.anthropic.com/v1  ")
        XCTAssertEqual(cfg.kind, .anthropic)
        XCTAssertEqual(cfg.baseURL, "https://api.anthropic.com/v1")
    }

    // MARK: - Helper

    private static func resolve(provider: String, baseURL: String) -> AIConfig {
        AIConfig.resolve(
            providerRaw: provider,
            baseURL: baseURL,
            model: "claude-sonnet-4-5",
            cliPath: "",
            cliModel: "",
            apiKey: "sk-test",
            requestTimeoutSeconds: 10
        )
    }
}
