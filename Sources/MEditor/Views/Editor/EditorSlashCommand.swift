import SwiftUI
import AppKit

struct SlashCommandExpansion {
    let text: String
    let cursorOffset: Int?
}

// MARK: - AI 命令类型

enum SlashAIAction {
    /// 执行注册表中的 AI 命令（argument 为命令后输入的参数，可为空）。
    /// 命令的 prompt preset / 作用范围 / 输出去向全部定义在 AISlashCommandRegistry。
    case command(AISlashCommand, argument: String)
}

struct SlashCommandItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let aliases: [String]
    let keywords: [String]
    /// 普通命令：插入这段文本。AI 命令时为 nil。
    let expansion: SlashCommandExpansion?
    /// AI 命令的注册表 id（AISlashCommandRegistry）；非 AI 命令为 nil。
    let aiCommandID: String?

    static func == (lhs: SlashCommandItem, rhs: SlashCommandItem) -> Bool {
        lhs.id == rhs.id
    }

    /// 是否是 AI 驱动的命令
    var isAICommand: Bool { aiCommandID != nil }

    /// 对应的注册表条目（AI 命令）。
    var aiCommand: AISlashCommand? {
        aiCommandID.flatMap { AISlashCommandRegistry.command(id: $0) }
    }

    /// 菜单显示标题：AI 命令走注册表本地化文案（随 UI 语言切换），普通命令用静态 title。
    var displayTitle: String { aiCommand?.title ?? title }
    /// 菜单显示说明（同上）。
    var displaySubtitle: String { aiCommand?.subtitle ?? subtitle }

    // 普通命令便利初始化（保持展参为非可选，向后兼容）
    init(title: String, subtitle: String, icon: String,
         aliases: [String], keywords: [String],
         expansion: SlashCommandExpansion) {
        self.title = title; self.subtitle = subtitle; self.icon = icon
        self.aliases = aliases; self.keywords = keywords
        self.expansion = expansion
        self.aiCommandID = nil
    }

    // AI 命令初始化：元数据全部来自注册表
    init(aiCommand cmd: AISlashCommand) {
        self.title = cmd.id; self.subtitle = ""   // 仅兜底；显示走 displayTitle/displaySubtitle
        self.icon = cmd.icon
        self.aliases = cmd.aliases; self.keywords = cmd.keywords
        self.expansion = nil
        self.aiCommandID = cmd.id
    }
}

/// Handles slash command menu: matching, display, and expansion.
/// Owned by EditorCoordinator; textView is set via the coordinator's didSet.
final class SlashCommandHandler {
    weak var textView: NSTextView?

    private var slashPopover: NSPopover?
    private var slashQueryRange: NSRange?
    private var slashItems: [SlashCommandItem] = []
    private var slashSelectedIndex = 0

    /// True while a slash expansion is being inserted, so delegate callbacks are ignored.
    private(set) var isApplyingCommand = false

    /// AI 命令触发回调：主程序提供，处理真实的 AI 请求。
    /// 参数：(action, contextText, insertionRange)
    var onAIAction: ((SlashAIAction, String, NSRange) -> Void)?

    var isMenuVisible: Bool {
        slashPopover?.isShown == true && !slashItems.isEmpty
    }

    /// 当前位置是否处于「带参数 AI 命令」语境（如「/ask 问题」「/polish 更正式」）。
    /// 用于空格键放行：这类命令的空格是参数分隔符，不能像其他命令那样触发提交。
    func isArgumentContext(in textView: NSTextView, at location: Int) -> Bool {
        guard let ctx = slashContext(in: textView, at: location) else { return false }
        let word = String(ctx.command.split(separator: " ", maxSplits: 1).first ?? "")
        return AISlashCommandRegistry.command(forAlias: word)?.takesArgument == true
    }

    // MARK: - Command catalogue

    static let allCommands: [SlashCommandItem] = staticCommands + aiCommands

