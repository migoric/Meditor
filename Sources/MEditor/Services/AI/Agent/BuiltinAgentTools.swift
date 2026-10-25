import Foundation

// MARK: - Tool Registry

/// 所有内建工具的注册表。
/// 工具实现分布在 Tools/ 子目录下，按功能域分组：
///   DocumentTools.swift  — 读写/搜索当前文档
///   WorkspaceTools.swift — 文件/目录操作
///   EditorTools.swift    — 编辑器交互（光标、打开文件）
enum BuiltinAgentTools {
    static let all: [any AgentTool] = {
        var tools: [any AgentTool] = [
            // Document
            ReadDocumentTool(),
            WriteDocumentTool(),
            PatchDocumentTool(),
            SearchDocumentTool(),
            // Workspace
            ListFilesTool(),
            ReadFileTool(),
            CreateFileTool(),
            WriteFileTool(),
            CreateDirectoryTool(),
            SearchWorkspaceTool(),
            // Editor
            InsertAtCursorTool(),
            OpenFileTool(),
            GetHTMLTemplateTool(),
            // Skills（渐进披露：按名加载技能全文，详见 AgentSkillStore）
            LoadSkillTool(),
        ]
        // Shell (script-based skills; gated by per-session user confirmation)
#if os(macOS)
        tools.append(RunCommandTool())   // iOS 无 Process 子进程能力，不注册 shell 工具
        // 项目记忆：跨会话的约定/术语/决策。落盘到工作区的 MEDITOR.md，
        // 注入侧见 AIChatCoordinator.systemContext。iOS 端暂不注册——
        // 记忆文件与检索层还没进共享源码清单（见 docs/ai-roadmap.md M1 的边界）。
        tools.append(SaveMemoryTool())
        tools.append(RecallMemoryTool())
#endif
        return tools
    }()

    static func tool(named name: String) -> (any AgentTool)? {
        all.first { $0.spec.name == name }
    }
}
