import Foundation
import Observation

/// AI 对话面板的状态：消息列表 + AgentRunner 流式接入。
/// 会话存储复用桌面端 AIConversation（多会话、磁盘持久化、滑动窗口截断），
/// 本类只负责移动端的运行编排（runner 生命周期、文档上下文、技能注入）。
/// 工具步骤快照不入盘（macOS 同样只保留在内存），App 生命周期内按会话保留可回放。
@MainActor
@Observable
final class ChatModel {

    /// 视图层消息：在 AIChatMessage 之上附带本次回复的工具步骤快照（仅内存）。
    struct ChatMessage: Identifiable {
        let id: UUID
        let role: AIChatMessage.Role
        var text: String
        /// 本次回复的工具步骤快照（运行中为空；运行中的实时步骤由 runner.steps 展示）。
        var steps: [AgentRunnerStep]
    }

    /// 持久化引擎（桌面端同款）：多会话 + 落盘 + 截断，构造注入便于测试。
    let convo: AIConversation

    var input: String = ""
    var isResponding = false
    /// 待替换的原文：AI 优化选中文本后存储，AI 回复完成后可用 replacePendingText 替换。
    private(set) var pendingOriginalText: String? = nil

    /// 运行中的 Runner（只读暴露给视图，驱动工具步骤面板）。
    private(set) var runner: AgentRunner?
    /// 写文件的确认闸门：视图层据此渲染确认条。
    /// 由 ChatModel 持有并注入 `MobileAgentContext`，保证两边看到同一份挂起状态。
    let writeGate: WriteConfirmationGate
    /// 工具步骤快照：sessionID → messageID → steps。只活在本进程内，不随会话入盘。
    private var stepSnapshots: [UUID: [UUID: [AgentRunnerStep]]] = [:]
    private let store: DocumentStore
    private let context: MobileAgentContext
    private let settings: MobileAISettings
    private let skillStore: MobileSkillStore
    /// Backend 工厂，透传给每次新建的 AgentRunner；测试时可注入 mock。
    private let backendFactory: @Sendable (AIConfig) -> any AgentBackend

    init(
        store: DocumentStore,
        settings: MobileAISettings,
        // 默认 nil → init 内取 .shared / 新建（默认参数表达式在非隔离上下文求值，
        // 直接写 = .shared 会在 Swift 6 模式报错）。
        skillStore: MobileSkillStore? = nil,
        convo: AIConversation? = nil,
        backendFactory: @escaping @Sendable (AIConfig) -> any AgentBackend = AgentBackendFactory.make
    ) {
        self.store          = store
        // 先建闸门再建 context：context 必须拿到同一个实例，否则视图看到的是
        // 一份挂起状态、工具等待的是另一份，确认条点下去也不会有反应。
        let gate = WriteConfirmationGate()
        self.writeGate      = gate
        self.context        = MobileAgentContext(store: store, gate: gate)
        self.settings       = settings
        self.skillStore     = skillStore ?? .shared
        self.convo          = convo ?? AIConversation()
        self.backendFactory = backendFactory
    }

    /// 当前会话消息（持久化文本 + 内存中的步骤快照合并视图）。
    var messages: [ChatMessage] {
        let snapshots = stepSnapshots[convo.activeID] ?? [:]
        return convo.messages.map {
            ChatMessage(id: $0.id, role: $0.role, text: $0.text, steps: snapshots[$0.id] ?? [])
        }
    }

    private static let systemPrompt = """
        你是 MEditor 移动端的 AI 助手。用户当前打开了一个 Markdown/HTML 文档，\
        你可以使用工具读取和修改当前文档（read_document / patch_document / write_document），\
        也可以操作 App 沙盒工作区内的文件（list_files / read_file / write_file / search_workspace 等）。\
        回答使用与用户相同的语言，简洁直接。
        """

