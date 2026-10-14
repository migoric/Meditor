import Foundation
import CoreFoundation

// MARK: - Tool Property Schema

struct ToolPropertySchema: Sendable {
    var type: String
    var description: String
    var enumValues: [String]?
}

// MARK: - Tool Parameter Schema（有序 properties，保证传给 AI 的字段顺序稳定）

struct ToolParameterSchema: Sendable {
    var type: String = "object"
    /// 有序键值对，避免 Dictionary 随机顺序影响模型对参数的理解
    var orderedProperties: [(key: String, schema: ToolPropertySchema)]
    var required: [String]

    init(
        type: String = "object",
        properties: [(key: String, schema: ToolPropertySchema)] = [],
        required: [String] = []
    ) {
        self.type = type
        self.orderedProperties = properties
        self.required = required
    }

    /// 便捷初始化：接受 [String: ToolPropertySchema] 并按 key 字母排序（兼容旧调用）
    init(
        type: String = "object",
        properties: [String: ToolPropertySchema],
        required: [String] = []
    ) {
        self.type = type
        self.orderedProperties = properties.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        self.required = required
    }
}

// MARK: - Agent Tool Spec

struct AgentToolSpec: Sendable {
    var name: String
    var description: String
    var parameters: ToolParameterSchema
    /// 远端 JSON Schema 原文透传（MCP 客户端工具）：非 nil 时 openAIDict/anthropicDict
    /// 的 parameters/input_schema 直接用它，不再由 parameters 重建——嵌套数组/对象等
    /// ToolPropertySchema 表达不了的结构不丢失；parameters 仍保留顶层属性的降级表示，
    /// 供 ClaudeCLI 紧凑签名等展示路径使用。
    var rawSchema: [String: AnySendableValue]?

    init(name: String, description: String, parameters: ToolParameterSchema = ToolParameterSchema(),
         rawSchema: [String: AnySendableValue]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.rawSchema = rawSchema
    }

    /// wire 用的 schema 字典：rawSchema 优先（还原为 Foundation 值），否则由 parameters 生成
    private var wireSchema: [String: Any] {
        if let rawSchema {
            return rawSchema.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
        }
        var props: [String: Any] = [:]
        for (key, schema) in parameters.orderedProperties {
            var p: [String: Any] = ["type": schema.type, "description": schema.description]
            if let enums = schema.enumValues { p["enum"] = enums }
            props[key] = p
        }
        return [
            "type": "object",
            "properties": props,
            "required": parameters.required
        ]
    }

    // Serialize to OpenAI tool format
    var openAIDict: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": wireSchema
            ] as [String: Any]
        ]
    }

    // Anthropic Messages API tool format
    var anthropicDict: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": wireSchema
        ]
    }

    /// 紧凑单行签名：ClaudeCLI system prompt 专用，比 XML 省 ~70% token。
    /// 格式：`name(param: type, optional?: type)  description`
    var compactCLIDescription: String {
        let params = parameters.orderedProperties.map { (key, schema) -> String in
            let req = parameters.required.contains(key)
            let t: String
            switch schema.type {
            case "string":  t = "str"
            case "boolean": t = "bool"
            case "array":   t = "[str]"
            case "integer", "number": t = "num"
            default:        t = schema.type
            }
            return req ? "\(key): \(t)" : "\(key)?: \(t)"
        }.joined(separator: ", ")
        let sig = params.isEmpty ? name : "\(name)(\(params))"
        return "  \(sig)\n    ↳ \(description)"
    }

    // Claude XML-style tool description
    var claudeXMLDescription: String {
        var lines = ["<tool>", "<name>\(name)</name>", "<description>\(description)</description>"]
        if !parameters.orderedProperties.isEmpty {
            lines.append("<parameters>")
            for (key, schema) in parameters.orderedProperties {
                lines.append("  <parameter>")
                lines.append("    <name>\(key)</name>")
                lines.append("    <type>\(schema.type)</type>")
                lines.append("    <description>\(schema.description)</description>")
                if parameters.required.contains(key) {
                    lines.append("    <required>true</required>")
                }
                lines.append("  </parameter>")
            }
            lines.append("</parameters>")
        }
        lines.append("</tool>")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tool Call (from AI response)
// 用强类型 AnySendableValue 替代 [String: Any]，消除 @unchecked Sendable

enum AnySendableValue: Sendable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([AnySendableValue])
    case dict([String: AnySendableValue])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// 还原为 Foundation `Any`（`.null` → NSNull），供 JSONSerialization 回写 wire format。
    /// 唯一的 unwrap 实现——此前同一份 switch 抄了 3 遍（这里 / AgentBackend / AgentRunner）。
    var anyValue: Any {
        switch self {
        case .string(let s):  return s
        case .bool(let b):    return b
        case .int(let i):     return i
        case .double(let d):  return d
        case .null:           return NSNull()
        case .array(let arr): return arr.map { $0.anyValue }
        case .dict(let d):    return d.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
        }
    }
}

