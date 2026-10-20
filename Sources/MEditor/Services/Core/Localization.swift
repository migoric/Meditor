import Foundation
import Observation

/// UI language options. `.system` follows the OS preferred language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, chinese
    var id: String { rawValue }
}

/// Runtime UI localization. `@Observable` so any SwiftUI view that calls
/// `L(...)` in its body re-renders when the language changes — no relaunch
/// needed for in-window UI. (The main menu bar refreshes on next launch.)
@Observable
final class LocalizationManager: @unchecked Sendable {
    static let shared = LocalizationManager()
    private static let key = "MEditor.language"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else {
            language = .system
        }
    }

    /// Effective language after resolving `.system`.
    var resolved: AppLanguage {
        guard language == .system else { return language }
        let prefersZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        return prefersZh ? .chinese : .english
    }

    func localized(_ key: String) -> String {
        // Reading `resolved` (which reads `language`) registers the dependency.
        let useZh = (resolved == .chinese)
        guard let pair = Self.table[key] else { return key }
        return useZh ? pair.zh : pair.en
    }
}

/// Look up a localized string by key.
///
/// 防回归（评审 M2）：所有面向用户的 UI 文案必须走 `L(key)` 并在下方翻译表登记中英双语，
/// 禁止在视图/ViewModel 里直接写中文字符串字面量。新增 key 按 `模块.语义` 命名，
/// 追加到 `tableN` 对应分组；存量硬编码缺口分批治理，见各批提交记录。
func L(_ key: String) -> String { LocalizationManager.shared.localized(key) }

/// Look up a localized format string and interpolate arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: LocalizationManager.shared.localized(key), arguments: args)
}

// MARK: - Translation table

