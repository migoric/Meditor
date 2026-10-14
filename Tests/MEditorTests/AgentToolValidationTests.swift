import Foundation
import Testing
@testable import MEditor

/// 工具参数运行时校验（`AgentTool.validateArguments`）的单测。
///
/// 背景：类型不匹配时旧行为是各工具 `?.stringValue`/`?.intValue` 拿到 nil 后静默走
/// 默认分支（如 read_document 的 start_line 被解析成 bool 时行区间读取静默退化为
/// 读全文），模型看到「正常返回」便以为参数生效。校验器把这类问题变成显式的
/// isError 工具结果回灌给模型自纠（同 argumentsParseError 的处理）。
///
/// 本组测试同时是「接线」验证的另一半：Runner/MCPServer 三个调用点的集成验证见
/// AgentRunnerValidationIntegrationTests（删调用点 → 那边红；删校验实现 → 这边红）。

// MARK: - 测试专用工具

/// 记录 execute 是否被调用——校验失败时绝不该被调用。
private final class ValidatingSpyTool: AgentTool, @unchecked Sendable {
    let spec: AgentToolSpec
    private(set) var wasExecuted = false
    private(set) var lastArguments: [String: AnySendableValue] = [:]

    init(spec: AgentToolSpec) {
        self.spec = spec
    }

    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String {
        wasExecuted = true
        lastArguments = arguments
        return "executed"
    }
}

private func makeSpec(
    name: String = "probe_tool",
    properties: [String: ToolPropertySchema],
    required: [String] = []
) -> AgentToolSpec {
    AgentToolSpec(name: name, description: "probe", parameters: ToolParameterSchema(properties: properties, required: required))
}

private func stringProp(_ desc: String = "a string") -> ToolPropertySchema {
    ToolPropertySchema(type: "string", description: desc)
}

private func intProp(_ desc: String = "an integer") -> ToolPropertySchema {
    ToolPropertySchema(type: "integer", description: desc)
}

// MARK: - required

struct AgentToolValidationTests {

