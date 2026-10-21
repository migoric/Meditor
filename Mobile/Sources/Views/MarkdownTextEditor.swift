import SwiftUI
import UIKit

/// Markdown 编辑器：UITextView 的 UIViewRepresentable 封装。
/// SwiftUI TextEditor 拿不到光标、不支持 inputAccessoryView，这里换 UIKit 实现：
/// 纸墨样式（16.5 等宽 / 松烟墨 / 宣纸底 / 行距 6），绑定写入仍走 DocumentStore.applyManualEdit
/// 的既有通道（防抖自动保存语义不变），并挂一条横滑的 Markdown 键盘工具条。
/// UITextView 子类：选中文本时 editMenu 增加「AI 优化」（iOS 16+）。
private class EditorTextView: UITextView {
    var onAIRefine: ((String) -> Void)?

    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu {
        var actions = suggestedActions
        if let text = text(in: textRange), !text.isEmpty {
            let aiAction = UIAction(title: "AI 优化", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.onAIRefine?(text)
            }
            actions.insert(aiAction, at: 0)
        }
        return UIMenu(children: actions)
    }
}

struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// 阅读设置字号系数：等宽字号跟随缩放。
    var fontScale: CGFloat = 1
    /// 选中文本后点击「AI 优化」的回调：参数为选中的文字。
    var onAIRefine: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = UIColor(PaperTheme.paper)
        // 与原 SwiftUI TextEditor 的 padding 对齐：左右 ~14pt、顶部 ~14pt 留白
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 14,
                                                   bottom: PaperTheme.Spacing.bottomBarInset + 4,
                                                   right: 14)
        textView.keyboardDismissMode = .interactive
        // Markdown 源码编辑：关掉智能引号 / 破折号，避免代码符号被改写
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true

        textView.onAIRefine = { [onAIRefine] in onAIRefine?($0) }
        context.coordinator.textView = textView
        context.coordinator.fontScale = fontScale
        context.coordinator.setStyledText(textView, text, selection: NSRange(location: 0, length: 0))
        textView.inputAccessoryView = MarkdownToolbarAccessory(
            onAction: { [weak coordinator = context.coordinator] action in
                coordinator?.perform(action)
            },
            onDismiss: { [weak textView] in
                textView?.resignFirstResponder()
            }
        )
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // 用户输入经 textViewDidChange 已写回绑定，这里只同步外部变更
        //（AI 写工具 / 打开文件 / 撤销），字符串相同则跳过以免打断输入与光标。
        // 字号系数变化（阅读设置）同样要整段重挂样式。
        let scaleChanged = context.coordinator.fontScale != fontScale
        context.coordinator.fontScale = fontScale
        guard scaleChanged || textView.text != text else { return }
        let selection = textView.selectedRange
        context.coordinator.setStyledText(textView, text, selection: selection)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        weak var textView: UITextView?
        /// 当前生效的阅读设置字号系数（updateUIView 同步，变化时整段重挂样式）。
        var fontScale: CGFloat = 1

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        // MARK: 纸墨样式

        private var editorAttributes: [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            return [
                .font: UIFont.monospacedSystemFont(ofSize: 16.5 * fontScale, weight: .regular),
                .foregroundColor: UIColor(PaperTheme.ink),
                .paragraphStyle: paragraph,
            ]
        }

        /// 程序化写入（工具条 / 外部变更）：整段重挂样式，尽量保住光标与滚动位置。
        func setStyledText(_ textView: UITextView, _ newText: String, selection: NSRange) {
            let offset = textView.contentOffset
            let attributes = editorAttributes
            textView.attributedText = NSAttributedString(string: newText, attributes: attributes)
            textView.typingAttributes = attributes
            let length = newText.utf16.count
            let location = min(selection.location, length)
            textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            textView.layoutIfNeeded()
            textView.contentOffset = offset
        }

        // MARK: 工具条动作

        func perform(_ action: MarkdownToolbarAction) {
            guard let textView else { return }
            let nsText = textView.text as NSString
            let selection = textView.selectedRange
            let result: (text: String, selection: NSRange)
            switch action {
            case .h1:        result = Self.applyLineRule(nsText, selection, rule: .heading1)
            case .h2:        result = Self.applyLineRule(nsText, selection, rule: .heading2)
            case .bold:      result = Self.wrapInline(nsText, selection, prefix: "**", suffix: "**")
            case .list:      result = Self.applyLineRule(nsText, selection, rule: .list)
            case .task:      result = Self.applyLineRule(nsText, selection, rule: .task)
            case .codeBlock: result = Self.insertCodeFence(nsText, selection)
            case .bracket:   result = Self.wrapInline(nsText, selection, prefix: "[", suffix: "]")
            case .link:      result = Self.insertLink(nsText, selection)
            case .quote:     result = Self.applyLineRule(nsText, selection, rule: .quote)
            }
            setStyledText(textView, result.text, selection: result.selection)
            text = result.text
        }

        // MARK: 行级语法（# / - / [ ] / >）：行首插入，再点一次去掉

        /// 行首前缀规则：candidates 按从长到短排列，命中即视为「已有前缀」。
        private struct LineRule {
            let candidates: [String]
            let target: String

            static let heading1 = LineRule(candidates: ["###### ", "##### ", "#### ", "### ", "## ", "# "], target: "# ")
            static let heading2 = LineRule(candidates: ["###### ", "##### ", "#### ", "### ", "## ", "# "], target: "## ")
            static let list     = LineRule(candidates: ["- [ ] ", "- [x] ", "- [X] ", "- "], target: "- ")
            static let task     = LineRule(candidates: ["- [x] ", "- [X] ", "- [ ] ", "- "], target: "- [ ] ")
            static let quote    = LineRule(candidates: ["> ", ">"], target: "> ")
        }

        /// 对选区覆盖的所有行套用行首规则：全部行已有目标前缀则统一去掉（再点一次），
        /// 否则逐行替换已有候选前缀 / 补插目标前缀（空行跳过，单行光标态除外）。
        private static func applyLineRule(_ nsText: NSString, _ selection: NSRange, rule: LineRule)
            -> (text: String, selection: NSRange)
        {
            let lineRange = nsText.lineRange(for: selection)
            let block = nsText.substring(with: lineRange)
            var lines = block.components(separatedBy: "\n")
            var trailingNewline = false
            if lines.count > 1, lines.last == "" {
                lines.removeLast()
                trailingNewline = true
            }

            let nonEmpty = lines.filter { !$0.isEmpty }
            let removeMode = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(rule.target) }

            var newLines: [String] = []
            newLines.reserveCapacity(lines.count)
            var offset = 0 // 当前行行首在 block 内的 utf16 位移
            var cursorLineStart = lineRange.location
            var cursorDelta = 0

            for line in lines {
                var newLine = line
                var delta = 0
                if removeMode {
                    newLine = String(line.dropFirst(rule.target.count))
                    delta = -rule.target.utf16.count
                } else if let matched = rule.candidates.first(where: { line.hasPrefix($0) }) {
                    if matched != rule.target {
                        newLine = rule.target + line.dropFirst(matched.count)
                        delta = rule.target.utf16.count - matched.utf16.count
                    }
                } else if !line.isEmpty || lines.count == 1 {
                    newLine = rule.target + line
                    delta = rule.target.utf16.count
                }

                if selection.length == 0 {
                    let lineStart = lineRange.location + offset
                    if selection.location >= lineStart, selection.location <= lineStart + line.utf16.count {
                        cursorLineStart = lineStart
                        cursorDelta = delta
                    }
                }
                newLines.append(newLine)
                offset += line.utf16.count + 1 // +1 补回 components 拆掉的换行符
            }

            var newBlock = newLines.joined(separator: "\n")
            if trailingNewline { newBlock += "\n" }
            let newText = nsText.replacingCharacters(in: lineRange, with: newBlock)

            let newSelection: NSRange
            if selection.length == 0 {
                newSelection = NSRange(location: max(cursorLineStart, selection.location + cursorDelta), length: 0)
            } else {
                newSelection = NSRange(location: lineRange.location, length: newBlock.utf16.count)
            }
            return (newText, newSelection)
        }

        // MARK: 行内语法（** / [ ]）：包裹选区，再点一次解开；无选区插骨架、光标放中间

        private static func wrapInline(_ nsText: NSString, _ selection: NSRange, prefix: String, suffix: String)
            -> (text: String, selection: NSRange)
        {
            let prefixLength = prefix.utf16.count
            let suffixLength = suffix.utf16.count

            if selection.length > 0 {
                let selected = nsText.substring(with: selection)
                // 选区自带标记：剥掉
                if selected.hasPrefix(prefix), selected.hasSuffix(suffix),
                   selection.length > prefixLength + suffixLength {
                    let inner = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
                    let newText = nsText.replacingCharacters(in: selection, with: inner)
                    return (newText, NSRange(location: selection.location, length: inner.utf16.count))
                }
                // 选区被标记包住：解开外层
                if selection.location >= prefixLength,
                   NSMaxRange(selection) + suffixLength <= nsText.length,
                   nsText.substring(with: NSRange(location: selection.location - prefixLength, length: prefixLength)) == prefix,
                   nsText.substring(with: NSRange(location: NSMaxRange(selection), length: suffixLength)) == suffix {
                    let withoutSuffix = nsText.replacingCharacters(
                        in: NSRange(location: NSMaxRange(selection), length: suffixLength), with: "")
                    let newText = (withoutSuffix as NSString).replacingCharacters(
                        in: NSRange(location: selection.location - prefixLength, length: prefixLength), with: "")
                    return (newText, NSRange(location: selection.location - prefixLength, length: selection.length))
                }
                let wrapped = prefix + selected + suffix
                let newText = nsText.replacingCharacters(in: selection, with: wrapped)
                return (newText, NSRange(location: selection.location + prefixLength, length: selection.length))
            }

            // 无选区：插入空骨架，光标落到两个标记中间
            let newText = nsText.replacingCharacters(in: selection, with: prefix + suffix)
            return (newText, NSRange(location: selection.location + prefixLength, length: 0))
        }

        // MARK: 链接骨架：[text](url)，占位词直接选中，敲字即替换

        private static func insertLink(_ nsText: NSString, _ selection: NSRange)
            -> (text: String, selection: NSRange)
        {
            if selection.length > 0 {
                let selected = nsText.substring(with: selection)
                let skeleton = "[" + selected + "](url)"
                let newText = nsText.replacingCharacters(in: selection, with: skeleton)
                let urlStart = selection.location + 1 + selection.length + 2
                return (newText, NSRange(location: urlStart, length: 3))
            }
            let skeleton = "[text](url)"
            let newText = nsText.replacingCharacters(in: selection, with: skeleton)
            return (newText, NSRange(location: selection.location + 1, length: 4))
        }

        // MARK: 代码块：``` 围栏对 + 换行；有选区时把选区装进去

        private static func insertCodeFence(_ nsText: NSString, _ selection: NSRange)
            -> (text: String, selection: NSRange)
        {
            let atLineStart = selection.location == 0
                || nsText.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\n"
            let leadingNewline = atLineStart ? "" : "\n"

            if selection.length > 0 {
                let selected = nsText.substring(with: selection)
                let endsAtLineBreak = NSMaxRange(selection) == nsText.length
                    || nsText.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) == "\n"
                let block = leadingNewline + "```\n" + selected + "\n```" + (endsAtLineBreak ? "" : "\n")
                let newText = nsText.replacingCharacters(in: selection, with: block)
                let innerStart = selection.location + leadingNewline.utf16.count + 4
                return (newText, NSRange(location: innerStart, length: selection.length))
            }

            let needsTrailingNewline = selection.location < nsText.length
                && nsText.substring(with: NSRange(location: selection.location, length: 1)) != "\n"
            let block = leadingNewline + "```\n\n```" + (needsTrailingNewline ? "\n" : "")
            let newText = nsText.replacingCharacters(in: selection, with: block)
            let cursor = selection.location + leadingNewline.utf16.count + 4
            return (newText, NSRange(location: cursor, length: 0))
        }
    }
}