extension LocalizationManager {
    private static let table0: [String: (en: String, zh: String)] = [
        // Common
        "common.ok": ("OK", "好"),
        "common.cancel": ("Cancel", "取消"),
        "common.save": ("Save", "保存"),
        "common.create": ("Create", "创建"),
        "common.delete": ("Delete", "删除"),
        "common.close": ("Close", "关闭"),
        "common.yes": ("Yes", "是"),
        "common.no": ("No", "否"),
        "common.search": ("Search", "搜索"),
        "common.noMatches": ("No matches", "无匹配项"),

        // AI assistant
        "ai.assistant": ("Assistant", "助手"),
        "ai.openAssistant": ("Open AI Assistant", "打开 AI 助手"),
        "ai.newChat": ("New Chat", "新聊天"),
        "ai.history": ("History", "历史记录"),
        "ai.thinking": ("Thinking…", "思考中…"),
        "ai.currentDocument": ("Current Document", "当前文档"),
        "ai.context": ("Context", "上下文"),
        "ai.greeting": ("How can I help?", "我能帮你做什么？"),
        "ai.greetingSub": ("Ask anything, or pick a suggestion below.", "问我任何问题，或从下方选择一个建议。"),
        "ai.accent.system": ("System accent (blue)", "系统强调色（蓝）"),
        "ai.accent.mono": ("Mono (shadcn black)", "高级黑（shadcn）"),
        "ai.accentStyle": ("Accent style", "强调色风格"),
        "ai.mode.local": ("Local", "本地"),
        "ai.mode.remote": ("Remote", "远程"),
        "ai.section.mode": ("Mode", "模式"),
        "ai.section.local": ("Local (Claude CLI)", "本地（Claude CLI）"),
        "ai.section.remote": ("Remote API (OpenAI-compatible)", "远程 API（OpenAI 兼容）"),
        "ai.section.appearance": ("Appearance", "外观"),
        "ai.preset": ("Provider", "服务商"),
        "ai.preset.custom": ("Custom", "自定义"),
        "ai.copy": ("Copy", "复制"),
        "ai.copied": ("Copied", "已复制"),
        "ai.insertToDoc": ("Insert", "插入文档"),
        "ai.detect": ("Auto-detect", "自动检测"),
        "ai.refreshModels": ("Refresh model list", "刷新模型列表"),
        "ai.history.title": ("Chat history", "聊天记录"),
        "ai.history.empty": ("No past chats yet", "暂无历史会话"),
        "ai.session.untitled": ("New chat", "新对话"),
        "settings.tab.ai": ("AI", "AI"),
        "ai.provider": ("AI provider", "AI 提供方"),
        "ai.provider.disabled": ("Off (preview)", "关闭（预览）"),
        "ai.provider.openai": ("Custom API (OpenAI-compatible)", "自定义 API（OpenAI 兼容）"),
        "ai.provider.claudeCLI": ("Local Claude CLI", "本地 Claude CLI"),
        "ai.baseURL": ("Base URL", "接口地址"),
        "ai.model": ("Model", "模型"),
        "ai.apiKey": ("API key", "API 密钥"),
        "ai.cliPath": ("claude path", "claude 路径"),
        "ai.cliHint": ("Reuses your local Claude Code login. Find the path with: which claude",
                       "复用本地 Claude Code 登录态。用 which claude 查看路径"),
        "ai.error.notConfigured": ("AI provider isn't configured. Open Settings → AI Assistant.",
                                   "AI 尚未配置，请前往 设置 → AI 助手。"),
        "ai.error.badURL": ("Invalid Base URL.", "接口地址无效。"),
        "ai.error.server": ("Server error %d: %@", "服务返回错误 %d：%@"),
        "ai.error.cliNotFound": ("claude not found at %@", "在 %@ 找不到 claude"),
        "ai.error.cliFailed": ("Claude CLI failed: %@", "Claude CLI 执行失败：%@"),
        "ai.error.network": ("Network error: %@", "网络错误：%@"),
        "ai.inputPlaceholder": ("Message the assistant", "给助手发消息"),
        "ai.execute": ("Run", "执行"),
        "ai.stop": ("Stop", "停止"),
        "ai.respondingElsewhere": ("Generating in another chat…", "另一会话生成中…"),
        "ai.regenerate": ("Regenerate", "重新生成"),        "ai.showMore": ("Show %d more", "再显示 %d 个"),
        "ai.section.suggestions": ("Suggestions", "建议"),
        "ai.section.yourPrompts": ("Your prompts", "你的提示"),
        "ai.createCustomPrompt": ("Create custom prompt", "创建自定义提示"),

        // @mention 功能入口
        "ai.section.mention": ("Reference context", "引用上下文"),
        "ai.mention.currentHint": ("Inject current document into the conversation", "将当前文档内容注入对话"),
        "ai.mention.workspaceHint": ("Inject workspace file list", "将工作区文件列表注入对话"),
        "ai.mention.file": ("@file", "引用文件"),
        "ai.mention.fileHint": ("Type @ to pick any file in the workspace", "输入 @ 选择工作区任意文件"),

        // @mention 首次引导卡片
        "ai.mention.cardTitle": ("Reference files with @mention", "@mention 引用文件"),
        "ai.mention.cardBody": ("Type @ in the input box to reference files, directories, or the full workspace. The AI will read their content before responding.",
                                "在输入框中输入 @ 可引用文件、目录或整个工作区，AI 会先读取内容再回复。"),

        // @mention picker
        "ai.mention.pickerTitle": ("Reference file or directory", "引用文件或目录"),
        "ai.mention.pickerSearch": ("Search \"%@\"", "搜索「%@」"),
        "ai.mention.pickerHint": ("↑↓ navigate  ↵ select  Esc close", "↑↓ 导航  ↵ 确认  Esc 关闭"),
        "ai.mention.noMatches": ("No matching files", "没有匹配的文件"),
        "ai.mention.builtin": ("Built-in", "内建"),
        "ai.mention.tagFileExample": ("@file", "@文件名"),

        // AI 面板：引用选段卡片 / 上下文警告
        "ai.quotedSelection": ("Quoted selection", "引用选段"),
        "ai.removeQuote": ("Remove quote", "移除引用"),
        "ai.contextNearlyFull": ("Context nearly full — start a new chat to avoid truncation.",
                                 "上下文即将占满，建议开启新对话以避免截断。"),

        // 待确认执行命令确认条
        "ai.command.pendingTitle": ("Command awaiting confirmation", "待确认执行命令"),
        "ai.command.cwd": ("Directory: %@", "目录：%@"),
        "ai.command.reject": ("Reject", "拒绝"),
        "ai.command.rememberHint": ("Won't ask again for this session", "确认后本次会话不再询问"),

        // 待确认文件写入确认条（与命令确认条同一范式）
        "ai.write.pendingTitle": ("File write awaiting confirmation", "待确认文件写入"),
        "ai.write.allow": ("Allow", "允许"),
        "ai.write.allowAll": ("Allow all for this run", "本次运行全部允许"),
        "ai.write.allowAllHint": ("\"Allow all\" only applies to the current run", "「全部允许」仅对本次运行有效"),
        // 写确认条 diff 预览（默认收起，点「查看改动」展开）
        "ai.write.viewDiff": ("View changes (%d)", "查看改动（%d 处）"),
        "ai.write.hideDiff": ("Hide changes", "收起改动"),
        "ai.write.diffTooLarge": ("File too large — diff not shown", "文件过大，不显示改动详情"),
        "ai.write.diffMore": ("… and %d more", "…… 另有 %d 处改动"),

        // Agent run 一键回滚（步骤面板尾部入口）
        "ai.rollback.undoRun": ("Undo all changes from this run", "撤销本次运行的全部修改"),
        "ai.rollback.fileCountSuffix": (" (%d files)", "（%d 个文件）"),
        "ai.rollback.summaryDone": ("Rolled back %d file(s)", "已回滚 %d 个文件"),
        "ai.rollback.summarySkipped": ("; skipped: %@", "；跳过：%@"),
        "ai.rollback.skipEdited": ("edited after the run", "运行后又有改动"),
        "ai.rollback.skipMissing": ("already deleted", "已不存在"),
        "ai.rollback.skipWriteFailed": ("restore write failed", "恢复写盘失败"),

        // Agent 执行面板
        "ai.agent.title": ("Agent Run", "Agent 执行"),
        "ai.agent.collapseSteps": ("Collapse earlier steps", "折叠早期步骤"),
        "ai.agent.collapsedSteps": ("▸ %d earlier steps collapsed", "▸ 已折叠 %d 个早期步骤"),
        "ai.agent.reply": ("Reply", "回复"),
        "ai.agent.collapse": ("Collapse", "收起"),
        "ai.agent.expand": ("Expand", "展开"),
        "ai.agent.done": ("Agent finished", "Agent 已完成"),
        "ai.agent.doneButton": ("Done", "完成"),

        // Agent 工具调用摘要（macOS / iOS 共享 AgentToolDisplay）
        "ai.tool.createFile": ("Create file", "创建文件"),
        "ai.tool.createFileNamed": ("Create file · %@", "创建文件 · %@"),
        "ai.tool.writeFile": ("Write file%@", "写入文件%@"),
        "ai.tool.writeFileNamed": ("Write %@%@", "写入 %@%@"),
        "ai.tool.sizeSuffix": (" (%d chars)", " (%d 字)"),
        "ai.tool.createDir": ("Create directory", "创建目录"),
        "ai.tool.createDirNamed": ("Create directory · %@", "创建目录 · %@"),
        "ai.tool.updateDocument": ("Update current document%@", "更新当前文档%@"),
        "ai.tool.patchDocument": ("Patch document%@", "精准修改文档%@"),
        "ai.tool.patchPreview": (" · \"%@\"", " · 「%@」"),
        "ai.tool.readDocument": ("Read current document", "读取当前文档"),
        "ai.tool.readFile": ("Read file", "读取文件"),
        "ai.tool.readFileNamed": ("Read · %@", "读取 · %@"),
        "ai.tool.openFile": ("Open file", "打开文件"),
        "ai.tool.openFileNamed": ("Open · %@", "打开 · %@"),
        "ai.tool.insertAtCursor": ("Insert content%@", "插入内容%@"),
        "ai.tool.listFiles": ("List workspace files", "列出工作区文件"),
        "ai.tool.searchWorkspace": ("Search workspace", "搜索工作区"),
        "ai.tool.searchWorkspaceQuery": ("Search \"%@\"", "搜索「%@」"),
        "ai.tool.searchDocument": ("Search document", "搜索文档"),
        "ai.tool.searchDocumentQuery": ("Search in document \"%@\"", "文档内搜索「%@」"),
        "ai.tool.runCommand": ("Run command", "执行命令"),
        "ai.tool.runCommandNamed": ("Run · %@", "执行命令 · %@"),

        // 行内编辑（编辑器 / 预览两个 bar）
        "ai.inline.working": ("AI: %@…", "AI %@中…"),
        "ai.inline.rewrite": ("Rewrite", "改写"),
        "ai.inline.expand": ("Expand", "扩写"),
        "ai.inline.condense": ("Condense", "精简"),
        "ai.inline.explain": ("Explain", "解释"),
        "ai.inline.addComments": ("Add comments", "加注释"),
        "ai.inline.expandSection": ("Expand section", "扩写章节"),
        "ai.inline.organizeList": ("Organize", "整理"),
        "ai.inline.more": ("More", "更多"),
        "ai.inline.adjust": ("Adjust", "调整"),
        "ai.inline.emptyResponse": ("AI returned no content", "AI 未返回内容"),
        "ai.inline.mapFailed": ("Couldn't map the selection back to the source text — please select it in the editor instead.",
                                "圈选内容无法对应回原文，请改从编辑器中圈选"),
        "ai.inline.targetLost": ("The document changed while the AI was working — the target passage couldn't be located, so the result wasn't applied.",
                                 "文档在 AI 处理期间已被修改，目标段落无法定位，本次结果未写回"),
        "ai.inline.selectionLost": ("Couldn't locate the selected text in the document — please re-select it and try again.",
                                    "无法在文档中定位选中文本，请重新圈选后重试"),

        // InlineEditBar 问 AI 按钒
        "ai.askAI": ("Ask AI", "问 AI"),
        "ai.askAIHint": ("Open AI assistant with this selection pre-loaded", "将选中文本带入 AI 助手对话"),

        // 自动附带当前文档（chip + 设置开关）
        "ai.autoAttach": ("Auto-attached: %@", "自动附带：%@"),
        "ai.autoAttach.remove": ("Skip for this message only", "仅本次发送不附带"),
        "ai.autoAttach.toggle": ("Auto-attach current document", "自动附带当前文档"),
        "ai.autoAttach.toggleHint": ("Inject the active tab as default context when sending; the input bar chip can skip it per message",
                                     "发送对话时默认注入当前 tab 的文档内容；输入栏 chip 可单次移除"),

        // 聊天视觉输入（图片附件：输入框 chips / 气泡缩略图 / 后端降级提示）
        "ai.images.remove": ("Remove image", "移除图片"),
        "ai.images.preview": ("Preview image", "预览图片"),
        "ai.images.decodeFailed": ("Couldn't load this image", "图片加载失败"),
        "ai.images.historyPlaceholder": ("%d image(s) — images aren't kept in chat history",
                                         "%d 张图片（历史记录不保存图片内容）"),
        "ai.images.unsupportedBackend": ("The current backend doesn't support image input — your images weren't sent, only the text.",
                                         "当前后端不支持图片输入——图片未发送，仅发送了文字。"),

        // 斜杠 AI 命令库（编辑器 / 菜单，标题与一句话说明随 UI 语言）
        "slash.ask.title": ("AI Answer", "AI 回答问题"),
        "slash.ask.subtitle": ("Ask a question inline at the caret", "在光标处内联回答问题"),
        "slash.summary.title": ("AI Summary", "AI 摘要"),
        "slash.summary.subtitle": ("Summarize the document as a chat reply", "在聊天面板生成全文摘要"),
        "slash.continue.title": ("AI Continue Writing", "AI 继续写作"),
        "slash.continue.subtitle": ("Continue from the caret, matching style", "从当前光标继续展开内容"),
        "slash.improve.title": ("AI Improve Paragraph", "AI 优化段落"),
        "slash.improve.subtitle": ("Improve the current paragraph via chat", "在聊天面板改善当前段落"),
        "slash.summarize.title": ("AI Summarize Above", "AI 总结以上"),
        "slash.summarize.subtitle": ("Summarize everything above the caret", "总结光标以上的所有内容"),
        "slash.polish.title": ("AI Polish", "AI 润色"),
        "slash.polish.subtitle": ("Polish the current paragraph (diff review)", "润色当前段落（diff 确认写回）"),
        "slash.outline.title": ("AI Re-outline", "AI 重排结构"),
        "slash.outline.subtitle": ("Restructure headings and sections (diff review)", "重排标题层级与章节顺序（diff 确认）"),
        "slash.translate.title": ("AI Translate", "AI 翻译"),
        "slash.translate.subtitle": ("Chinese ↔ English for the current paragraph (diff review)", "当前段落中英互译（diff 确认写回）"),
        "slash.fix.title": ("AI Fix Issues", "AI 修复问题"),
        "slash.fix.subtitle": ("Fix issues found by document diagnostics", "修复文档诊断发现的问题"),
        "slash.table.title": ("AI To Table", "AI 转表格"),
        "slash.table.subtitle": ("Convert the current paragraph/list into a Markdown table", "把当前段落/列表转成规范 Markdown 表格"),
        "slash.fix.noIssues": ("No issues found by diagnostics", "诊断未发现问题"),
        "slash.noTarget": ("No paragraph at the caret to process", "光标处没有可处理的段落"),
        "slash.emptyDocument": ("The current document is empty", "当前文档为空"),
        "slash.documentTooLarge": ("Document is too large for a whole-document rewrite — use the chat panel instead",
                                   "文档过大，无法整篇改写——请改用聊天面板"),
        "slash.noDocument": ("No document is currently open", "当前没有打开的文档"),
        "slash.writeBack.tabChanged": ("You switched documents while the AI was working — the result wasn't applied",
                                       "AI 运行期间切换了文档，本次结果未写回"),

        "ai.inline.toTable": ("To table", "转表格"),
        "ai.previewReply": (
            "The AI service isn't connected yet — this is a UI preview. Hook up a model provider to enable real responses.",
            "AI 服务尚未连接 —— 这是界面预览。接入模型服务后即可获得真实回复。"
        ),

        // AI suggestions
        "ai.suggest.whatCanYouDo": ("What can the assistant do?", "助手能帮我做什么？"),
        "ai.suggest.summarize": ("Add a summary", "添加摘要"),
        "ai.suggest.improveClarity": ("Improve clarity", "提升清晰度"),
        "ai.suggest.fixGrammar": ("Fix spelling & grammar", "改进拼写和语法"),
        "ai.suggest.translate": ("Translate", "翻译"),
        "ai.suggest.styleDocument": ("Style this document", "为此页面设置样式"),
        "ai.suggest.outline": ("Generate an outline", "生成大纲"),
        "ai.suggest.shorten": ("Make it shorter", "精简内容"),
        "ai.suggest.expand": ("Expand on this", "扩展内容"),
        "ai.suggest.toTable": ("Convert to a table", "转换为表格"),

        // AI suggestion prompts (inserted into the compose field)
        "ai.prompt.whatCanYouDo": ("What can you help me with?", "你能帮我做些什么？"),
        "ai.prompt.summarize": ("Summarize this document.", "总结这篇文档。"),
        "ai.prompt.improveClarity": ("Improve the clarity of this document.", "提升这篇文档的清晰度。"),
        "ai.prompt.fixGrammar": ("Fix the spelling and grammar in this document.", "修正这篇文档的拼写和语法。"),
        "ai.prompt.translate": ("Translate this document.", "翻译这篇文档。"),
        "ai.prompt.styleDocument": ("Suggest a style for this document.", "为这篇文档建议一种排版样式。"),
        "ai.prompt.outline": ("Generate an outline for this document.", "为这篇文档生成大纲。"),
        "ai.prompt.shorten": ("Make this document shorter.", "精简这篇文档。"),
        "ai.prompt.expand": ("Expand on the ideas in this document.", "扩展这篇文档中的内容。"),
        "ai.prompt.toTable": ("Convert this content into a table.", "将这部分内容转换为表格。"),

        // Menus / commands
        "menu.openFolder": ("Open Folder…", "打开文件夹…"),
        "menu.bold": ("Bold", "加粗"),
        "menu.italic": ("Italic", "斜体"),
        "menu.link": ("Insert Link", "插入链接"),
        "menu.openFile": ("Open File…", "打开文件…"),
        "menu.newFile": ("New from Template…", "从模板新建…"),
        "menu.saveAsTemplate": ("Save as Template…", "保存为模板…"),
        "template.search": ("Search templates…", "搜索模板…"),
        "template.myTemplates": ("My Templates", "我的模板"),
        "template.create": ("Create", "创建"),
        "template.saveTitle": ("Save as Template", "保存为模板"),
        "template.namePlaceholder": ("Template name", "模板名称"),
        "template.saveMessage": ("Save current file content as a reusable template.", "将当前文件内容保存为可复用模板。"),
        "template.builtinSection": ("Built-in", "内置模板"),
        "template.selectHint": ("Select a template to get started", "选择模板以开始创建"),
        "template.blank": ("Blank", "空白文档"),
        "template.blankDesc": ("Empty document", "空文档"),
        "template.meeting": ("Meeting Notes", "会议记录"),
        "template.meetingDesc": ("Attendees, agenda, action items", "参会人、议程、待办事项"),
        "template.techDesign": ("Tech Design", "技术方案"),
        "template.techDesignDesc": ("Background, design, implementation plan", "背景、设计、实施计划"),
        "template.weekly": ("Weekly Report", "周报"),
        "template.weeklyDesc": ("Progress, blockers, next week plan", "进展、阻塞、下周计划"),
        "template.journal": ("Journal", "日记"),
        "template.journalDesc": ("Daily reflection and notes", "每日反思与笔记"),
        "template.htmlDoc": ("HTML Document", "HTML 文档"),
        "template.htmlDocDesc": ("Styled document with sidebar navigation", "带侧边栏导航的样式文档"),
        "menu.newFolder": ("New Folder", "新建文件夹"),
        "menu.save": ("Save", "保存"),
        "menu.find": ("Find…", "查找…"),
        "menu.findNext": ("Find Next", "查找下一个"),
        "menu.findPrevious": ("Find Previous", "查找上一个"),
        "menu.useSelectionForFind": ("Use Selection for Find", "用所选内容查找"),
        "menu.jumpToLine": ("Jump to Line…", "跳转到行…"),
        "menu.findInWorkspace": ("Find in Workspace…", "在工作区中查找…"),
        "menu.replace": ("Replace…", "替换…"),
        "menu.closeTab": ("Close Tab", "关闭标签"),
        "menu.reopenClosedTab": ("Reopen Closed Tab", "重新打开关闭的标签"),
        "menu.nextTab": ("Next Tab", "下一个标签"),
        "menu.previousTab": ("Previous Tab", "上一个标签"),
        "menu.quickOpen": ("Quick Open…", "快速打开…"),
        "menu.commandPalette": ("Command Palette…", "命令面板…"),
        "menu.presentation": ("Presentation Mode", "演讲模式"),
        "menu.exportPresentation": ("Export Presentation…", "导出演示文稿…"),
        "menu.copyAbsolutePath": ("Copy Absolute Path", "复制绝对路径"),
        "menu.copyRelativePath": ("Copy Relative Path", "复制相对路径"),
        "menu.revealInFinder": ("Reveal in Finder", "在 Finder 中显示"),
        "panel.chooseFolder": ("Choose a project folder", "选择一个项目文件夹"),
        "menu.tools": ("Tools", "工具"),
        "menu.aiAssistant": ("AI Assistant", "AI 助手"),
        "menu.documentDiagnostics": ("Document Diagnostics…", "文档诊断…"),
        "diagnostics.title": ("Document Diagnostics", "文档诊断"),
        "diagnostics.scanning": ("Scanning %1$d/%2$d files…", "正在扫描 %1$d/%2$d 个文件…"),
        "diagnostics.summary": ("%1$d issues in %2$d files", "%2$d 个文件共 %1$d 个问题"),
        "diagnostics.noIssues": ("No issues found", "未发现问题"),
        "diagnostics.rescan": ("Rescan", "重新扫描"),
        "diagnostics.close": ("Close", "关闭"),
        "diagnostics.deadLink": ("Dead link: %@", "死链：%@"),
        "diagnostics.missingImage": ("Missing image: %@", "图片缺失：%@"),
        "diagnostics.duplicateHeading": ("Duplicate heading: %@", "重复标题：%@"),
        "diagnostics.headingLevelSkip": ("Heading level skipped: H%1$d → H%2$d", "标题层级跳跃：H%1$d → H%2$d"),
        "diagnostics.emptyHeading": ("Empty heading", "空标题"),
        "diagnostics.unclosedCodeBlock": ("Unclosed code block", "代码块未闭合"),
        "diagnostics.mermaidSyntax": ("Mermaid syntax error: %@", "Mermaid 语法错误：%@"),
        "diagnostics.fix.agent": ("Fix with Agent", "让 Agent 修复"),
        "diagnostics.fix.scope": ("Agent can fix %d issue(s) in the current document",
                                  "当前文档有 %d 个问题可由 Agent 修复"),
        "diagnostics.fix.tooLarge": ("Document is too large for Agent fix — use the chat panel instead",
                                     "文档过大，Agent 无法整篇修复——请改用聊天面板"),
        "diagnostics.fix.report": ("Agent fix applied: %1$d fixed, %2$d remaining",
                                   "Agent 修复完成：已修复 %1$d 条，剩余 %2$d 条"),
    ]