struct AgentToolCall: Sendable {
    var id: String
    var name: String
    var arguments: [String: AnySendableValue]
    /// 后端返回的原始参数 JSON 字符串（用于 wire 回放与错误诊断）
    var rawArgumentsJSON: String? = nil
    /// 参数 JSON 解析失败的错误摘要；非 nil 表示 arguments 为空是解析失败所致，
    /// Runner 应跳过执行并直接回灌错误，避免工具误报「缺少参数」误导模型
    var argumentsParseError: String? = nil

    // Parse arguments from JSON string
    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.rawArgumentsJSON = argumentsJSON
        if let data = argumentsJSON.data(using: .utf8) {
            do {
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.arguments = Self.convert(obj)
                } else {
                    self.arguments = [:]
                    self.argumentsParseError = L("agentErr.argsNotObject")
                }
            } catch {
                self.arguments = [:]
                self.argumentsParseError = error.localizedDescription
            }
        } else {
            self.arguments = [:]
            self.argumentsParseError = L("agentErr.argsNotUTF8")
        }
    }

    /// 将强类型 arguments 还原为 [String: Any]（用于序列化回 wire format）
    var argumentsDict: [String: Any] {
        arguments.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
    }

    /// 参数的回放 JSON 文本：优先后端返回的原始串（rawArgumentsJSON），
    /// 缺失时（手工构造 / 持久化解码的 call）由强类型 arguments 重新序列化。
    /// 与 AgentMessage.openAIDict 的回放口径一致；供上下文预算的 token 估算使用
    /// （write_document 全量写入的参数可达数万字符，必须计入预算）。
    var argumentsJSONForReplay: String {
        if let raw = rawArgumentsJSON { return raw }
        let data = (try? JSONSerialization.data(withJSONObject: argumentsDict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    init(id: String, name: String, arguments: [String: AnySendableValue] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.rawArgumentsJSON = nil
        self.argumentsParseError = nil
    }

    /// 递归将 [String: Any] 转换为 [String: AnySendableValue]
    static func convert(_ dict: [String: Any]) -> [String: AnySendableValue] {
        var result: [String: AnySendableValue] = [:]
        for (key, value) in dict {
            result[key] = convertValue(value)
        }
        return result
    }

    private static func convertValue(_ value: Any) -> AnySendableValue {
        switch value {
        case let s as String:  return .string(s)
        case let arr as [Any]: return .array(arr.map { convertValue($0) })
        case let dict as [String: Any]: return .dict(convert(dict))
        // Bool 必须先于 Int 且用 CFBoolean 类型判定：Darwin 上 JSONSerialization 返回
        // NSNumber，`NSNumber(1) as? Bool` / `NSNumber(0) as? Bool` 会成功，导致 JSON 里的
        // 整数 1/0 被误判为 true/false（read_document 的 start_line:1 → bool → intValue
        // 为 nil → 退化成读全文）。用 CFGetTypeID 区分真正的 CFBoolean。
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        default: return .null
        }
    }
}

// MARK: - AgentToolCall Codable

extension AgentToolCall: Codable {
    enum CodingKeys: String, CodingKey { case id, name, arguments }
}

// MARK: - Tool Result

struct AgentToolResult: Sendable {
    var toolCallID: String
    var toolName: String
    var content: String
    var isError: Bool

    init(toolCallID: String, toolName: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}

// MARK: - Agent Tool Protocol

protocol AgentTool: Sendable {
    var spec: AgentToolSpec { get }
    func execute(arguments: [String: AnySendableValue], context: any AgentContextProtocol) async throws -> String
}

extension AgentTool {
    /// 对照 `spec.parameters` 的运行时参数校验：必填缺失、类型不符、enum 越界。
    ///
    /// 背景：工具参数由模型生成，历史上类型不匹配时各工具自行 `?.stringValue`/`?.intValue`
    /// 拿到 nil 后静默走默认分支（如 `read_document` 的 `start_line:1` 若被解析成 bool，
    /// 行区间读取会静默退化成读全文），模型看到「正常返回」便以为参数生效，错误自我复制。
    ///
    /// 契约：返回 nil = 通过；否则返回人读的错误消息，调用方须把它当作工具结果
    /// （`isError: true`）回灌给模型自纠——与 `argumentsParseError`（JSON 解析失败）
    /// 的处理完全同构，不让参数问题升级成整轮 run 失败。
    ///
    /// 宽容规则（避免误伤合法调用）：
    /// - schema 里未声明的参数一律放行（模型有时会补充字段，不该因此失败）；
    /// - `integer` 接受整数值的 double（JSON 里 `2` 可能被解析成 2.0）；
    /// - `.null` 视为缺失（必填才拦；可选参数显式传 null 是合法表达）。
    func validateArguments(_ arguments: [String: AnySendableValue]) -> String? {
        let schema = spec.parameters

        for key in schema.required {
            // nil 与显式 .null 都视为缺失（AnySendableValue 含关联值，无法直接用 == 比较）
            let raw = arguments[key]
            let explicitNull = { () -> Bool in
                if let v = raw, case .null = v { return true }
                return false
            }()
            guard raw != nil, !explicitNull else {
                let desc = schema.orderedProperties.first { $0.key == key }?.schema.description ?? ""
                return "参数 '\(key)' 缺失（该参数为必填）。\(desc.isEmpty ? "" : "说明：\(desc)")请补充后重试。"
            }
        }

        for (key, value) in arguments {
            guard let prop = schema.orderedProperties.first(where: { $0.key == key }) else { continue }
            if case .null = value { continue }
            guard Self.argumentTypeMatches(value, declared: prop.schema.type) else {
                return "参数 '\(key)' 的类型应为 \(prop.schema.type)，实际收到 \(Self.argumentTypeName(of: value))。请按 schema 声明的类型重新生成该参数。"
            }
            if let allowed = prop.schema.enumValues, case .string(let s) = value, !allowed.contains(s) {
                return "参数 '\(key)' 的取值 '\(s)' 不在允许范围内。允许值：\(allowed.joined(separator: "、"))。"
            }
        }
        return nil
    }

    /// JSON Schema 类型 ↔ AnySendableValue case 的匹配。
    private static func argumentTypeMatches(_ value: AnySendableValue, declared: String) -> Bool {
        switch declared {
        case "string":  if case .string = value { return true }
        case "integer":
            if case .int = value { return true }
            if case .double(let d) = value { return d == d.rounded() }
        case "number":  if case .int = value { return true }; if case .double = value { return true }
        case "boolean": if case .bool = value { return true }
        case "array":   if case .array = value { return true }
        case "object":  if case .dict = value { return true }
        default: return true // 未声明/未知类型不拦（schema 演进期向前兼容）
        }
        return false
    }

    private static func argumentTypeName(of value: AnySendableValue) -> String {
        switch value {
        case .string: return "string"
        case .bool:   return "boolean"
        case .int:    return "integer"
        case .double: return "number"
        case .array:  return "array"
        case .dict:   return "object"
        case .null:   return "null"
        }
    }
}

// MARK: - Agent Runner Step（独立为 Model，不再混入 Runner）

enum AgentRunnerStep: Identifiable, Sendable {
    case thinking(label: String, id: UUID = UUID())
    case toolCall(id: String, name: String, args: String)
    /// durationSeconds：工具实际执行耗时（仅 tool.execute 真实执行的分支有值；
    /// 参数解析失败/未找到工具等短路分支为 nil）。默认 nil，旧构造点不受影响。
    case toolCallDone(id: String, name: String, args: String, result: String, isError: Bool,
                      durationSeconds: TimeInterval? = nil)

    /// SwiftUI 用来标识同一视图的 key。
    /// toolCall 和 toolCallDone 共享同一 id，让 SwiftUI 将它们识别为同一个视图，实现原地内容过渡。
    var id: String {
        switch self {
        case .thinking(_, let uid):                 return uid.uuidString
        case .toolCall(let id, _, _):               return "call-\(id)"
        case .toolCallDone(let id, _, _, _, _, _):  return "call-\(id)"   // 意图与 toolCall 相同
        }
    }

    var isDone:  Bool { if case .toolCallDone = self { return true  }; return false }
    var isError: Bool { if case .toolCallDone(_, _, _, _, let e, _) = self { return e }; return false }
}

// MARK: - Errors

enum AgentError: LocalizedError {
    case noDocument
    case noWorkspace
    case toolNotFound(String)
    case maxStepsExceeded
    case parseError(String)
    case executionError(String)

    var errorDescription: String? {
        switch self {
        case .noDocument:            return L("agentErr.noDocument")
        case .noWorkspace:           return L("agentErr.noWorkspace")
        case .toolNotFound(let n):   return L("agentErr.toolNotFound", n)
        case .maxStepsExceeded:      return L("agentErr.maxSteps")
        case .parseError(let m):     return L("agentErr.parse", m)
        case .executionError(let m): return L("agentErr.execution", m)
        }
    }
}