// MARK: - 键盘工具条

/// 工具条动作：行级（H1/H2/列表/任务/引用）、行内（加粗/方括号/链接）、代码块。
enum MarkdownToolbarAction {
    case h1, h2, bold, list, task, codeBlock, bracket, link, quote
}

/// 横滑 Markdown 工具条（inputAccessoryView）：纸墨风格胶囊按钮，
/// card 底 + 发丝描边 + inkSecondary 文字/图标，最右固定一枚收键盘钮。
final class MarkdownToolbarAccessory: UIView {
    private let onAction: (MarkdownToolbarAction) -> Void
    private let onDismiss: () -> Void

    init(onAction: @escaping (MarkdownToolbarAction) -> Void, onDismiss: @escaping () -> Void) {
        self.onAction = onAction
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        autoresizingMask = .flexibleWidth
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 46)
    }

    private func build() {
        backgroundColor = UIColor(PaperTheme.paper)

        // 顶部发丝分隔线，与键盘区域隔开
        let hairline = UIView()
        hairline.backgroundColor = UIColor(PaperTheme.hairline)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let items: [(title: String, action: MarkdownToolbarAction, accessibility: String)] = [
            ("H1", .h1, "一级标题"),
            ("H2", .h2, "二级标题"),
            ("**", .bold, "加粗"),
            ("-", .list, "列表"),
            ("[ ]", .task, "任务列表"),
            ("`", .codeBlock, "代码块"),
            ("[", .bracket, "方括号"),
            ("链接", .link, "链接"),
            (">", .quote, "引用"),
        ]
        for item in items {
            let button = makeButton(title: item.title, accessibilityLabel: item.accessibility) { [weak self] in
                self?.onAction(item.action)
            }
            stack.addArrangedSubview(button)
        }

        let dismissButton = makeButton(image: UIImage(systemName: "chevron.down"), accessibilityLabel: "收起键盘") { [weak self] in
            self?.onDismiss()
        }
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 胶囊钮：card 底、发丝描边、inkSecondary 文字/图标，按压轻触觉。
    private func makeButton(
        title: String? = nil,
        image: UIImage? = nil,
        accessibilityLabel: String,
        handler: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = image
        configuration.baseForegroundColor = UIColor(PaperTheme.inkSecondary)
        configuration.background.backgroundColor = UIColor(PaperTheme.card)
        configuration.background.strokeColor = UIColor(PaperTheme.hairline)
        configuration.background.strokeWidth = 0.5
        configuration.background.cornerRadius = 15 // 30pt 高即胶囊
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 13)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            return outgoing
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            handler()
        })
        button.accessibilityLabel = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
}