    /// 静态插入命令（展开为固定文本）。
    static let staticCommands: [SlashCommandItem] = [
        SlashCommandItem(
            title: "Heading 1",
            subtitle: "Large section title",
            icon: "textformat.size.larger",
            aliases: ["/h1", "/heading1", "/title"],
            keywords: ["heading", "title"],
            expansion: SlashCommandExpansion(text: "# ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Heading 2",
            subtitle: "Medium section title",
            icon: "textformat.size",
            aliases: ["/h2", "/heading2"],
            keywords: ["heading", "section"],
            expansion: SlashCommandExpansion(text: "## ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Heading 3",
            subtitle: "Small section title",
            icon: "textformat",
            aliases: ["/h3", "/heading3"],
            keywords: ["heading", "subsection"],
            expansion: SlashCommandExpansion(text: "### ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Todo",
            subtitle: "Checklist item",
            icon: "checklist",
            aliases: ["/todo", "/task"],
            keywords: ["task", "checkbox", "checklist"],
            expansion: SlashCommandExpansion(text: "- [ ] ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Bullet List",
            subtitle: "Unordered list item",
            icon: "list.bullet",
            aliases: ["/bullet", "/bulleted"],
            keywords: ["list", "unordered"],
            expansion: SlashCommandExpansion(text: "- ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Numbered List",
            subtitle: "Ordered list item",
            icon: "list.number",
            aliases: ["/numbered", "/num"],
            keywords: ["list", "ordered"],
            expansion: SlashCommandExpansion(text: "1. ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Quote",
            subtitle: "Block quote",
            icon: "quote.opening",
            aliases: ["/quote"],
            keywords: ["blockquote", "callout"],
            expansion: SlashCommandExpansion(text: "> ", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Divider",
            subtitle: "Horizontal rule",
            icon: "minus",
            aliases: ["/hr", "/divider"],
            keywords: ["horizontal", "rule", "separator"],
            expansion: SlashCommandExpansion(text: "---\n", cursorOffset: nil)
        ),
        SlashCommandItem(
            title: "Code Block",
            subtitle: "Fenced code block",
            icon: "curlybraces.square",
            aliases: ["/code"],
            keywords: ["fence", "pre", "snippet"],
            expansion: SlashCommandExpansion(text: "```\n\n```", cursorOffset: 4)
        )
    ]

    /// AI 命令：全部来自注册表（含 /ask、/polish、/outline、/translate、/summary、
    /// /fix、/table 等），菜单只消费注册表。原静态 /table 骨架由 AI table 命令的
    /// 空目标兜底承接（空行插入两列骨架）。
    static let aiCommands: [SlashCommandItem] =
        AISlashCommandRegistry.all.map { SlashCommandItem(aiCommand: $0) }

    // MARK: - Public interface (called by EditorCoordinator)

    func applyIfNeeded(in textView: NSTextView, at location: Int) -> Bool {
        guard let ctx = slashContext(in: textView, at: location),
              let item = Self.allCommands.first(where: { $0.aliases.contains(ctx.command) }) else { return false }
        return applyCommand(item, in: textView, range: ctx.range)
    }

    func updateMenu(in textView: NSTextView) {
        guard !isApplyingCommand,
              let ctx = slashContext(in: textView, at: textView.selectedRange().location) else {
            closeMenu(); return
        }
        let matches = filteredCommands(for: ctx.command)
        guard !matches.isEmpty else { closeMenu(); return }
        slashQueryRange = ctx.range
        slashItems = matches
        slashSelectedIndex = min(slashSelectedIndex, matches.count - 1)
        showMenu(relativeTo: ctx.range, in: textView)
    }

    func moveSelection(_ delta: Int) {
        guard !slashItems.isEmpty else { return }
        slashSelectedIndex = min(max(0, slashSelectedIndex + delta), slashItems.count - 1)
        if let tv = textView {
            showMenu(relativeTo: slashQueryRange ?? tv.selectedRange(), in: tv)
        }
    }

    func commitSelection() -> Bool {
        guard let tv = textView,
              !slashItems.isEmpty,
              slashSelectedIndex < slashItems.count,
              let range = slashQueryRange else { return false }
        return applyCommand(slashItems[slashSelectedIndex], in: tv, range: range)
    }

    func closeMenu() {
        slashPopover?.close()
        slashPopover = nil
        slashQueryRange = nil
        slashItems = []
        slashSelectedIndex = 0
    }

    /// Filter commands by a slash-prefixed query string (e.g. "/head").
    func filteredCommands(for command: String) -> [SlashCommandItem] {
        let query = String(command.dropFirst()).lowercased()
        guard !query.isEmpty else { return Self.allCommands }
        // 「/cmd 参数」形式：空格后的是参数内容，不参与命令匹配
        let matchQuery = String(query.split(separator: " ", maxSplits: 1).first ?? "")
        return Self.allCommands.filter { item in
            if item.aliases.contains(where: { $0.dropFirst().hasPrefix(matchQuery) }) { return true }
            // AI 命令的标题/说明走注册表本地化文案（随 UI 语言切换）
            if item.displayTitle.lowercased().contains(matchQuery) { return true }
            if item.displaySubtitle.lowercased().contains(matchQuery) { return true }
            return item.keywords.contains { $0.lowercased().contains(matchQuery) }
        }
    }

    // MARK: - Private helpers

    private func slashContext(in textView: NSTextView, at location: Int) -> (range: NSRange, command: String)? {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0, selectedRange.location == location else { return nil }

        let nsText = textView.string as NSString
        guard location <= nsText.length else { return nil }

        var lineStart = 0
        if location > 0 {
            let prefixRange = NSRange(location: 0, length: location)
            let newline = nsText.range(of: "\n", options: .backwards, range: prefixRange)
            if newline.location != NSNotFound { lineStart = newline.location + 1 }
        }

        let typedLength = location - lineStart
        guard typedLength >= 1 else { return nil }
        let typed = nsText.substring(with: NSRange(location: lineStart, length: typedLength))
        let indentLength = typed.prefix { $0 == " " || $0 == "\t" }.count
        let command = String(typed.dropFirst(indentLength)).lowercased()
        guard command.hasPrefix("/") else { return nil }
        // 带参数命令（/ask、/polish 等）允许「/cmd 参数」带空格的形式（参数是命令的
        // 一部分）；其他命令含空白即视为已脱离斜杠命令语境
        if command.dropFirst().contains(where: { $0.isWhitespace }) {
            let word = String(command.split(separator: " ", maxSplits: 1).first ?? "")
            guard AISlashCommandRegistry.command(forAlias: word)?.takesArgument == true else { return nil }
        }

        let commandStart = lineStart + indentLength
        return (NSRange(location: commandStart, length: location - commandStart), command)
    }

    private func showMenu(relativeTo range: NSRange, in textView: NSTextView) {
        let popover = slashPopover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentSize = NSSize(width: 260, height: min(280, 48 + slashItems.count * 43))
        popover.contentViewController = NSHostingController(rootView: SlashCommandMenuView(
            items: slashItems,
            selectedIndex: slashSelectedIndex
        ))
        slashPopover = popover
        let rect = caretRect(for: range, in: textView)
        if popover.isShown { popover.positioningRect = rect }
        else { popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY) }
    }

    private func caretRect(for range: NSRange, in textView: NSTextView) -> NSRect {
        guard let window = textView.window else { return textView.visibleRect }
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty else { return textView.visibleRect }
        let windowRect = window.convertFromScreen(screenRect)
        var viewRect = textView.convert(windowRect, from: nil)
        viewRect.size.width = max(2, viewRect.size.width)
        viewRect.size.height = max(18, viewRect.size.height)
        return viewRect
    }

    private func applyCommand(_ item: SlashCommandItem, in textView: NSTextView, range: NSRange) -> Bool {
        closeMenu()

        // AI 命令：删除命令文本，获取上下文，回调触发
        if item.isAICommand {
            guard let aiCommand = item.aiCommand else { return false }
            // 「/cmd 参数」的参数提取必须在删除命令文本之前（range 覆盖命令+参数全段）
            let rawCommand = (textView.string as NSString).substring(with: range)

            isApplyingCommand = true
            textView.insertText("", replacementRange: range)   // 删除 /command（含参数）
            isApplyingCommand = false

            let insertionLoc = textView.selectedRange().location
            // 全文快照（删除命令后）：执行器的目标段落定位与 diff original 都以它为准，
            // 不能读 tab.content（可能还停在含命令文本的防抖窗口里）
            let documentText = textView.string

            // 参数部分（删除前提取，保留大小写）；无参数回退空串
            let argument: String
            if let space = rawCommand.firstIndex(of: " ") {
                argument = String(rawCommand[rawCommand.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                argument = ""
            }
            onAIAction?(.command(aiCommand, argument: argument), documentText,
                        NSRange(location: insertionLoc, length: 0))
            return true
        }

        // 普通插入命令
        guard let exp = item.expansion else { return false }
        isApplyingCommand = true
        textView.insertText(exp.text, replacementRange: range)
        let len = (exp.text as NSString).length
        let loc = range.location + (exp.cursorOffset ?? len)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        isApplyingCommand = false
        return true
    }
}

// MARK: - Slash menu views

struct SlashCommandMenuView: View {
    let items: [SlashCommandItem]
    let selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "command")
                    .font(.system(size: 10, weight: .semibold))
                Text("Insert")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                Spacer()
                Text("↑↓ ↵")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 5)

            Divider().opacity(0.45)

            // 命令库变大后列表可滚动，键盘选择时滚动跟随选中项
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SlashCommandMenuRow(item: item, isSelected: index == selectedIndex)
                                .id(index)
                        }
                    }
                    .padding(5)
                }
                .onChange(of: selectedIndex) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(width: 260, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

struct SlashCommandMenuRow: View {
    let item: SlashCommandItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.appAccent : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Text(item.displaySubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(item.aliases.first ?? "")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.selectionFill : Color.clear)
        )
    }
}