    private static let table1: [String: (en: String, zh: String)] = [
        // Welcome
        "welcome.subtitle": ("Markdown & HTML Editor", "Markdown & HTML 编辑器"),
        "welcome.dropHint": ("Or drop a folder here", "或将文件夹拖放到此处"),

        // Alerts
        "alert.errorTitle": ("Error", "错误"),
        "alert.saveChangesTitle": ("Save changes?", "保存更改？"),
        "alert.dontSave": ("Don't Save", "不保存"),
        "alert.saveChangesMessage": ("Save changes to \"%@\" before closing?", "关闭前保存对\"%@\"的更改？"),
        "alert.fileChanged": ("File Changed", "文件已更改"),
        "alert.fileChangedMessage": ("\"%@\" was modified by another app. Keep your changes or reload from disk?", "\"%@\"被其他应用修改。保留你的更改还是从磁盘重新加载？"),
        "alert.keepMine": ("Keep Mine", "保留我的"),
        "alert.reload": ("Reload", "重新加载"),
        "alert.largeFile": ("Large File", "大文件"),
        "alert.largeFileMessage": ("\"%@\" is large and may be slow to edit. Open anyway?", "\"%@\"文件较大，编辑可能较慢。仍要打开吗？"),
        "alert.openAnyway": ("Open Anyway", "仍然打开"),

        // Toolbar tooltips
        "tooltip.showSidebar": ("Show Sidebar (⌥⌘B)", "显示侧边栏 (⌥⌘B)"),
        "tooltip.hideSidebar": ("Hide Sidebar (⌥⌘B)", "隐藏侧边栏 (⌥⌘B)"),
        "tooltip.showPreview": ("Show Preview (⌘⇧V)", "显示预览 (⌘⇧V)"),
        "tooltip.hidePreview": ("Hide Preview (⌘⇧V)", "隐藏预览 (⌘⇧V)"),
        "tooltip.showEditor": ("Show Editor (⌘⇧M)", "显示编辑器 (⌘⇧M)"),
        "tooltip.hideEditor": ("Hide Editor (⌘⇧M)", "隐藏编辑器 (⌘⇧M)"),
        "tooltip.focusMode": ("Focus Mode", "专注模式"),
        "tooltip.exitFocus": ("Exit Focus Mode (Esc)", "退出专注模式 (Esc)"),
        "focus.hint": ("Press Esc to exit Focus Mode", "按 Esc 退出专注模式"),

        // Sharing
        "share.viaLAN": ("Share via LAN", "通过局域网分享"),
        "share.stopWithURL": ("Stop Sharing (%@)", "停止分享 (%@)"),
        "share.active": ("LAN Share Active", "局域网分享中"),
        "share.currentFile": ("Current file:", "当前文件："),
        "share.copyURL": ("Copy URL", "复制链接"),
        "share.stop": ("Stop Sharing", "停止分享"),
        "share.lan.title": ("LAN Share", "局域网分享"),

        // GitHub Gist sharing
        "github.gist.title": ("GitHub Gist", "GitHub Gist"),
        "github.gist.token": ("Personal Access Token", "Personal Access Token"),
        "github.gist.tokenConfigured": ("Configured", "已配置"),
        "github.gist.clearToken": ("Clear", "清除"),
        "github.gist.saveToken": ("Save", "保存"),
        "github.gist.visibility": ("Visibility", "可见性"),
        "github.gist.public": ("Public", "公开"),
        "github.gist.secret": ("Secret", "私密"),
        "github.error.notConfigured": ("GitHub not configured — set a token first.", "GitHub 未配置——请先设置 Token。"),
        "github.error.invalidToken": ("Invalid token — please reconfigure.", "Token 无效，请重新配置。"),
        "github.error.insufficientScope": ("Token lacks permission — needs gist scope.", "Token 权限不足，需要 gist 权限。"),
        "github.error.tooLarge": ("File too large (>1MB) to share as a Gist.", "文件过大（>1MB），无法作为 Gist 分享。"),
        "github.error.network": ("Cannot reach GitHub — check your network.", "无法连接 GitHub，请检查网络。"),
        "github.error.server": ("GitHub error %d: %@", "GitHub 错误 %d：%@"),
        "github.error.badResponse": ("Unexpected response from GitHub.", "GitHub 返回异常。"),
        "github.error.keychain": ("Keychain error (%d).", "钥匙串错误（%d）。"),

        // GitLab Snippet sharing
        "gitlab.title": ("GitLab Snippet", "GitLab Snippet"),
        "gitlab.publish": ("Publish to GitLab", "发布到 GitLab"),
        "gitlab.publishing": ("Publishing…", "正在发布…"),
        "gitlab.shared": ("Snippet URL", "Snippet 链接"),
        "gitlab.open": ("Open", "打开"),
        "gitlab.configHint": ("Configure your GitLab host and a Personal Access Token (api scope) to publish snippets.", "配置 GitLab 主机和 Personal Access Token（需 api 权限）后即可发布 Snippet。"),
        "gitlab.host": ("GitLab Host", "GitLab 主机"),
        "gitlab.token": ("Personal Access Token", "Personal Access Token"),
        "gitlab.saveConfig": ("Save", "保存"),
        "gitlab.manageHint": ("Manage host & token in Settings → Sharing.", "在 设置 → 分享 中管理主机与 Token。"),
        "gitlab.visibility.internal": ("Internal", "内部可见"),
        "gitlab.visibility.private": ("Private", "仅自己"),
        "gitlab.tokenConfigured": ("Configured", "已配置"),
        "gitlab.clearToken": ("Clear", "清除"),
        "gitlab.error.notConfigured": ("GitLab not configured — set host and token first.", "GitLab 未配置——请先设置主机和 Token。"),
        "gitlab.error.invalidToken": ("Invalid token — please reconfigure.", "Token 无效，请重新配置。"),
        "gitlab.error.insufficientScope": ("Token lacks permission — needs api scope.", "Token 权限不足，需要 api 权限。"),
        "gitlab.error.tooLarge": ("File too large (>1MB) to share as a snippet.", "文件过大（>1MB），无法作为 Snippet 分享。"),
        "gitlab.error.network": ("Cannot reach GitLab — check your network.", "无法连接 GitLab，请检查网络。"),
        "gitlab.error.server": ("GitLab error %d: %@", "GitLab 错误 %d：%@"),
        "gitlab.error.badResponse": ("Unexpected response from GitLab.", "GitLab 返回异常。"),
        "gitlab.error.keychain": ("Keychain error (%d).", "钥匙串错误（%d）。"),

        // 在线分享链接（自建 Worker）
        "sharelink.title": ("Online Share", "在线分享"),
        "sharelink.publish": ("Publish Online Link", "发布在线链接"),
        "sharelink.republish": ("Republish Online Link", "重新发布在线链接"),
        "sharelink.publishing": ("Publishing…", "正在发布…"),
        "sharelink.copyLink": ("Copy Link", "复制链接"),
        "sharelink.openInBrowser": ("Open in Browser", "在浏览器中打开"),
        "sharelink.baseURL": ("Share Service URL", "分享服务地址"),
        "sharelink.baseURLHint": ("Self-hosted share endpoint. Switch to your custom domain before release.", "自建分享服务地址，发布前可换成自定义域名。"),
        "sharelink.token": ("Share Token", "分享 Token"),
        "sharelink.tokenHint": ("Your personal share token issued by the service operator (one of the Worker's SHARE_TOKENS).", "服务方分配给你的个人分享 Token（Worker 的 SHARE_TOKENS 之一）。"),
        "sharelink.tokenConfigured": ("Configured", "已配置"),
        "sharelink.clearToken": ("Clear", "清除"),
        "sharelink.saveToken": ("Save", "保存"),
        "sharelink.error.notConfigured": ("Share not configured — set a token in Settings → Sharing first.", "在线分享未配置——请先在 设置 → 分享 中设置 Token。"),
        "sharelink.error.invalidToken": ("Invalid share token — please reconfigure.", "分享 Token 无效，请重新配置。"),
        "sharelink.error.tooLarge": ("Document too large (>4MB) to publish.", "文档过大（>4MB），无法发布。"),
        "sharelink.error.quotaExceeded": ("Monthly publish quota used up (%d documents on the free plan). It resets on the 1st of next month — upgrade to Pro for unlimited publishing.", "本月发布额度已用完（免费档 %d 篇）。下月 1 日重置，升级 Pro 可无限发布。"),
        "sharelink.error.network": ("Cannot reach the share service — check your network.", "无法连接分享服务，请检查网络。"),
        "sharelink.error.server": ("Share service error %d: %@", "分享服务错误 %d：%@"),
        "sharelink.error.badResponse": ("Unexpected response from the share service.", "分享服务返回异常。"),
        "sharelink.error.noWebView": ("Preview is not ready yet — try again in a moment.", "预览尚未就绪，请稍后重试。"),
        "sharelink.error.renderFailed": ("Failed to render the document: %@", "文档渲染失败：%@"),
    ]

