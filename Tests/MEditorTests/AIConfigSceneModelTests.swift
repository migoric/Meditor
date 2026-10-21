import XCTest
@testable import MEditor

/// `AIConfig.resolveModel` 的契约测试。
///
/// 这个纯函数是「分场景模型」的唯一回退规则来源：桌面端 `AIConfig.current` 读
/// `AppSettings`，iOS 壳 `MobileAISettings.makeConfig(scene:)` 读 UserDefaults /
/// Keychain。iOS 侧没有测试 target，所以规则本身必须在这里被钉住——
/// 否则两端谁改错都只能靠肉眼比对。
final class AIConfigSceneModelTests: XCTestCase {

    // MARK: - chat / beautify：恒用主模型

    func test_chatScene_ignoresAgentAndInline() {
        let model = AIConfig.resolveModel(
            scene: .chat, fallback: "base", agent: "agent-x", inline: "inline-x"
        )
        XCTAssertEqual(model, "base")
    }

    func test_beautifyScene_ignoresAgentAndInline() {
        let model = AIConfig.resolveModel(
            scene: .beautify, fallback: "base", agent: "agent-x", inline: "inline-x"
        )
        XCTAssertEqual(model, "base")
    }

    // MARK: - agent：优先专属模型，空白视为未设置

    func test_agentScene_prefersAgentModel() {
        let model = AIConfig.resolveModel(
            scene: .agent, fallback: "base", agent: "agent-x", inline: ""
        )
        XCTAssertEqual(model, "agent-x")
    }

    func test_agentScene_blankAgentModel_fallsBackToBase() {
        let model = AIConfig.resolveModel(
            scene: .agent, fallback: "base", agent: "   \n ", inline: ""
        )
        XCTAssertEqual(model, "base", "只有空白的 agent 模型必须回退，不能原样当模型名发出去")
    }

    func test_agentScene_emptyAgentModel_fallsBackToBase() {
        let model = AIConfig.resolveModel(
            scene: .agent, fallback: "base", agent: "", inline: ""
        )
        XCTAssertEqual(model, "base")
    }

    // MARK: - inline：与 agent 同规则

    func test_inlineScene_prefersInlineModel() {
        let model = AIConfig.resolveModel(
            scene: .inline, fallback: "base", agent: "agent-x", inline: "inline-x"
        )
        XCTAssertEqual(model, "inline-x")
    }

    /// iOS 壳恒传 `inline: ""`（移动端没有内联编辑入口）——这条把那个约定钉住：
    /// 一旦有人顺手给 iOS 传了非法值，这里先红。
    func test_inlineScene_emptyInlineModel_fallsBackToBase() {
        let model = AIConfig.resolveModel(
            scene: .inline, fallback: "base", agent: "agent-x", inline: ""
        )
        XCTAssertEqual(model, "base")
    }

    // MARK: - 两端都得去掉首尾空白

    func test_paddedInputs_areTrimmed() {
        let model = AIConfig.resolveModel(
            scene: .agent, fallback: " fallback ", agent: "  agent-x  ", inline: ""
        )
        XCTAssertEqual(model, "agent-x")
    }

    /// 空白主模型 + 空白专属模型：返回空串（上层 `isConfigured` 会判未配置）。
    /// 不能在这里编一个默认模型——那会让「没填模型」变成「悄悄用某个模型」。
    func test_allEmpty_returnsEmpty() {
        let model = AIConfig.resolveModel(
            scene: .agent, fallback: "  ", agent: "  ", inline: ""
        )
        XCTAssertEqual(model, "")
    }
}