    @Test(arguments: [
        ([String: AnySendableValue](), "filename"),          // 完全缺失
        (["filename": .string("")], "filename"),              // 空串是合法 string（放行，由工具业务层判）
    ])
    func requiredEmptyValueHandling(args: [String: AnySendableValue], key: String) throws {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["filename": stringProp()], required: [key]))
        // 空串：string 类型匹配、非 null ⇒ 校验放行（是否为空由工具自己判）
        // 完全缺失：nil ⇒ 拦
        if key == "filename", args["filename"] == nil {
            #expect(tool.validateArguments(args) != nil)
        } else {
            #expect(tool.validateArguments(args) == nil)
        }
    }

    @Test
    func requiredMissing_returnsErrorWithDescription() {
        let tool = ValidatingSpyTool(spec: makeSpec(
            properties: ["filename": stringProp("要读的文件名")],
            required: ["filename"]
        ))
        let violation = tool.validateArguments(["other": .string("x")])
        #expect(violation != nil)
        #expect(violation?.contains("filename") == true)
        #expect(violation?.contains("必填") == true)
        #expect(violation?.contains("要读的文件名") == true, "错误消息应带参数说明，便于模型自纠")
        #expect(tool.wasExecuted == false)
    }

    @Test
    func requiredExplicitNull_isTreatedAsMissing() {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["filename": stringProp()], required: ["filename"]))
        #expect(tool.validateArguments(["filename": .null]) != nil)
    }

    // MARK: - 类型匹配

    @Test
    func typeMismatch_returnsErrorNamingBothTypes() {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["filename": stringProp()]))
        let violation = tool.validateArguments(["filename": .int(42)])
        #expect(violation != nil)
        #expect(violation?.contains("string") == true)
        #expect(violation?.contains("integer") == true)
        #expect(tool.wasExecuted == false)
    }

    /// 每个 case 是 (送进工具的值, spec 里声明的类型)。
    /// ⚠️ 必须显式写 `AnySendableValue.`：数组字面量里的 `.double(2.0)` 在
    /// swift-testing 的 `@Test(arguments:)` 泛型推断下没有上下文基准
    /// （`cannot infer contextual base in reference to member 'double'`）。
    @Test(arguments: [
        (AnySendableValue.string("ok"), "string"),
        (AnySendableValue.int(7), "integer"),
        (AnySendableValue.double(2.0), "integer"),   // JSON 的 2 可能解析成 2.0：整数值 double 放行
        (AnySendableValue.double(2.5), "integer"),   // 小数：拦
        (AnySendableValue.int(3), "number"),
        (AnySendableValue.double(1.5), "number"),
        (AnySendableValue.bool(true), "boolean"),
        (AnySendableValue.array([.int(1)]), "array"),
        (AnySendableValue.dict(["k": .int(1)]), "object"),
        (AnySendableValue.string("x"), "unknown_future_type"), // 未声明类型不拦（schema 演进兼容）
    ])
    func typeMatchingMatrix(value: AnySendableValue, declared: String) {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["p": ToolPropertySchema(type: declared, description: "p")]))
        let violation = tool.validateArguments(["p": value])
        let shouldPass: Bool
        switch (value, declared) {
        case (.double(2.0), "integer"): shouldPass = true   // 整数值 double
        case (.double(2.5), "integer"): shouldPass = false  // 小数 double
        case (_, "unknown_future_type"): shouldPass = true
        default:
            shouldPass = violation == nil
        }
        #expect((violation == nil) == shouldPass, "\(declared) vs \(value) 的判定不符合预期")
    }

    @Test
    func unknownProperty_passesThrough() {
        // 模型有时会补充 schema 外的字段：宽容放行，不因此失败
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["filename": stringProp()]))
        #expect(tool.validateArguments(["filename": .string("a.md"), "extra": .int(1)]) == nil)
    }

    @Test
    func optionalExplicitNull_passes() {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: ["filename": stringProp(), "end_line": intProp()]))
        #expect(tool.validateArguments(["filename": .string("a.md"), "end_line": .null]) == nil)
    }

    // MARK: - enum

    @Test
    func enumOutOfRange_returnsErrorListingAllowedValues() {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: [
            "style": ToolPropertySchema(type: "string", description: "style", enumValues: ["doc", "craft", "tufte"])
        ]))
        let violation = tool.validateArguments(["style": .string("cyberpunk")])
        #expect(violation != nil)
        #expect(violation?.contains("cyberpunk") == true)
        #expect(violation?.contains("doc") == true)
        #expect(violation?.contains("craft") == true)
    }

    @Test
    func enumInRange_passes() {
        let tool = ValidatingSpyTool(spec: makeSpec(properties: [
            "style": ToolPropertySchema(type: "string", description: "style", enumValues: ["doc", "craft"])
        ]))
        #expect(tool.validateArguments(["style": .string("craft")]) == nil)
    }

    // MARK: - 合法参数照常执行

    /// `MockAgentContext` 是 `@MainActor` 隔离的，本测试要在主 actor 上跑。
    /// 仓内其他用它的测试是 XCTestCase（本身在主 actor），这里是 swift-testing，
    /// 需要显式标注。
    @Test
    @MainActor
    func validArguments_passAndExecute() async throws {
        let tool = ValidatingSpyTool(spec: makeSpec(
            properties: ["filename": stringProp(), "start_line": intProp()],
            required: ["filename"]
        ))
        let args: [String: AnySendableValue] = ["filename": .string("a.md"), "start_line": .int(3)]
        #expect(tool.validateArguments(args) == nil)
        let context = MockAgentContext()
        let output = try await tool.execute(arguments: args, context: context)
        #expect(output == "executed")
        #expect(tool.wasExecuted)
    }
}