    private static let table2: [String: (en: String, zh: String)] = [
        // Export
        "export.title": ("Export Preview", "导出预览"),
        "export.markdown": ("Export as Markdown…", "导出为 Markdown…"),
        "export.pdf": ("Export as PDF…", "导出为 PDF…"),
        "export.image": ("Export as Image…", "导出为图片…"),
        "export.html": ("Export as HTML…", "导出为 HTML…"),

        // Export preflight check（导出前检查清单）
        "export.preflight.title": ("Export Check", "导出检查"),
        "export.preflight.summary": ("%d issue(s) found in this document", "本文档发现 %d 个问题"),
        "export.preflight.hint": ("Fix them first, or export anyway.", "可以先修复，或直接导出。"),
        "export.preflight.exportAnyway": ("Export Anyway", "仍然导出"),

        // PDF export options（PDF 导出选项）
        "pdf.options.title": ("PDF Options", "PDF 选项"),
        "pdf.paperSize": ("Paper Size", "纸张大小"),
        "pdf.paper.a4": ("A4", "A4"),
        "pdf.paper.letter": ("Letter", "Letter"),
        "pdf.margins": ("Margins", "页边距"),
        "pdf.margins.narrow": ("Narrow", "窄"),
        "pdf.margins.normal": ("Normal", "标准"),
        "pdf.margins.wide": ("Wide", "宽"),
        "pdf.showHeader": ("Header (document title)", "页眉（文档标题）"),
        "pdf.showFooter": ("Footer (page numbers)", "页脚（页码）"),
        "pdf.coverPage": ("Cover page (title + date)", "封面页（标题 + 日期）"),
        "pdf.options.linkLossHint": (
            "Custom layout drops clickable links in the exported PDF",
            "自定义排版将丢失可点击链接"
        ),

        // Copy as rich text（复制为富文本）
        "action.copyRichText": ("Copy as Rich Text", "复制为富文本"),
        "richText.copied": ("Rich text copied", "已复制为富文本"),
        "richText.failed": ("Copy as rich text failed", "复制为富文本失败"),

        // Theme
        "theme.title": ("Preview Theme", "预览主题"),

        // Quick Open
        "quickOpen.placeholder": ("Open file by name…", "按名称打开文件…"),
        "globalSearch.placeholder": ("Search workspace content…", "搜索工作区内容…"),
        "globalSearch.typeToSearch": ("Type to search file contents", "输入以搜索文件内容"),
        "globalSearch.indexing": ("Building index…", "正在构建索引…"),
        "globalSearch.searching": ("Searching…", "搜索中…"),
        "quickOpen.commandPlaceholder": ("Search files and actions…", "搜索文件和操作…"),
        "quickOpen.typeToSearch": ("Type to search files", "输入以搜索文件"),
        "quickOpen.actions": ("Actions", "操作"),
        "quickOpen.files": ("Files", "文件"),
        "quickOpen.toggleFocusMode": ("Toggle Focus Mode", "切换专注模式"),
        "quickOpen.toggleFocusModeDesc": ("Hide surrounding panels and keep the document frontmost", "隐藏周边面板，让文档保持在前景"),
        "quickOpen.toggleSidebar": ("Toggle Sidebar", "切换侧边栏"),
        "quickOpen.toggleSidebarDesc": ("Show or hide the file sidebar", "显示或隐藏文件侧边栏"),
        "quickOpen.toggleEditor": ("Toggle Editor", "切换编辑器"),
        "quickOpen.toggleEditorDesc": ("Show or hide the editor pane", "显示或隐藏编辑器面板"),
        "quickOpen.togglePreview": ("Toggle Preview", "切换预览"),
        "quickOpen.togglePreviewDesc": ("Show or hide the preview pane", "显示或隐藏预览面板"),
        "quickOpen.openInsertPanel": ("Open Insert Panel", "打开插入面板"),
        "quickOpen.openInsertPanelDesc": ("Create documents and reusable templates", "创建文档和可复用模板"),
        "quickOpen.openStylePanel": ("Open Style Panel", "打开样式面板"),
        "quickOpen.openStylePanelDesc": ("Change theme and workspace layout", "调整主题和工作区布局"),
        "quickOpen.openPageInfo": ("Open Page Info", "打开页面信息"),
        "quickOpen.openPageInfoDesc": ("Show metadata for the current document", "显示当前文档的元信息"),
        "quickOpen.openComments": ("Open Comments", "打开评论"),
        "quickOpen.openCommentsDesc": ("Show the document comments panel", "显示文档评论面板"),
        "quickOpen.openSharePanel": ("Open Share Panel", "打开分享面板"),
        "quickOpen.openSharePanelDesc": ("Manage LAN sharing from the right panel", "在右侧面板管理局域网分享"),
        "quickOpen.openSearchResults": ("Open Search Results", "打开搜索结果"),
        "quickOpen.openSearchResultsDesc": ("Show the global search results panel", "显示全局搜索结果面板"),
        "quickOpen.openOutlinePanel": ("Open Outline Panel", "打开大纲面板"),
        "quickOpen.openOutlinePanelDesc": ("Jump between Markdown headings from the right panel", "从右侧面板跳转 Markdown 标题"),
        "quickOpen.openFolder": ("Open Folder…", "打开文件夹…"),
        "quickOpen.openFolderDesc": ("Choose another workspace folder", "选择另一个工作区文件夹"),
        "quickOpen.newDocument": ("New from Template…", "从模板新建…"),
        "quickOpen.newDocumentDesc": ("Create a document in the current workspace", "在当前工作区中创建文档"),
        "quickOpen.cycleTheme": ("Cycle Theme", "切换主题"),
        "quickOpen.cycleThemeDesc": ("Switch to the next preview theme", "切换到下一个预览主题"),
        "quickOpen.exportPDF": ("Export as PDF…", "导出为 PDF…"),
        "quickOpen.exportPDFDesc": ("Export the current preview as PDF", "将当前预览导出为 PDF"),

        // Right panel
        "rightPanel.insert": ("Insert", "插入"),
        "rightPanel.style": ("Style", "样式"),
        "rightPanel.outline": ("Outline", "大纲"),
        "rightPanel.pageInfo": ("Page Info", "页面信息"),
        "rightPanel.comments": ("Comments", "评论"),
        "rightPanel.share": ("Share", "分享"),
        "rightPanel.search": ("Search Results", "搜索结果"),
        "rightPanel.outline.previewNote": ("The preview outline is still shown beside Markdown preview. This panel is reserved for the unified document outline.", "Markdown 预览旁仍显示大纲。此面板将作为统一文档大纲入口。"),
        "rightPanel.outline.emptyTitle": ("No outline", "暂无大纲"),
        "rightPanel.outline.emptyMessage": ("Open a Markdown document to inspect its heading structure.", "打开 Markdown 文档以查看标题结构。"),
        "rightPanel.info.name": ("Name", "名称"),
        "rightPanel.info.path": ("Path", "路径"),
        "rightPanel.info.language": ("Language", "语言"),
        "rightPanel.info.size": ("Size", "大小"),
        "rightPanel.info.words": ("Words", "词数"),
        "rightPanel.info.modified": ("Modified", "已修改"),
        "rightPanel.info.emptyTitle": ("No document selected", "未选择文档"),
        "rightPanel.info.emptyMessage": ("Open a file to see document details.", "打开文件后可查看文档详情。"),
        "rightPanel.comments.emptyTitle": ("No comments yet", "暂无评论"),
        "rightPanel.comments.emptyMessage": ("Add document-level notes here. They are stored locally and stay out of the Markdown file.", "在这里添加文档级备注。内容会保存在本地，不写入 Markdown 文件。"),
        "rightPanel.comments.noDocumentTitle": ("No document selected", "未选择文档"),
        "rightPanel.comments.noDocumentMessage": ("Open a file to add document comments.", "打开文件后可添加文档评论。"),
        "rightPanel.comments.add": ("New Comment", "新评论"),
        "rightPanel.comments.addButton": ("Add Comment", "添加评论"),
        "rightPanel.comments.markResolved": ("Mark Resolved", "标记为已解决"),
        "rightPanel.comments.markOpen": ("Mark Open", "标记为未解决"),
        "rightPanel.search.emptyTitle": ("No search yet", "尚未搜索"),
        "rightPanel.search.emptyMessage": ("Global search results will appear here so they do not compete with Quick Open.", "全局搜索结果将显示在这里，避免与快速打开混在一起。"),
        "rightPanel.search.placeholder": ("Search files and content…", "搜索文件和内容…"),
        "rightPanel.search.noMatchesMessage": ("Try another file name, path, or content query.", "试试其他文件名、路径或正文关键词。"),
        "rightPanel.search.recent": ("Recent", "最近"),
        "rightPanel.search.files": ("Files", "文件"),
        "rightPanel.search.content": ("Content", "内容"),
        "rightPanel.search.scanning": ("Scanning file contents…", "正在扫描文件内容…"),
        "rightPanel.share.message": ("Start LAN sharing to make currently open documents available on the local network.", "启动局域网分享后，可在本地网络访问当前打开的文档。"),
        "rightPanel.insert.message": ("Use existing document creation tools from a stable side panel while editing.", "编辑时可从稳定的侧边面板使用现有文档创建工具。"),

        // Calendar
        "calendar.today": ("Today", "今天"),
        "calendar.tomorrow": ("Tomorrow", "明天"),
        "calendar.allDay": ("All Day", "全天"),
        "calendar.empty": ("No upcoming events", "暂无日程"),
        "calendar.requestAccess": ("Grant Access", "授权访问"),
        "calendar.accessHint": ("Calendar access is required to show your events.", "需要日历访问权限以显示你的日程。"),
    ]

