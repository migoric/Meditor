import Foundation
import SwiftUI

// MARK: - SlashAICommandExecutor

/// 斜杠 AI 命令执行器：解析目标范围 → 构建 prompt → 按命令输出类型分发。
///
/// - `diffWriteBack`：复用行内编辑的 diff 流式链路（beginStreaming → AgentRunner →
///   段落 diff 确认 → applyAIWriteBack 可撤销写回）；
/// - `chatBubble`：复用 /ask 的「预填聊天面板」链路（pendingSelectionPrompt）。
///
/// 由 EditorView 的 onSlashAIAction 回调触发；命令元数据全部来自
/// `AISlashCommandRegistry`，这里只做执行编排。
@MainActor
enum SlashAICommandExecutor {

    /// document 级命令（/outline、/fix）整篇进 prompt 的体积上限：
    /// 超出后模型的「输出完整文档」不可靠，拒绝并提示改走聊天面板的 Agent 工具。
    static let maxDocumentChars = 32_000

    /// - Parameters:
    ///   - documentText: 删除命令文本后的文档全文（由 SlashCommandHandler 快照，
    ///     不读 tab.content——后者可能还停在含命令文本的防抖窗口里）
    ///   - insertionLocation: 命令删除后的光标位置（UTF-16 偏移）
    ///   - onWriteBack: diff 确认后真正写回文档时回调（参数为写回的整文内容）；
    ///     诊断面板/导出预检的「让 Agent 修复」用它触发修复后重扫/续跑导出
    static func run(
        command: AISlashCommand,
        argument: String,
        documentText: String,
        insertionLocation: Int,
        state: AppState,
        settings: AppSettings,
        onWriteBack: ((String) -> Void)? = nil
    ) {
        var ctx = AISlashCommand.Context()
        ctx.argument = argument
        ctx.document = documentText
        if let prefixRange = Range(NSRange(location: 0, length: insertionLocation), in: documentText) {
            ctx.precedingContext = String(documentText[prefixRange])
        }

        // 目标解析（scope）
        var targetRange: Range<String.Index>? = nil
        if command.scope == .paragraphOrSelection {
            let sel = state.editorSelectedRange
            if sel.length > 0, let r = Range(sel, in: documentText), !documentText[r].isEmpty {
                targetRange = r
            } else {
                targetRange = ParagraphTargeting.paragraphRange(at: insertionLocation, in: documentText)
            }
        }
        ctx.target = targetRange.map { String(documentText[$0]) } ?? ""

        // /fix：先跑静态诊断，无问题则直接反馈，不消耗模型调用
        if command.id == "fix" {
            guard let tab = state.selectedTab else {
                state.showToast(L("slash.noDocument"), icon: "exclamationmark.triangle")
                return
            }
            let issues = DocumentDiagnostics.issues(in: documentText, fileURL: tab.url) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard !issues.isEmpty else {
                state.showToast(L("slash.fix.noIssues"), icon: "checkmark.circle")
                return
            }
            ctx.diagnostics = formatIssues(issues)
        }

        // 空目标：有静态兜底（/table 骨架）则直接插入，否则提示
        if command.scope == .paragraphOrSelection,
           ctx.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let fallback = command.emptyFallbackInsertion {
                state.insertIntoEditor(fallback)
            } else {
                state.showToast(L("slash.noTarget"), icon: "exclamationmark.triangle")
            }
            return
        }
        if command.scope == .document {
            guard !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state.showToast(L("slash.emptyDocument"), icon: "exclamationmark.triangle")
                return
            }
            if command.output == .diffWriteBack, documentText.count > maxDocumentChars {
                state.showToast(L("slash.documentTooLarge"), icon: "exclamationmark.triangle")
                return
            }
            if command.output == .chatBubble {
                // 尺寸门控对齐：chatBubble 不整篇硬塞进聊天框，走
                // DocumentContextExcerpt 的预算截取（首部 + 光标附近 + 尾部）
                ctx.document = DocumentContextExcerpt.excerpt(
                    content: documentText, cursorLine: state.cursorLine)
            }
        }

        switch command.output {
        case .chatBubble:
            state.aiUI.pendingSelectionPrompt = command.buildPrompt(ctx)
            withAnimation(DS.Motion.spring) { state.showingAIAssistant = true }
        case .diffWriteBack:
            runWriteBack(command: command, ctx: ctx, targetRange: targetRange,
                         documentText: documentText, state: state, settings: settings,
                         onWriteBack: onWriteBack)
        }
    }

    // MARK: - diff 写回链路（与 InlineEditBar.triggerAction 同一模式）

    private static func runWriteBack(
        command: AISlashCommand,
        ctx: AISlashCommand.Context,
        targetRange: Range<String.Index>?,
        documentText: String,
        state: AppState,
        settings: AppSettings,
        onWriteBack: ((String) -> Void)?
    ) {
        let original = documentText
        func spliced(_ replacement: String) -> String {
            // document 级命令无局部范围：模型输出即整篇；段落级：替换目标段落
            guard let targetRange else { return replacement }
            return original.replacingCharacters(in: targetRange, with: replacement)
        }

        // 锁定发起 tab：AI 运行期间用户可能切换 tab——写回那一刻当前 tab 不是
        // 发起 tab 时绝不把结果合并进别的文档（provider / onFinalize 双重校验）
        let sourceTabID = state.selectedTab?.id

        // 连续触发写回命令：取消仍在运行的上一轮 runner（白烧 token）。其迟到的
        // onComplete 由 generation 校验拦截，不会误清新一轮的 diff UI / 注册。
        state.diffReview.activeRunner?.cancel()

        // 进入 diff 流式模式
        state.diffReview.beginStreaming(original: original, actionLabel: command.title)
        // 快照过期防护：AI 运行期间用户可能继续编辑——写回时以当前文档为起点
        // 重定位合并；目标段落已被改动则拒绝覆盖并提示，由用户放弃本次结果。
        // 当前 tab 不是发起 tab 时返回 nil（不进 rebase），由 onFinalize 的
        // tab 校验中止写回并提示。
        state.diffReview.currentContentProvider = { [weak state] in
            guard let state, state.selectedTab?.id == sourceTabID else { return nil }
            return state.selectedTab?.content
        }
        state.diffReview.onRebaseConflict = { [weak state] in
            state?.showToast(L("ai.inline.targetLost"), icon: "exclamationmark.triangle")
        }
        // 捕获 generation token：dismiss / 新一轮流式后在途回调写入被丢弃
        let streamGen = state.diffReview.streamGeneration

        let config  = AIConfig.current(settings, scene: .inline)   // 内联编辑专用模型
        let context = AgentContext.make(appState: state)
        let tools   = BuiltinAgentTools.all

        // 系统 prompt = 内置 inlineEditor skill + 用户插件附加（与行内编辑一致）
        var systemPrompt = BuiltinSkills.inlineEditor.content
        let extra = state.pluginManager.userSkillsPrompt()
        if !extra.isEmpty { systemPrompt += "\n\n---\n\n# 附加技能\n\n" + extra }

        let runner = AgentRunner()
        // 注册到 diffReview：dismiss 才能取消到这次运行；且 runner 由 diffReview
        // 强持有，run 不会在途中被释放
        state.diffReview.activeRunner = runner

        runner.onChunk = { [weak state] chunk in
            guard let state else { return }
            // 仅当 chunk 是最终文本时替换（AgentRunner 目前一次性输出）；
            // generation 校验：dismiss 后迟到的 chunk 不得写回
            state.diffReview.writeStreamedContent(spliced(chunk), generation: streamGen)
        }

        runner.onComplete = { [weak state, weak runner] in
            guard let state else { return }
            // 只在自己的 runner 仍注册时释放引用（避免清掉后一轮运行的注册）
            if let runner, state.diffReview.activeRunner === runner {
                state.diffReview.activeRunner = nil
            }
            if let err = runner?.error {
                // 过期 run（被新一轮触发取消 / 用户 dismiss）的迟到收尾不得
                // 误清新一轮的 diff UI，也不重复弹「已取消」toast
                if state.diffReview.streamGeneration == streamGen {
                    state.diffReview.dismiss()
                    state.showToast(err, icon: "exclamationmark.triangle")
                }
                return
            }
            let finalText = runner?.finalText ?? ""
            guard !finalText.isEmpty else {
                if state.diffReview.streamGeneration == streamGen {
                    state.diffReview.dismiss()
                    state.showToast(L("ai.inline.emptyResponse"), icon: "exclamationmark.triangle")
                }
                return
            }
            state.diffReview.commitStreamWithModified(spliced(finalText), generation: streamGen) { merged in
                // 写回那一刻当前 tab 必须仍是发起 tab：AI 运行期间切了 tab 则
                // 放弃本次结果（finalize 随后 dismiss），绝不写进别的文档
                guard let tab = state.selectedTab, tab.id == sourceTabID else {
                    state.showToast(L("slash.writeBack.tabChanged"), icon: "exclamationmark.triangle")
                    return
                }
                // 统一走 applyAIWriteBack：编辑器挂载时可撤销最小化替换
                state.applyAIWriteBack(tab.id, content: merged)
                onWriteBack?(merged)
            }
        }

        runner.run(
            systemPrompt: systemPrompt,
            userMessage: command.buildPrompt(ctx),
            tools: tools,
            config: config,
            context: context
        )
    }

    // MARK: - 诊断结果格式化（/fix 的 prompt 上下文）

    static func formatIssues(_ issues: [DocumentIssue]) -> String {
        issues.map { issue in
            let desc: String
            switch issue.kind {
            case .deadLink(let target):
                desc = "死链：链接目标文件不存在（\(target)）"
            case .missingImage(let target):
                desc = "图片缺失：引用的本地图片不存在（\(target)）"
            case .duplicateHeading(let heading):
                desc = "重复标题：「\(heading)」在文档中出现多次"
            case .headingLevelSkip(let from, let to):
                desc = "标题层级跳跃：H\(from) 直接跳到 H\(to)"
            case .emptyHeading:
                desc = "空标题：只有 # 没有文字"
            case .unclosedCodeBlock:
                desc = "围栏代码块未闭合"
            case .mermaidSyntax(let message):
                desc = "Mermaid 语法错误：\(message)"
            }
            // 行号转 1-based 展示（DocumentIssue.line 是 0-based）
            return "- 第 \(issue.line + 1) 行：\(desc)"
        }.joined(separator: "\n")
    }
}