    /// 系统 prompt = 基础说明 + 已启用技能注入（每次发送时现取，开关即时生效）。
    private func systemPromptWithSkills() -> String {
        let section = skillStore.promptSection
        var prompt = section.isEmpty ? Self.systemPrompt : Self.systemPrompt + "\n\n" + section
        // 用户在设置里填的自定义系统提示词：始终注入（最高优先级的个人偏好）
        let custom = settings.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            prompt += "\n\n# 用户自定义指令（务必遵守）\n\n" + custom
        }
        return prompt
    }

    /// 发送当前输入框内容。
    func send() {
        send(text: input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 发送指定内容（技能快捷指令 chip 用）。
    func sendQuick(_ text: String) {
        send(text: text)
    }

    private func send(text: String) {
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        store.beginAIRun()
        // 「本次全部允许」是 run 级作用域：新 run 一开始就复位，并拒掉可能残留的挂起。
        writeGate.resetRun()

        // 对话过长时先做滑动窗口截断（复用 AIConversation 的实现，与 macOS 同源）。
        if convo.truncateIfOverLimit() {
            convo.messages.append(AIChatMessage(role: .assistant, text: "⚠️ 对话历史过长，已自动保留最近 10 轮对话。"))
        }

        convo.messages.append(AIChatMessage(role: .user, text: text))
        convo.messages.append(AIChatMessage(role: .assistant, text: ""))
        isResponding = true

        // agentHistory（= 上轮 runner.finalMessages）首条已含 system 消息。
        // 对齐 macOS AIAssistant 的策略：替换首条而非再前置一条——
        // 保证 system prompt 有且仅有一条，且始终是当前最新（技能开关即时生效）。
        var msgs = convo.agentHistory
        let systemMessage = AgentMessage(role: .system, content: systemPromptWithSkills())
        if msgs.first?.role == .system {
            msgs[0] = systemMessage
        } else {
            msgs.insert(systemMessage, at: 0)
        }
        msgs.append(AgentMessage(role: .user, content: text))

        // 步数预算与模型都按「agent 场景」取：iOS 的对话面板本质就是带工具的 agent，
        // 与桌面端 AIAssistant 同类。此前两处都吃默认值（30 步 / 通用模型），
        // 用户换了聊天模型会把 agent 一起换掉。
        let r = AgentRunner(maxSteps: settings.agentMaxSteps, backendFactory: backendFactory)
        runner = r
        // 会话切换/删除会先 cancel()，但 runner 的收尾（onComplete）与在途的
        // chunk 仍可能异步落到回调里——用发送时的会话 id 把关，跨会话一律丢弃，
        // 避免把旧会话的文本/历史写进新会话。
        let sessionID = convo.activeID
        r.onChunk = { [weak self] fullText in
            self?.updateLastAssistant(fullText, in: sessionID)
        }
        // 双 weak 捕获：避免 闭包 → runner → 闭包 的 retain cycle
        // （对齐 macOS AIAssistant.swift 的 onComplete 写法）。
        r.onComplete = { [weak self, weak r] in
            guard let self, let r else { return }
            self.finish(r, sessionID: sessionID)
        }
        r.run(
            messages: msgs,
            tools: BuiltinAgentTools.all,
            config: settings.makeConfig(scene: .agent),
            context: context
        )
    }

    func cancel() {
        // 先拒掉挂起的写入确认：否则那条 continuation 永不恢复，run 会卡在写工具里
        // 等一个已经没人能点的确认条。
        writeGate.cancelPending()
        runner?.cancel()
        runner = nil
        isResponding = false
        convo.persist()
    }

    /// 把 AI 回复插入当前文档末尾（消息操作）；无打开文档时返回 false。
    @discardableResult
    func insertIntoDocument(_ text: String) -> Bool {
        guard store.hasDocument else { return false }
        context.insertIntoDocument(text)
        return true
    }

    /// 撤销上一轮 AI 对文档的改动。
    func undoAIChanges() {
        store.undoAIChanges()
    }

    /// 记录待替换原文（选中文本优化场景）。
    func setPendingReplace(original: String) {
        pendingOriginalText = original
    }

    /// 用 AI 回复替换原文（查找第一个匹配替换）。
    func replacePendingText(with aiText: String) {
        guard let original = pendingOriginalText, !original.isEmpty, !aiText.isEmpty else { return }
        pendingOriginalText = nil
        if let range = store.text.range(of: original) {
            var newText = store.text
            newText.replaceSubrange(range, with: aiText)
            store.applyManualEdit(newText)
        }
    }

    /// 重试最后一次回复：移除最后一条 AI 消息（含错误），重新发送上一条用户消息。
    func retryLast() {
        guard !isResponding, convo.messages.count >= 2 else { return }
        // 移除最后一条 AI 回复（含错误文本）
        convo.messages.removeLast()
        // 上一条应该是用户消息，用它重发
        guard let lastUser = convo.messages.last, lastUser.role == .user else { return }
        send(text: lastUser.text)
    }

    private func updateLastAssistant(_ text: String, in sessionID: UUID) {
        guard convo.activeID == sessionID, !convo.messages.isEmpty else { return }
        convo.messages[convo.messages.count - 1].text = text
    }

    // MARK: - 多会话（转发给 AIConversation，先停掉本进程内的 runner）

    /// 历史会话列表，最近更新的在前。
    var sessions: [AISession] { convo.history }

    var activeSessionID: UUID { convo.activeID }

    func newSession() {
        cancel()
        convo.newSession()
    }

    func activateSession(_ id: UUID) {
        guard id != convo.activeID else { return }
        cancel()
        convo.activate(id)
    }

    func deleteSession(_ id: UUID) {
        if id == convo.activeID { cancel() }
        convo.delete(id)
    }

    private func finish(_ r: AgentRunner, sessionID: UUID) {        // 会话已切换/删除时（cancel 后 runner 收尾仍异步触发本回调）：
        // runner/isResponding 已被 cancel() 复位，直接丢弃这次收尾，
        // 避免把旧会话的 agentHistory / 错误文本写进新会话。
        guard convo.activeID == sessionID else { return }
        convo.agentHistory = r.finalMessages
        // 工具步骤快照进内存映射（滤掉 thinking 占位），run 结束后仍可回放；
        // 切换会话再切回（本进程内）快照仍在，重启后随进程消失（macOS 同样不落盘）。
        if let last = convo.messages.last {
            let steps = r.steps.filter { step in
                if case .thinking = step { return false }
                return true
            }
            stepSnapshots[sessionID, default: [:]][last.id] = steps
        }
        if let error = r.error, convo.messages.last?.text.isEmpty == true {
            updateLastAssistant("[!] \(error)", in: sessionID)
        } else if let error = r.error {
            updateLastAssistant((convo.messages.last?.text ?? "") + "\n\n[!] \(error)", in: sessionID)
        }
        runner = nil
        isResponding = false
        convo.persist()
    }

#if DEBUG
    /// 演示会话：仅 DEBUG 用（launch argument `-debugSeedChat YES` 触发），
    /// 供模拟器截图/设计走查，不依赖真实 API。
    func seedDemoConversation() {
        convo.messages.removeAll()  // 幂等：重复启动不叠加
        convo.messages.append(AIChatMessage(role: .user, text: "帮我把文档里「产品演进」这一节改得更简洁"))
        convo.messages.append(AIChatMessage(role: .assistant, text: """
            已通读文档并完成了精简，主要改动：

            - **删繁就简**：三个重复论述的段落合并为一段
            - 结构重排：按「现状 → 方向 → 路径」组织
            - 保留了所有关键数据点和版本对比表格

            其中精简幅度最大的一段：

            > 原文 87 字压缩到 31 字，信息无损。

            如需进一步压缩到一页以内，可以继续。
            """))
        if let last = convo.messages.last {
            stepSnapshots[convo.activeID, default: [:]][last.id] = [
                .toolCallDone(id: "d1", name: "read_document", args: "{}", result: "ok", isError: false),
                .toolCallDone(id: "d2", name: "search_workspace", args: "{\"query\":\"产品演进\"}", result: "ok", isError: false),
                .toolCallDone(id: "d3", name: "patch_document", args: "{\"find\":\"...\"}", result: "ok", isError: false),
                .toolCallDone(id: "d4", name: "patch_document", args: "{\"find\":\"...\"}", result: "ok", isError: false),
            ]
        }
        convo.messages.append(AIChatMessage(role: .user, text: "好的，再帮我看看还有没有语病"))
        convo.messages.append(AIChatMessage(role: .assistant, text: """
            检查完了，有两处小问题：

            1. 第二段「的的」重复，已修正
            2. 结尾「进行一个推进」建议改为「推进」

            其他部分读起来都很顺。
            """))
        convo.persist()
    }
#endif
}