    private static let table3: [String: (en: String, zh: String)] = [
        // Todo
        "todo.noRoot": ("No folder open", "未打开文件夹"),
        "todo.empty": ("No tasks found", "暂无待办"),
        "todo.refresh": ("Refresh tasks", "刷新待办"),

        // Sidebar
        "sidebar.search": ("Search", "搜索"),
        "sidebar.newDocument": ("New Document", "新建文档"),
        "sidebar.allDocs": ("All Docs", "所有文档"),
        "sidebar.recent": ("Recent", "最近"),
        "sidebar.tasks": ("Tasks", "待办"),
        "sidebar.calendar": ("Calendar", "日历"),
        "sidebar.imagine": ("Imagine", "Imagine"),
        "sidebar.sharedWithMe": ("Shared with Me", "与我共享"),
        "sidebar.favorites": ("Favorites", "收藏"),
        "sidebar.favoritesHint": ("Favorite docs for quick access", "收藏文档以便快速访问"),
        "sidebar.folders": ("Folders", "文件夹"),
        "sidebar.tags": ("Tags", "标签"),
        "sidebar.tagsHint": ("Pin keywords here for quick access", "固定关键词标签以便快速访问"),
        "sidebar.newFolder": ("New Folder", "新建文件夹"),
        "menu.preferences": ("Preferences", "偏好设置"),
        "create.folderName": ("Folder name", "文件夹名称"),
        "create.fileName": ("File name", "文件名称"),
        "create.messageFolder": ("Enter a name for the new folder.", "请输入新文件夹的名称。"),
        "create.messageFile": ("Enter a name for the new file.", "请输入新文件的名称。"),
        "rename.title": ("Rename", "重命名"),
        "rename.newName": ("New name", "新名称"),
        "rename.messageFormat": ("Rename \"%@\" to:", "将\"%@\"重命名为："),
        "delete.confirmFormat": ("Are you sure you want to delete \"%@\"?", "确定要删除\"%@\"吗？"),
        "error.createFolderFailed": ("Failed to create folder: %@", "创建文件夹失败：%@"),
        "error.createFileFailed": ("Failed to create file: %@", "创建文件失败：%@"),
        "error.renameFailed": ("Failed to rename: %@", "重命名失败：%@"),
        "error.deleteFailed": ("Failed to delete: %@", "删除失败：%@"),

        // Status bar
        "statusBar.modified": ("Modified", "已修改"),
        "statusBar.saved":    ("Saved", "已保存"),
        "statusBar.cursor":   ("Cursor position", "光标位置"),
        "statusBar.sharing": ("Sharing", "分享中"),
        "statusBar.copyLANLink": ("Copy LAN Link", "复制局域网链接"),
        "statusBar.copyGistLink": ("Copy Gist Link", "复制 Gist 链接"),

        // Tab context menu
        "tab.close": ("Close", "关闭"),
        "tab.closeOthers": ("Close Others", "关闭其他"),
        "tab.closeAll": ("Close All", "关闭全部"),
        "tab.showInFinder": ("Show in Finder", "在 Finder 中显示"),

        // Editor / Preview placeholders
        "editor.selectFile": ("Select a file to edit", "选择一个文件进行编辑"),
        "editor.placeholder": ("Start writing…", "开始写作…"),
        "preview.empty": ("Preview", "预览"),
        "preview.findPlaceholder": ("Find in Preview", "在预览中查找"),
        "preview.findNoResults": ("No results", "无结果"),
        "toc.level": ("Level %d", "%d 级"),

        // Settings
        "settings.tab.general": ("General", "通用"),
        "settings.tab.editor": ("Editor", "编辑器"),
        "settings.tab.sharing": ("Publish & Share", "发布分享"),
        "settings.section.preview": ("Preview", "预览"),
        "settings.fontSize": ("Font Size", "字体大小"),
        "settings.section.save": ("Save", "保存"),
        "settings.section.spotlight": ("System Search", "系统搜索"),
        "settings.spotlightContent": ("Index document text in Spotlight", "将文档正文索引进 Spotlight"),
        "settings.desc.spotlightContent": ("Off by default — only file names are indexed. Turning this on makes document text searchable system-wide (and by other apps).",
                                           "默认关闭——只索引文件名。开启后正文可被系统全局搜索（以及其他 App）检索到。"),
        "settings.section.about": ("About", "关于"),
        "settings.version": ("Version", "版本"),
        "settings.checkUpdates": ("Check for Updates…", "检查更新…"),
        "settings.autoCheckUpdates": ("Automatically check for updates", "自动检查更新"),
        "settings.desc.autoCheckUpdates": ("Check for new versions in the background", "后台自动检查新版本"),
        "settings.autoSave": ("Auto-Save", "自动保存"),
        "settings.interval": ("Interval", "间隔"),
        "settings.secondsFormat": ("%d sec", "%d 秒"),
        "settings.section.launchLayout": ("Default Layout on Launch", "启动时默认布局"),
        "settings.showSidebar": ("Show Sidebar", "显示侧边栏"),
        "settings.showEditor": ("Show Editor", "显示编辑器"),
        "settings.showPreview": ("Show Preview", "显示预览"),
        "settings.section.lanShare": ("LAN Sharing", "局域网分享"),
        "settings.port": ("Port", "端口"),
        "settings.portHint": ("Port used for LAN preview sharing, default 8899", "局域网预览分享使用的端口，默认 8899"),
        "settings.section.language": ("Language", "语言"),
        "settings.section.assistant": ("AI Assistant", "AI 助手"),
        "settings.desc.theme": ("Color scheme for the editor and preview", "编辑器与预览的配色主题"),
        "settings.desc.accent": ("App-wide highlight color for buttons and selection", "全局按钮与选中态的强调色"),
        "settings.desc.language": ("Interface display language", "界面显示语言"),
        "settings.desc.fontSize": ("Base text size in the rendered preview", "预览渲染的基础字号"),
        "settings.section.editor": ("Editor", "编辑器"),
        "settings.editorFont": ("Font", "字体"),
        "settings.desc.editorFont": ("Body font for the editor; code spans always use monospace", "编辑器正文字体，代码片段始终使用等宽字体"),
        "settings.editorFont.system": ("System Default", "系统默认"),
        "settings.editorFontSize": ("Font Size", "字号"),
        "settings.desc.editorFontSize": ("Editor text size in points", "编辑器文字大小（磅）"),
        "settings.desc.autoSave": ("Automatically save modified documents on a timer", "按间隔自动保存已修改的文档"),
        "settings.section.export": ("Export", "导出"),
        "settings.exportPreflight": ("Pre-export check", "导出前检查"),
        "settings.desc.exportPreflight": ("Scan for dead links, missing images and markup issues before exporting", "导出前扫描死链、缺失图片与格式问题"),
        "settings.desc.provider": ("Where assistant replies are generated", "助手回复的生成来源"),
        "settings.language": ("Language", "语言"),
        "lang.system": ("System", "跟随系统"),
    ]

    private static let table4: [String: (en: String, zh: String)] = [
        // AppError descriptions
        "error.openFailed": ("Couldn't open \"%@\": %@", "无法打开\"%@\"：%@"),
        "error.saveFailed": ("Couldn't save \"%@\": %@", "无法保存\"%@\"：%@"),
        "error.deleteFailed2": ("Couldn't delete \"%@\": %@", "无法删除\"%@\"：%@"),
        "error.renameFailed2": ("Couldn't rename \"%@\": %@", "无法重命名\"%@\"：%@"),
        "error.createFailed": ("Couldn't create \"%@\": %@", "无法创建\"%@\"：%@"),
        "error.accessDenied": ("Access denied to \"%@\".", "无权访问\"%@\"。"),
        "error.previewResourceMissing": ("Preview resource missing: %@.", "缺少预览资源：%@。"),
        "error.exportFailed": ("Export to %@ failed: %@.", "导出为 %@ 失败：%@。"),
        "error.unknown": ("unknown error", "未知错误"),
        "error.sessionRestoreFailed": ("Couldn't restore previous session: %@.", "无法恢复上次会话：%@。"),
        "error.icloudNotDownloaded": ("\"%@\" hasn't been downloaded from iCloud yet. Download started — please try again shortly.", "\"%@\" 尚未从 iCloud 下载，已开始下载，请稍后重试。"),
        "error.icloudReadFailed": ("Couldn't read iCloud file \"%@\": %@", "无法读取 iCloud 文件\"%@\"：%@"),

        // Export errors
        "export.err.noWebView": ("Preview is not available.", "预览不可用。"),
        "export.err.js": ("Export failed (JS): %@", "导出失败（JS）：%@"),
        "export.err.pdf": ("PDF export failed: %@", "PDF 导出失败：%@"),
        "export.err.image": ("Image export failed: %@", "图片导出失败：%@"),

        // Document action bar
        "action.export": ("Export", "导出"),
        "action.share": ("Share", "分享"),
        "action.present": ("Present", "放映"),

        // Tab share / publish actions
        "tab.shareViaLAN": ("Share via LAN", "通过局域网分享"),
        "tab.copyShareURL": ("Copy Share URL", "复制分享链接"),
        "tab.stopSharing": ("Stop Sharing", "停止分享"),
        "tab.publishToGitHub": ("Publish to GitHub Gist", "发布到 GitHub Gist"),

        // GitHub Gist
        "github.gist.copyLink": ("Copy Gist Link", "复制 Gist 链接"),
        "github.gist.openInBrowser": ("Open in Browser", "在浏览器中打开"),
        "github.gist.publishing": ("Publishing…", "正在发布…"),
        "github.gist.republish": ("Republish to GitHub", "重新发布到 GitHub"),

        // AI inline-replace ambiguous match
        "ai.error.replaceAmbiguous": (
            "The selected text appears multiple times in the document. Please apply the change manually.",
            "所选文本在文档中出现了多次，无法精确定位。请手动应用修改。"
        ),

        // FileService errors
        "error.file.accessDenied": ("Access denied to the file", "无权访问该文件"),
        "error.file.readFailed": ("Failed to read file: %@", "读取文件失败：%@"),
        "error.file.writeFailed": ("Failed to write file: %@", "写入文件失败：%@"),
        "error.file.alreadyExists": ("A file named “%@” already exists", "已存在同名文件“%@”"),

        // Image paste / drop
        "image.pasteFailed": ("Couldn't save the image: %@", "图片保存失败：%@"),
        "image.dropFailed": ("Couldn't import %d image(s)", "%d 张图片导入失败"),

        // Local history
        "menu.localHistory": ("File History…", "文件历史…"),
        "history.title": ("File History", "文件历史"),
        "history.snapshotCount": ("%d snapshot(s)", "%d 份快照"),
        "history.empty": ("No snapshots yet", "暂无历史快照"),
        "history.emptyMessage": ("A snapshot is recorded each time you save this file.", "每次保存该文件时都会记录一份快照。"),
        "history.comparePrompt": ("Select one snapshot to compare it with the current content, or two to compare them.", "选择一份快照与当前内容对比，或选两份互相对比。"),
        "history.current": ("Current", "当前内容"),
        "history.restore": ("Restore This Snapshot", "恢复此快照"),
        "history.restoreHint": ("Restoring keeps the current content as a new snapshot first.", "恢复前会先把当前内容另存为新快照。"),
        "history.restored": ("Restored from snapshot (undo with ⌘Z)", "已从快照恢复（可用 ⌘Z 撤销）"),
        "history.readFailed": ("Couldn't read snapshot: %@", "读取快照失败：%@"),

        // TemplateStore errors
        "template.error.cannotDeleteBuiltin": ("Built-in templates cannot be deleted", "内置模板不可删除"),
        "template.error.invalidName": ("Template name is invalid", "模板名称无效"),
        "template.error.writeFailed": ("Failed to save template: %@", "保存模板失败：%@"),

        // Software update panel
        "update.title.checking": ("Checking for Updates", "检查更新"),
        "update.title.permission": ("Automatically Check for Updates", "自动检查更新"),
        "update.title.found": ("New Version Available", "发现新版本"),
        "update.title.downloading": ("Downloading Update", "正在下载更新"),
        "update.title.extracting": ("Preparing Update", "正在准备更新"),
        "update.title.installing": ("Installing Update", "正在安装更新"),
        "update.title.ready": ("Update Ready", "更新已就绪"),
        "update.title.notFound": ("You're Up to Date", "已是最新版本"),
        "update.title.failed": ("Update Failed", "更新失败"),
        "update.checking": ("Checking for updates…", "正在检查更新…"),
        "update.permissionPrompt": ("Allow MEditor to check for new versions once a day? The check only reads the version number and sends no personal information.",
                                    "允许 MEditor 每天自动检查一次新版本吗？检查结果仅包含版本号，不会发送任何个人信息。"),
        "update.foundNoNotes": ("A new version is available.", "新版本已发布，建议更新。"),
        "update.downloading": ("Downloading…", "正在下载…"),
        "update.extracting": ("Extracting the package…", "正在解压安装包…"),
        "update.installing": ("Installing — the app will relaunch automatically…", "正在安装，应用将自动重启…"),
        "update.readyMessage": ("Download complete. Relaunch to apply.", "下载完成，重启后生效。"),
        "update.notFoundMessage": ("Version %@ is up to date.", "当前版本 %@ 已是最新。"),
        "update.disallow": ("Don't Allow", "不允许"),
        "update.allowAutoCheck": ("Allow Automatic Checks", "允许自动检查"),
        "update.skipVersion": ("Skip This Version", "跳过此版本"),
        "update.remindLater": ("Remind Me Later", "稍后提醒"),
        "update.updateNow": ("Update Now", "立即更新"),
        "update.later": ("Later", "稍后"),
        "update.restartNow": ("Restart Now", "立即重启"),

        // AI onboarding
        "onboarding.title.ready": ("AI Is Ready", "AI 已就绪"),
        "onboarding.title.setup": ("Let the Agent Help You Write", "让 Agent 帮你写文档"),
        "onboarding.subtitle": ("Tidy meeting notes, draft weekly reports, rewrite text — right inside your documents. Pick a way to start:",
                                "整理会议纪要、起草周报、改写文字，都直接发生在你的文档里。选择一种方式开始："),
        "onboarding.otherProvider": ("Set Up Another AI Provider", "配置其他 AI 服务"),
        "onboarding.otherProviderSub": ("OpenAI / DeepSeek / Kimi / GLM… bring your own API key",
                                        "OpenAI / DeepSeek / Kimi / GLM… 填 API Key"),
        "onboarding.skip": ("Skip for Now", "暂时跳过"),
        "onboarding.useClaudeCode": ("Use Claude Code", "使用 Claude Code"),
        "onboarding.recommended": ("Recommended", "推荐"),
        "onboarding.detecting": ("Looking for Claude Code on this Mac…", "正在检测本机 Claude Code…"),
        "onboarding.detected": ("Found: %@", "已检测到：%@"),
        "onboarding.notDetected": ("Not found. If Claude Code is installed, you can use it with no API key.",
                                   "未检测到。已安装 Claude Code 可免 Key 零配置使用"),
        "onboarding.useDirectly": ("Use It Now (No API Key Needed)", "直接使用（免 API Key）"),
        "onboarding.verifying": ("Verifying connection…", "正在验证连接…"),
        "onboarding.connectFailed": ("Connection failed: %@", "连接失败：%@"),
        "onboarding.connectOK": ("Connected — you're good to go", "连接正常，可以开始对话"),
        "onboarding.demoTitle": ("See What the Agent Can Do", "看看 Agent 能做什么"),
        "onboarding.demoSub": ("The agent tidies up a sample meeting note (written to a temp folder — your files stay untouched)",
                               "Agent 自动整理一篇示例会议记录（写在临时目录，不动你的文件）"),
        "onboarding.startChat": ("Start Chatting", "直接开始对话"),

        // Beautify sheet
        "beautify.title": ("Beautify HTML", "HTML 美化"),
        "beautify.token.accent": ("Accent", "强调色"),
        "beautify.token.bg": ("Background", "背景色"),
        "beautify.token.text": ("Text", "文字色"),
        "beautify.token.font": ("Font", "字体"),
        "beautify.token.width": ("Content Width", "内容宽度"),
        "beautify.token.fontMono": ("Code Font", "代码字体"),
        "beautify.resetTokens": ("Reset to Defaults", "恢复默认"),
        "beautify.customize": ("Customize Style", "自定义样式"),
        "beautify.tokensModified": ("%d modified", "%d 项已修改"),
        "beautify.generating": ("Generating HTML…", "正在生成 HTML…"),
        "beautify.emptyHint": ("Pick a theme, then hit Generate", "选择主题后点击「生成」"),
        "beautify.streaming": ("Generating…", "生成中…"),
        "beautify.stop": ("Stop", "停止"),
        "beautify.generate": ("Generate", "生成"),
        "beautify.regenerate": ("Regenerate", "重新生成"),
        "beautify.save": ("Save HTML", "保存 HTML"),
        "beautify.saved": ("Saved %@", "已保存 %@"),
        "beautify.savedGeneric": ("Saved", "已保存"),

        // Claude file prompt toast
        "toast.claudeFileCreated": ("Claude created a file", "Claude 生成了文件"),
        "toast.open": ("Open", "打开"),
        "toast.ignore": ("Ignore", "忽略"),

        // Sidebar sections / loose-file context menu
        "sidebar.userDocs": ("User Documents", "用户文档"),
        "sidebar.appDocs": ("App Documents", "App 文档"),
        "sidebar.looseFiles": ("Loose Files", "散文件"),
        "sidebar.copyPath": ("Copy Path", "复制路径"),
        "sidebar.removeFromList": ("Remove from List", "从列表移除"),

        // AppState toasts
        "toast.noWorkspace": ("Open a workspace first", "请先打开一个工作区"),
        "toast.todoAdded": ("To-do added to %@", "已新增待办到 %@"),
        "toast.reloadedFromDisk": ("Reloaded from disk: %@", "已从磁盘更新：%@"),

        // AI settings
        "ai.apiKey.localOnly": ("Stored only on this Mac", "仅存储在本机"),
    ]

