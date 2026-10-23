import Foundation

// MARK: - AgentToolBudget

/// 每轮请求的**工具定义预算**。
///
/// 背景：内置 16 个工具的定义不大，但每个 MCP server 会带进一批远端工具，而工具
/// 定义是**每轮重发**的（历史越长、轮次越多，这笔固定开销被付的次数越多）。挂三四个
/// server 之后很容易到 40+ 条，其中绝大多数与当前这句话无关。
///
/// 两条硬约束决定了这里必须保守：
/// 1. **藏掉唯一能用的工具比多花 token 更糟**——模型没法猜到自己没有的工具，
///    用户看到的是「它说做不到」。
/// 2. 裁剪必须是**确定性**的：同样的输入必须给同样的工具集，否则同一句话两次运行
///    行为不同，没法复现、也没法写测试。
///
/// 所以策略是「只在有把握时裁」：
/// - 总条数没超上限 ⇒ 原样放行（绝大多数人的日常）。
/// - 超了，且用户这句话**命中了某些外部工具**（名字/描述里出现查询词）⇒ 只保留命中的
///   前 N 个，其余折叠，并在系统提示里点名折叠了什么。
/// - 超了但**一个都没命中**（典型：中文提问 vs 英文工具描述）⇒ 不裁。没有信号时
///   裁剪等于瞎猜，宁可多付 token。
enum AgentToolBudget {

    /// 一次请求里工具定义的总条数上限（含内置）。
    static let defaultMaxTools = 32

    /// 一次裁剪的结果。
    struct Selection {
        /// 实际发给模型的工具（保持传入顺序，避免打乱 wire 字节）。
        let tools: [any AgentTool]
        /// 被折叠的工具（可能为空）。
        let dropped: [any AgentTool]
        /// 给系统提示的一句话说明（nil = 没裁，不必提）。
        let notice: String?

        var didTrim: Bool { !dropped.isEmpty }
    }

    // MARK: - Select

    /// - Parameters:
    ///   - tools: 候选工具（内置 + MCP，后者注册名以 `mcp__` 开头）。
    ///   - query: 用户这一轮的原话，用于相关性打分。
    ///   - maxTools: 总条数上限，测试可注入。
    static func select(
        tools: [any AgentTool],
        query: String,
        maxTools: Int = defaultMaxTools
    ) -> Selection {
        guard tools.count > maxTools, maxTools > 0 else {
            return Selection(tools: tools, dropped: [], notice: nil)
        }

        let builtin = tools.filter { !isExternal($0.spec.name) }
        let external = tools.filter { isExternal($0.spec.name) }

        // 外部工具数量本就在余量内 ⇒ 没什么可裁的。
        let room = max(0, maxTools - builtin.count)
        guard external.count > room else {
            return Selection(tools: tools, dropped: [], notice: nil)
        }

        let keywords = tokenize(query)
        // 没有任何可判定的信号 ⇒ 不裁（见类型注释的第 2 条约束）。
        guard !keywords.isEmpty else {
            return Selection(tools: tools, dropped: [], notice: nil)
        }

        let scored = external.map { tool -> (tool: any AgentTool, score: Int) in
            (tool, score(tool.spec, keywords: keywords))
        }
        guard scored.contains(where: { $0.score > 0 }) else {
            return Selection(tools: tools, dropped: [], notice: nil)
        }

        // 命中数排序，同分按名字（确定性；`sort` 不稳定，必须给全序）。
        let ranked = scored.sorted {
            $0.score == $1.score ? $0.tool.spec.name < $1.tool.spec.name : $0.score > $1.score
        }
        let keepNames = Set(ranked.prefix(room).map(\.tool.spec.name))

        // 保留顺序与传入一致：wire 字节稳定，缓存命中率不受影响。
        let kept = tools.filter { !isExternal($0.spec.name) || keepNames.contains($0.spec.name) }
        let droppedNames = external.map(\.spec.name).filter { !keepNames.contains($0) }.sorted()

        return Selection(
            tools: kept,
            dropped: tools.filter { droppedNames.contains($0.spec.name) },
            notice: notice(droppedNames: droppedNames)
        )
    }

    // MARK: - 打分

    /// 外部工具的判据：MCP 注册名前缀。内置工具一律不参与裁剪——
    /// 它们定义小、且是文档编辑的主路径。
    static func isExternal(_ name: String) -> Bool {
        name.hasPrefix(MCPTool.namePrefix)
    }

    /// 查询词拆解：按非字母数字切分（含中文标点），小写，去重，丢弃单字符。
    ///
    /// 中文提问很常见而 MCP 工具描述基本是英文，所以这里不指望中文命中——命中不了
    /// 就走「不裁」分支，这正是设计意图（见类型注释）。
    static func tokenize(_ query: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
        let parts = query.lowercased().components(separatedBy: separators)
        return Set(parts.filter { $0.count >= 2 })
    }

    /// 命中数：每个查询词在「工具名 + 描述」里出现过就 +1。
    /// 工具名单独再 +1 —— 名字比描述更能代表用途（用户常直接说工具名）。
    static func score(_ spec: AgentToolSpec, keywords: Set<String>) -> Int {
        let name = spec.name.lowercased()
        let haystack = name + " " + spec.description.lowercased()
        var total = 0
        for kw in keywords {
            guard haystack.contains(kw) else { continue }
            total += name.contains(kw) ? 2 : 1
        }
        return total
    }

    // MARK: - 提示文案

    private static func notice(droppedNames: [String]) -> String? {
        guard !droppedNames.isEmpty else { return nil }
        let list = droppedNames.joined(separator: ", ")
        return "\n\nTool budget: this run exposes \(droppedNames.count) MCP tool(s) too many to send every turn, "
            + "so the following are folded out for now: \(list). "
            + "If the task really needs one of them, say so explicitly and ask the user to narrow the request; "
            + "do not pretend the capability does not exist."
    }
}
