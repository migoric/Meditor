import Foundation

// MARK: - DocumentAuthoringProfile

/// 一种文档类型的写作档案：首轮给模型看什么、追加什么策略。
///
/// **为什么不拆两个 `AgentRunner`**：Runner 里的三级停滞检测、并行只读调度、代际防竞态、
/// 上下文预算裁剪、diff 审阅、写后自检，全部与文档类型无关。复制两份等于两份 bug 各修
/// 一遍，而真正的差异只有三件事——上下文怎么给、工具给哪些、策略怎么说。
/// 所以这里只做一个纯值配置（无 IO、无状态），Runner 一行不改。
///
/// **为什么没有「工具白名单」**（设计稿 §3.1 原本打算有，实现时推翻了）：
/// 全部文档工具都带可选的 `filename` 参数（`read_document(filename:)` 等），
/// 也就是说它们的**作用对象与当前 tab 的类型无关** —— 在 `.md` tab 里让 agent
/// 「把这份报告导出成 HTML」是常见请求，按 tab 类型把 HTML 工具藏起来会直接
/// 让这类请求无解。工具的取舍因此交给已有的 `AgentToolBudget`（按本轮原话对
/// MCP 工具打分裁剪），不在这里再加一层会误伤的过滤。
struct DocumentAuthoringProfile: Sendable, Equatable {

    enum Kind: String, Sendable, Equatable {
        case markdown, html, plain
    }

    /// 首轮注入的上下文形态。
    enum ContextMode: Sendable, Equatable {
        /// 今天的全部行为：预算感知的全文摘录（`DocumentContextExcerpt`）。
        case fullDocument
        /// 标题树 + 行区间 + 字数，让模型按需 `read_section`。
        case markdownOutline
        /// 结构树 + CSS 折叠提示，让模型按需 `read_node` / `read_style`。
        case htmlStructure
    }

    let kind: Kind
    /// 追加到 system prompt **稳定段**的操作策略（每轮不变 ⇒ 可进 prompt cache 前缀）。
    let guidance: String

    var contextMode: ContextMode {
        switch kind {
        case .markdown: return .markdownOutline
        case .html:     return .htmlStructure
        case .plain:    return .fullDocument
        }
    }

    /// 按扩展名分派。未知 / 无扩展名一律 `plain` —— 老用户的行为不受影响，
    /// 也是整套设计的回滚开关（把 `.md` 也映射到 plain 即可退回旧行为）。
    static func resolve(fileExtension: String?) -> DocumentAuthoringProfile {
        switch fileExtension?.lowercased() {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "html", "htm":                    return .html
        default:                               return .plain
        }
    }

    /// 按文件名（可含路径）分派。
    static func resolve(fileName: String?) -> DocumentAuthoringProfile {
        guard let fileName, !fileName.isEmpty else { return .plain }
        let ext = (fileName as NSString).pathExtension
        return resolve(fileExtension: ext.isEmpty ? nil : ext)
    }

    // MARK: - 三个档案

    /// 默认档案 = 今天的全部行为，逐字节不变。
    static let plain = DocumentAuthoringProfile(kind: .plain, guidance: "")

    static let markdown = DocumentAuthoringProfile(
        kind: .markdown,
        guidance: """

        ## 当前文档是 Markdown：先看结构，再定位

        首轮你拿到的是**大纲**（每节的标题、行区间、字数），不是全文——写作任务的绝大多数
        是「改某一节」「检查结构」「统一某个说法」，全文是每轮都要重付的钱。

        - 要改某节：先 `read_section("<标题或编号>")` 只读那一节，不要 `read_document` 全文。
        - 整节改写：`rewrite_section("<标题或编号>", 新内容)`。它只碰这一节，结构上不可能
          误伤别的节；小范围措辞改动用 `patch_document`（字面匹配，改动更精确）。
        - 标题重名（两节都叫「小结」）时用完整路径消歧：`rewrite_section("三、实现 > 小结", …)`；
          工具会把所有同名节的行区间列出来，别猜。
        - 需要通读全篇才能判断的请求（「有没有前后矛盾」）才逐节 `read_section`——这是该付的成本，
          但只在这类请求上付。
        """
    )

    static let html = DocumentAuthoringProfile(
        kind: .html,
        guidance: """

        ## 当前文档是 HTML：正文与样式分开看

        首轮你拿到的是**结构树**（可寻址的选择器）与「CSS 已折叠」的提示，正文与 `<style>`
        都不在上下文里。

        - 定位：`html_outline()` 给结构树；`read_node("<selector>")` 取某个节点的 outerHTML。
          选择器支持 `#id`、`.class`、`tag#id`、`tag.class`、`tag`。
        - 改正文：用 `patch_document`（字面匹配）或 `read_node` 取到节点后精确替换，**不要**
          为了改一句话 `write_document` 整份重写——HTML 里带着几千字符的 CSS，逐字复制必出错。
        - 改样式：`patch_style` 追加 CSS 规则（级联，后面的覆盖前面的）；换 class 用
          `set_node_class`，不必改正文。
        - 只有用户明确要看样式时才 `read_style`——它会把整段 CSS 灌进历史（约 1.5K token）。
        - 新建 HTML 文件：用 `write_html_with_template(template:body:)`，只写语义 body，
          模板与 `<style>` 由宿主展开。**不要**再用 `get_html_template` 抄全文（2.7K token，且复制会出错）。
        """
    )
}