    // MARK: table5 — 本地化收尾批（diff 审阅 / 日历 / 待办 / 设置 / 模板 / 统计 / toast）
    private static let table5: [String: (en: String, zh: String)] = [
        // Common additions
        "common.add": ("Add", "添加"),

        // Diff review overlay
        "diff.original": ("Original", "原文"),
        "diff.aiGeneratedHTML": ("AI-Generated HTML", "AI 生成 HTML"),
        "diff.aiAction": ("AI %@", "AI %@"),
        "diff.review": ("Review Changes", "对比审阅"),
        "diff.refinePlaceholder": ("Keep refining, e.g. \"shorter\"", "继续调整，如：再短一点"),
        "diff.refineHelp": ("Run another AI pass on the result with this instruction", "按此指令对 AI 结果再改一轮"),
        "diff.pendingCount": ("%d pending", "%d 处待处理"),
        "diff.allHandled": ("All handled", "全部已处理"),
        "diff.acceptAll": ("Accept All", "全部接受"),
        "diff.skipAll": ("Skip All", "全部跳过"),
        "diff.closeHelp": ("Close (Esc)", "关闭 (Esc)"),
        "diff.accept": ("✓ Accept", "✓ 接受"),
        "diff.skip": ("✗ Skip", "✗ 跳过"),

        // Calendar main view / sidebar
        "calendar.mode.month": ("Month", "月"),
        "calendar.mode.week": ("Week", "周"),
        "calendar.fmt.monthTitle": ("MMMM yyyy", "yyyy年M月"),
        "calendar.fmt.weekStart": ("MMM d", "M月d日"),
        "calendar.fmt.weekEnd": ("MMM d", "M月d日"),
        "calendar.fmt.dayHeader": ("EEEE, MMM d", "M月d日 EEEE"),
        "calendar.newEvent": ("New Event", "新建事件"),
        "calendar.new": ("New", "新建"),
        "calendar.refresh": ("Refresh", "刷新"),
        "calendar.refreshHint": ("Refresh Calendars", "刷新日历"),
        "calendar.noEvents": ("No events", "无事件"),
        "calendar.moreEvents": ("+%d more", "+%d 个"),
        "calendar.serviceName": ("System Calendar", "系统日历"),

        // Calendar events
        "event.untitled": ("(No title)", "（无标题）"),
        "event.title": ("Title", "标题"),
        "event.start": ("Start", "开始"),
        "event.end": ("End", "结束"),
        "event.date": ("Date", "日期"),
        "event.calendar": ("Calendar", "日历"),
        "event.notes": ("Notes", "备注"),
        "event.saveFailed": ("Couldn't save the event — check calendar access", "保存失败，请检查日历权限"),
        "event.deleteConfirm": ("Delete this event?", "确认删除此事件？"),

        // To-do main view / sidebar / context menu
        "todo.add": ("Add To-do", "新增待办"),
        "todo.addFromSelection": ("Add as To-do", "新增为待办"),
        "todo.sectionPending": ("To-do (%d)", "待办 (%d)"),
        "todo.sectionDone": ("Done (%d)", "已完成 (%d)"),
        "todo.addedToast": ("To-do added", "已新增待办"),
        "todo.unknownFile": ("Unknown file", "未知文件"),
        "todo.contentLabel": ("Task", "待办内容"),
        "todo.inputPlaceholder": ("What needs to be done?", "输入待办事项…"),
        "todo.willWrite": ("Will be saved to:", "将写入："),

        // Document stats popover / status bar chip
        "stats.chipChars": ("%@ chars", "%@字"),
        "stats.chipWords": ("%dw", "%dw"),
        "stats.title": ("Document Stats", "文档统计"),
        "stats.cjk": ("CJK Characters", "汉字"),
        "stats.words": ("Words", "英文词"),
        "stats.chars": ("Characters", "字符"),
        "stats.lines": ("Lines", "行数"),
        "stats.readingTime": ("Reading Time", "阅读时间"),
        "stats.readingMinutes": ("~%d min", "约 %d 分钟"),

        // Beautify
        "beautify.disabledToast": ("Beautify is turned off in Settings", "「美化」功能已在设置中关闭"),
        "beautify.alreadyClean": ("Markdown is already tidy", "Markdown 已经很规整了"),
        "beautify.label": ("Beautify", "美化"),
        "beautify.overwriteTitle": ("File exists — overwrite?", "文件已存在，确认覆盖？"),
        "beautify.existingFile": ("Existing File", "现有文件"),
        "beautify.newFile": ("New File", "新文件"),
        "beautify.sizeDelta": ("Size change: %@", "大小变化：%@"),
        "beautify.overwrite": ("Overwrite", "覆盖保存"),

        // Preview action bar
        "actionbar.expand": ("Expand action bar", "展开操作栏"),
        "actionbar.collapse": ("Collapse action bar", "收起操作栏"),

        // LAN share toasts
        "share.stopped": ("Sharing stopped", "已停止分享"),
        "share.startedCopied": ("Sharing on · link copied", "已开启分享 · 链接已复制"),
        "share.started": ("LAN sharing on", "已开启局域网分享"),

        // Settings
        "settings.tab.plugins": ("Skills", "技能"),
        "settings.tab.integrations": ("Integrations", "集成"),
        "settings.tab.about": ("About", "关于"),
        "settings.section.appearance": ("Appearance", "外观"),
        "settings.softwareUpdate": ("Software Update", "软件更新"),
        "settings.desc.checkUpdates": ("Check for a new version of MEditor", "检查 MEditor 是否有新版本"),
        "settings.about.website": ("Website", "官方网站"),
        "settings.test.okModel": ("✓ Connected (model: %@)", "✓ 连接成功（model: %@）"),
        "settings.test.failed": ("✗ Connection failed: %@", "✗ 连接失败：%@"),
        "settings.test.okCLI": ("✓ Connected (CLI available)", "✓ 连接成功（CLI 可用）"),

        // Paths settings
        "paths.group": ("Document Paths", "文档路径"),
        "paths.userDocs": ("User Documents", "用户文档"),
        "paths.userDocsHint": ("Files under this folder appear in the sidebar", "侧边栏显示此目录下的文件"),
        "paths.appDocs": ("App Documents (output)", "App 文档（输出目录）"),
        "paths.appDocsHint": ("Default save location for Beautify HTML and similar features", "HTML 美化等功能的默认保存位置"),
        "paths.choose": ("Choose Folder", "选择文件夹"),
        "paths.clear": ("Clear", "清除"),

        // Template picker sections
        "templates.sectionMarkdown": ("Document Templates", "文档模板"),
        "templates.sectionHTML": ("HTML Themes", "HTML 主题"),
        "templates.sectionMine": ("My Templates", "我的模板"),

        // Built-in template names / descriptions (user-visible in the picker)
        "template.prd": ("Product PRD", "产品需求 PRD"),
        "template.prdDesc": ("Background · user stories · feature list", "背景・用户故事・功能清单"),
        "template.bugReport": ("Bug Report", "Bug 报告"),
        "template.bugReportDesc": ("Symptoms · repro steps · analysis", "现象・复现步骤・分析结论"),
        "template.readingNotes": ("Reading Notes", "读书笔记"),
        "template.readingNotesDesc": ("Ideas · quotes · thoughts · actions", "观点・摘抄・想法・行动"),
        "template.releaseNotes": ("Release Notes", "发布说明"),
        "template.releaseNotesDesc": ("Features · improvements · fixes · upgrade guide", "新功能・改进・修复・升级指引"),
        "template.retrospective": ("Retrospective", "项目复盘"),
        "template.retrospectiveDesc": ("Data review · root causes · action items", "数据回顾・根因分析・行动项"),
        "template.htmlTufte": ("Tufte Academic", "Tufte 学术风"),
        "template.htmlTufteDesc": ("Serif · academic style", "衬线字体・学术风格"),
        "template.htmlCraft": ("Craft Modern", "Craft 现代风"),
        "template.htmlCraftDesc": ("Card layout · clean and modern", "卡片布局・现代简洁"),
        "template.htmlDark": ("Dark Code", "Dark 代码风"),
        "template.htmlDarkDesc": ("Dark theme · tech style", "深色主题・技术风格"),
        "template.htmlLanding": ("Landing Page", "产品落地页"),
        "template.htmlLandingDesc": ("Hero · feature cards · CTA", "Hero・特性卡片・CTA"),
        "template.htmlReport": ("Data Report", "数据报告页"),
        "template.htmlReportDesc": ("KPI cards · detail tables · conclusions", "KPI 卡片・明细表・结论"),
        "template.htmlResume": ("Resume", "个人简历"),
        "template.htmlResumeDesc": ("Print-friendly · clean professional layout", "打印友好・简洁专业版式"),

        // Plugin manager (load errors surface in Settings → Plugins)
        "plugin.error.parse": ("%@: couldn't parse SKILL.md (%@)", "%@：无法解析 SKILL.md（%@）"),
        "plugin.error.bookmark": ("ID %@: stale bookmark — re-add the skill", "ID %@：书签失效，请重新添加技能"),
        "plugin.defaultTrigger": ("Action", "操作"),

        // AI chat transcript notices
        "ai.notice.truncatedHistory": ("⚠️ Conversation history was too long — kept only the last 10 turns.",
                                       "⚠️ 对话历史过长，已自动保留最近 10 轮对话。"),
        "ai.notice.evictedToolResults": ("%d earlier tool result(s) omitted (re-read with a tool if needed)",
                                         "%d 条早期工具读取内容已省略（如仍需可用工具重新读取）"),
        "ai.notice.evictedToolArgs": ("%d earlier tool call argument(s) omitted (re-read with a tool if needed)",
                                      "%d 条早期工具调用参数已省略（如仍需可用工具重新读取）"),
        "ai.notice.droppedMessages": ("earliest messages trimmed", "最早的部分对话已裁剪"),
        "ai.notice.contextBudget": ("ℹ️ Context over budget: %@.", "ℹ️ 上下文超出预算：%@。"),
        "ai.notice.separator": ("; ", "；"),
        "ai.notice.error": ("Error: %@", "错误：%@"),
        "ai.notice.outputTruncated": ("⚠️ Output hit the length limit and may be truncated.",
                                      "⚠️ 输出达到长度上限，内容可能被截断。"),
        "ai.notice.partialFailure": ("⚠️ Some actions didn't complete:\n", "⚠️ 部分操作未能完成：\n"),

        // AI provider presets / CLI errors
        "ai.preset.ollama": ("Ollama · Local", "Ollama · 本地"),
        "ai.error.cliGeneric": ("Claude CLI failed", "Claude CLI 执行失败"),
        "ai.error.cliTimeout": ("CLI request timed out (%ds) — process terminated", "CLI 请求超时（%ds），进程已终止"),
        "ai.error.cliMacOnly": ("Claude CLI is only supported on macOS", "Claude CLI 仅支持 macOS"),
        "ai.error.cliToolBlocked": ("Claude CLI blocked a tool call: %@", "Claude CLI 拦下了一次工具调用：%@"),

        // Agent errors
        "agentErr.argsNotObject": ("Arguments aren't a JSON object", "参数不是 JSON 对象"),
        "agentErr.argsNotUTF8": ("Arguments aren't valid UTF-8 text", "参数不是有效的 UTF-8 文本"),
        "agentErr.noDocument": ("No document open", "没有打开的文档"),
        "agentErr.noWorkspace": ("No workspace open", "没有打开工作区"),
        "agentErr.toolNotFound": ("Tool not found: %@", "工具未找到：%@"),
        "agentErr.maxSteps": ("Agent exceeded the step limit", "Agent 执行步数超限"),
        "agentErr.parse": ("Parse error: %@", "解析错误：%@"),
        "agentErr.execution": ("Execution error: %@", "执行错误：%@"),

        // Agent demo flow (onboarding)
        "demo.notConfigured": ("AI isn't configured yet — finish the setup above first", "尚未配置 AI，请先完成上方配置"),
        "demo.createFailed": ("Couldn't create the demo file: %@", "演示文件创建失败：%@"),

        // Welcome / misc toasts
        "welcome.recent": ("Recent", "最近打开"),
        "toast.presentationResourcesMissing": ("Presentation resources missing — can't export", "演讲模式资源缺失，无法导出"),

        // Plugin settings tab（补齐 WIP 中已引用未登记的 key）
        "plugin.loadFailed": ("Some skills failed to load", "部分技能加载失败"),
        "plugin.builtinGroup": ("Built-in Skills (%d/%d on)", "内置技能（%d/%d 已启用）"),
        "plugin.myGroup": ("My Skills (%d on)", "我的技能（%d 已启用）"),
        "plugin.emptyTitle": ("No custom skills yet", "还没有自定义技能"),
        "plugin.emptyHint": ("Add a SKILL.md file or a skills folder", "添加 SKILL.md 文件或技能目录"),
        "plugin.add": ("Add Skill", "添加技能"),
        "plugin.reload": ("Reload", "重新加载"),
        "plugin.reloadHint": ("Re-scan all skill files", "重新扫描全部技能文件"),
        "plugin.gallery": ("Skill Gallery", "技能库"),
        "plugin.galleryHint": ("Curated picks", "精选推荐"),
        "plugin.install": ("Install", "安装"),
        "plugin.installing": ("Installing…", "安装中…"),
        "plugin.installed": ("Installed", "已安装"),
        "plugin.installFailed": ("Install failed: %@", "安装失败：%@"),
        "plugin.builtinBadge": ("Built-in", "内置"),
        "plugin.openInApp": ("Open in MEditor", "在 App 内打开"),
        "plugin.showInFinder": ("Show in Finder", "在 Finder 中显示"),
        "plugin.removeSkill": ("Remove skill", "移除技能"),
        "plugin.pickTitle": ("Choose a SKILL.md file or a skills folder", "选择 SKILL.md 文件或技能目录"),
        "plugin.added": ("Added %d skills", "已添加 %d 个技能"),
        "plugin.noSkillFound": ("No SKILL.md found in the selection", "所选内容中没有找到 SKILL.md"),

        // AI settings tab（补齐 WIP 中已引用未登记的 key）
        "settings.ai.cliModelHint": ("Model used by the local Claude CLI", "本地 Claude CLI 使用的模型"),
        "settings.ai.cliModelDefault": ("Default", "默认"),
        "settings.ai.cliModelOpus": ("Opus 4.5", "Opus 4.5"),
        "settings.ai.cliModelSonnet": ("Sonnet 4.5", "Sonnet 4.5"),
        "settings.ai.cliModelHaiku": ("Haiku 4.5", "Haiku 4.5"),
        "settings.ai.connectionTest": ("Connection Test", "连接测试"),
        "settings.ai.connectionTestHint": ("Send a test request to verify the configuration", "发送一条测试请求验证配置是否可用"),
        "settings.ai.testing": ("Testing…", "测试中…"),
        "settings.ai.testConnection": ("Test Connection", "测试连接"),
        "settings.ai.agentModel": ("Agent Model", "Agent 模型"),
        "settings.ai.agentModelHint": ("Model for agent runs; falls back to the chat model when empty",
                                       "Agent 执行使用的模型，留空则跟随聊天模型"),
        "settings.ai.agentMaxSteps": ("Agent Max Steps", "Agent 最大步数"),
        "settings.ai.agentMaxStepsHint": ("Maximum tool-call rounds per agent run", "单次 Agent 运行允许的最大工具调用轮数"),
        "settings.ai.inlineModel": ("Inline Edit Model", "行内编辑模型"),
        "settings.ai.inlineModelHint": ("Model for selection-based inline edits; falls back to the chat model when empty",
                                        "圈选行内编辑使用的模型，留空则跟随聊天模型"),
        "settings.ai.modelFallback": ("Follow chat model", "跟随聊天模型"),
        "settings.ai.sectionPersonal": ("Personalization", "个性化"),
        "settings.ai.customPrompt": ("Custom System Prompt", "自定义系统提示词"),
        "settings.ai.customPromptHint": ("Injected into every conversation — your personal preferences",
                                         "每次对话都会注入，用于表达你的个人偏好"),
        "settings.ai.claudeIntegration": ("Claude Code Integration", "Claude Code 集成"),
        "settings.ai.monitorFiles": ("Watch Claude Code Sessions", "监听 Claude Code 会话"),
        "settings.ai.monitorFilesHint": ("Detect files created by Claude Code and offer to open them",
                                         "发现 Claude Code 生成的文件并提示打开"),
        "settings.ai.monitorDir": ("Session Directory", "会话目录"),
        "settings.ai.monitorDirHint": ("Directory where Claude Code stores session transcripts", "Claude Code 存放会话记录的目录"),
        "settings.ai.choose": ("Choose…", "选择…"),
        "settings.ai.fileTypes": ("File Types", "文件类型"),
        "settings.ai.fileTypesHint": ("Comma-separated extensions to watch, e.g. md,txt", "要监听的扩展名，逗号分隔，如 md,txt"),
        "settings.ai.monitorDirInfo": ("Watching: %@", "正在监听：%@"),
        "settings.ai.pickClaudeDir": ("Choose the Claude session directory", "选择 Claude 会话目录"),
        "settings.ai.clearCustom": ("Clear", "清除"),
        "settings.ai.pickPresetModel": ("Pick from preset models", "从预设模型中选择"),

        // AI 设置分层（首屏只留一个决策：本机 CLI 还是自己的 key；其余收进「高级」）
        "settings.ai.quickStart": ("Quick Start", "快速开始"),
        "settings.ai.quickCLITitle": ("Local Claude CLI (zero-config)", "本机 Claude CLI（零配置）"),
        "settings.ai.recommended": ("Recommended", "推荐"),
        "settings.ai.cliDetecting": ("Checking for a local Claude CLI…", "正在检测本机 Claude CLI…"),
        "settings.ai.cliDetected": ("Found at %@ — reuses your local Claude Code login",
                                    "已检测到：%@（复用本机 Claude Code 登录）"),
        "settings.ai.cliNotDetected": ("No local Claude CLI found — set the path manually in Advanced",
                                       "未检测到本机 Claude CLI——可在「高级」里手动指定路径"),
        "settings.ai.quickAPIKeyTitle": ("Use your own API key", "使用自己的 API key"),
        "settings.ai.quickAPIKeyHint": ("Any OpenAI-compatible endpoint (OpenAI, DeepSeek, Ollama…)",
                                        "任意 OpenAI 兼容接口（OpenAI、DeepSeek、Ollama…）"),
        "settings.ai.advanced": ("Advanced", "高级"),
        "settings.ai.advancedHint": ("Provider, endpoint, models, personalization & integrations",
                                     "提供方、接口地址、模型、个性化与集成"),

        // AI onboarding 演示（无 key 离线预演 + 设置页重看入口）
        "onboarding.demoSubOffline": ("No setup needed — a scripted offline preview: the agent tidies a messy meeting note",
                                      "无需配置——离线预演：Agent 把凌乱会议记录整理成结构化纪要"),
        "demo.openFailed": ("Couldn't open the demo document", "打不开演示文档"),
        "demo.simulatedDone": ("Offline demo finished — connect an AI provider to do this on your own documents",
                               "离线演示完成——接入 AI 后即可在你自己的文档上这样运行"),
        "settings.ai.replayDemo": ("Onboarding Demo", "入门演示"),
        "settings.ai.replayDemoLabel": ("Run the Agent Demo Again", "重看 Agent 演示"),
        "settings.ai.replayDemoHint": ("Replays the 30-second meeting-note tidy-up in a temp folder; runs offline when AI isn't configured",
                                       "在临时目录重跑 30 秒会议纪要整理演示；未配置 AI 时离线预演"),
        "settings.ai.replayDemoAction": ("Run Demo", "运行演示"),

        // MCP 服务器（外部 Agent 接入）
        "settings.ai.mcp": ("MCP Server", "MCP 服务器"),
        "settings.ai.mcpHint": ("Let external agents (Claude Desktop, Cursor…) operate on your workspace via MCP — 12 tools, same sandbox as the in-app Agent",
                                "让 Claude Desktop / Cursor 等外部 Agent 通过 MCP 协议操作你的工作区（12 个工具，与内置 Agent 同一沙箱）"),
        "settings.ai.mcpConfigLabel": ("Claude Desktop config", "Claude Desktop 配置"),
        "settings.ai.mcpCopy": ("Copy", "复制"),
        "settings.ai.mcpCopied": ("MCP config copied", "MCP 配置已复制"),

        // MCP 客户端（内置 Agent 作为 MCP client 连接外部工具服务器）
        "settings.ai.mcpClient": ("MCP Client", "MCP 客户端"),
        "settings.ai.mcpClientLabel": ("External tool servers", "外部工具服务器"),
        "settings.ai.mcpClientHint": ("Give the in-app Agent tools from external MCP servers. Config: ~/.meditor/mcp.json. A project's <workspace>/.meditor/mcp.json is ignored until you explicitly trust it below (it can run shell commands).",
                                      "让内置 Agent 调用外部 MCP server 的工具。配置文件：~/.meditor/mcp.json；项目自带的 <工作区>/.meditor/mcp.json 默认忽略，需在下方显式信任后启用（它可执行 shell 命令）。"),
        "settings.ai.mcpClientEmpty": ("No MCP servers configured", "尚未配置 MCP server"),
        "settings.ai.mcpClientOpenConfig": ("Open Config File", "打开配置文件"),
        "settings.ai.mcpClientReconnect": ("Reconnect", "重新连接"),
        "settings.ai.mcpClientToolsCount": ("%d tools", "%d 个工具"),
        "settings.ai.mcpClientConnected": ("Connected", "已连接"),
        "settings.ai.mcpClientFailed": ("Connection failed", "连接失败"),
        "settings.ai.mcpClientDisconnected": ("Not connected", "未连接"),
        "settings.ai.mcpClientConnecting": ("Connecting…", "连接中…"),
        "settings.ai.mcpClientConfigIssue": ("Config issue: %@", "配置问题：%@"),
        "settings.ai.mcpWorkspaceConfig": ("Project MCP config (.meditor/mcp.json)", "项目 MCP 配置（.meditor/mcp.json）"),
        "settings.ai.mcpWorkspaceTrust": ("Trust & Enable", "信任并启用"),
        "settings.ai.mcpWorkspaceRevoke": ("Revoke Trust", "撤销信任"),
        "settings.ai.mcpWorkspaceHint": ("This project ships an MCP config that runs shell commands as soon as the Agent starts. It is ignored until you trust it; if the file changes, trust is revoked automatically.",
                                          "该项目自带 MCP 配置，Agent 一启动就会执行其中的命令。未授权前一律忽略；配置文件变更后授权自动失效，需重新确认。"),

        // 技能导入/导出（用户间分享技能）
        "plugin.import": ("Import", "导入"),
        "plugin.importFromFile": ("Import from File…", "从文件导入…"),
        "plugin.importFromURL": ("Import from URL…", "从 URL 导入…"),
        "plugin.importURLHint": ("Paste a https:// link to a shared skill .md file",
                                 "粘贴分享的技能 .md 文件链接（仅支持 https://）"),
        "plugin.importPickTitle": ("Choose a skill .md file to import", "选择要导入的技能 .md 文件"),
        "plugin.exportSkill": ("Export Skill…", "导出技能…"),
        "skill.import.doneRenamed": ("Imported as \"%@\" — the original name was already in use",
                                     "已导入为「%@」——原名已被占用"),
        "skill.export.failed": ("Export failed: %@", "导出失败：%@"),
        "skill.transfer.error.empty": ("The file is empty", "文件为空"),
        "skill.transfer.error.noFrontmatter": ("Not a skill file: missing the --- frontmatter block",
                                               "不是技能文件：缺少 --- frontmatter 块"),
        "skill.transfer.error.noName": ("Not a skill file: frontmatter has no valid name",
                                        "不是技能文件：frontmatter 缺少有效的 name"),
        "skill.transfer.error.unsafeName": ("Skill name \"%@\" is not a safe folder name",
                                            "技能名「%@」不能用作文件夹名"),
        "skill.transfer.error.emptyBody": ("Skill content is empty", "技能正文为空"),
        "skill.transfer.error.tooLarge": ("Skill file exceeds the %d KB limit", "技能文件超过 %d KB 上限"),
        "skill.transfer.error.invalidURL": ("Invalid URL", "URL 无效"),
        "skill.transfer.error.httpsOnly": ("Only https:// links are allowed", "仅允许 https:// 链接"),
        "skill.transfer.error.download": ("Download failed: %@", "下载失败：%@"),
        "skill.transfer.error.contentType": ("The link did not return a Markdown/text file (%@)",
                                             "链接返回的不是 Markdown/文本文件（%@）"),
        "skill.transfer.error.notUTF8": ("The file is not valid UTF-8 text", "文件不是有效的 UTF-8 文本"),

        // AI usage / cost transparency（prompt 缓存命中与会话累计成本）
        "ai.usage.cachedHit": ("cached %@", "缓存命中 %@"),
        "ai.usage.sessionTotal": ("Total %@ tokens", "累计 %@ tokens"),

        // 改前 diff 审阅（agent 写操作默认主流程）
        "settings.ai.autoApplyWrites": ("Auto-apply Agent Changes", "自动应用 Agent 改动"),
        "settings.ai.autoApplyWritesHint": ("Write files after a simple confirmation instead of reviewing each change in the diff view first",
                                            "写操作只弹确认条直接落盘，不先进入逐块 diff 审阅"),
        "diff.totalCount": ("%d changes", "共 %d 处改动"),

        // Agent 断点续传（运行失败中断后从中断处继续）
        "ai.resume.continue": ("Continue from Interruption", "从中断处继续"),
        "ai.resume.continueHint": ("Resume the interrupted run — completed tool steps are kept, only the remaining work is redone",
                                   "带着已完成的步骤从中断处继续运行，不从头重来"),

        // Agent 写后自检（AI 是唯一作者：写工具内容生效后自动跑本地诊断并分级报告）
        "ai.selfcheck.title": ("Post-write Self-check", "写后自检"),
        "ai.selfcheck.toast": ("Self-check found %d issue(s) — see AI panel", "自检发现 %d 个问题——见 AI 面板"),
        "ai.selfcheck.summary": ("Found %d issue(s): %d auto-fixable, %d need manual review",
                                 "发现 %d 个问题：%d 个可一键修复，%d 个需人工确认"),
        "ai.selfcheck.fix": ("Fix with Agent (%d)", "一键修复（%d）"),
        "ai.selfcheck.dismiss": ("Dismiss", "忽略"),

        // 端侧智能（Apple Foundation Models，macOS 26+）：设置页分区与可用状态
        "settings.ai.onDevice": ("On-Device Intelligence (Apple Intelligence)", "端侧智能（Apple 智能）"),
        "settings.ai.onDevicePasteCleanup": ("Clean Pasted Content", "粘贴内容智能清理"),
        "settings.ai.onDevicePasteCleanupHint": ("Use the on-device model to remove ads, tracking parameters and promo blocks from pasted web content; the original text is kept if cleanup fails — nothing is sent over the network",
                                                 "粘贴网页内容时用端侧模型去除广告、追踪参数和推广段落；失败时保留原文，全程不联网"),
        "settings.ai.onDeviceStatus": ("On-Device Model Status", "端侧模型状态"),
        "ai.onDevice.available": ("Available", "可用"),
        "ai.onDevice.unsupportedOS": ("Requires macOS 26 or later", "需要 macOS 26 或更高版本"),
        "ai.onDevice.deviceNotEligible": ("This device doesn't support Apple Intelligence", "此设备不支持 Apple 智能"),
        "ai.onDevice.notEnabled": ("Apple Intelligence isn't enabled in System Settings", "Apple 智能未启用（请在系统设置中开启）"),
        "ai.onDevice.modelNotReady": ("Model is downloading…", "模型资源下载中…"),
        "ai.onDevice.unknown": ("Unavailable", "暂不可用"),

        // 后台 Agent 任务（脱离聊天 UI 独立运行；toast + 系统通知 + 任务列表）
        "ai.background.section": ("Background Tasks", "后台任务"),
        "ai.background.running": ("Running…", "运行中…"),
        "ai.background.runHelp": ("Run in background — keep editing and chatting while it works",
                                  "在后台运行该任务，运行期间可继续编辑和聊天"),
        "ai.background.limitReached": ("%d background tasks already running — wait for one to finish",
                                       "已有 %d 个后台任务在运行，请等待完成后再发起"),
        "ai.background.done": ("Background task done: %@", "后台任务完成：%@"),
        "ai.background.failed": ("Background task failed: %@ — %@", "后台任务失败：%@——%@"),
        "ai.background.cancelled": ("Background task cancelled: %@", "后台任务已取消：%@"),
        "ai.background.cancelTask": ("Cancel this task", "取消该任务"),
        "ai.background.notificationTitle": ("MEditor Background Task", "MEditor 后台任务"),

        // 定时任务（cron 触发的后台 Agent 任务；设置页「定时任务」区 + 触发失败提示）
        "settings.ai.scheduledTasks": ("Scheduled Tasks", "定时任务"),
        "settings.ai.scheduledTasksLabel": ("Cron-triggered Agent runs", "定时触发的 Agent 任务"),
        "settings.ai.scheduledTasksHint": ("Run an Agent prompt on a cron schedule as a background task. Config: ~/.meditor/schedules.json plus <workspace>/.meditor/schedules.json (same-name entries in the workspace file win)",
                                           "按 cron 表达式定时把一段指令交给后台 Agent 运行。配置文件：~/.meditor/schedules.json 与 <工作区>/.meditor/schedules.json（同名条目以工作区为准）"),
        "settings.ai.scheduledTasksEmpty": ("No scheduled tasks configured", "尚未配置定时任务"),
        "settings.ai.scheduledTasksOpenConfig": ("Open Config File", "打开配置文件"),
        "settings.ai.scheduledTasksNext": ("Next: %@", "下次触发：%@"),
        "settings.ai.scheduledTasksGlobal": ("global", "全局"),
        "settings.ai.scheduledTasksWorkspace": ("workspace", "工作区"),
        "settings.ai.scheduledTasksAutoApprove": ("auto-approve", "免确认"),
        "settings.ai.scheduledTasksConfigIssue": ("Config issue: %@", "配置问题：%@"),
        "ai.schedule.notConfigured": ("AI is not configured — scheduled task \"%@\" skipped",
                                      "未配置 AI——定时任务「%@」已跳过"),
    ]

    static let table: [String: (en: String, zh: String)] = {
        var t = table0
        t.merge(table1) { _, new in new }
        t.merge(table2) { _, new in new }
        t.merge(table3) { _, new in new }
        t.merge(table4) { _, new in new }
        t.merge(table5) { _, new in new }
        return t
    }()
}
