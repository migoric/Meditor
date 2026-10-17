import SwiftUI
import AppKit

// MARK: - AtMentionComposerView
//
// SwiftUI wrapper around a custom NSTextView that:
//   • Renders confirmed @mentions as tinted NSTextAttachment chips
//   • Detects @ typed by the user → shows a floating candidate picker
//   • Returns a plain-text representation + token list to the parent
//
// Architecture:
//   AtMentionComposerView (SwiftUI)
//     └─ AtMentionTextView (NSViewRepresentable)
//          └─ MentionTextView : NSTextView  (AppKit, owns the rich document)
//               └─ MentionAttachmentCell     (draws individual chips)

// MARK: - Public SwiftUI wrapper

@MainActor
struct AtMentionComposerView: NSViewRepresentable {

    // MARK: Bindings / callbacks

    /// Plain-text content of the composer (for persistence / canSend logic)
    @Binding var plainText: String
    /// Confirmed @mention tokens (read by send() to build context)
    @Binding var mentionTokens: [AtMentionToken]
    /// Whether the view currently has focus
    @Binding var isFocused: Bool

    /// Called when user presses Return (without Shift) → trigger send
    var onSubmit: () -> Void
    /// picker 未显示时按下 Esc 的回调（语义同 hero overlay 的 onExitCommand：关闭 AI 面板）。
    /// NSTextView 默认会把 Esc 转成 cancelOperation: 并吞掉，SwiftUI 的 onExitCommand 收不到，
    /// 必须在这里显式上报。为 nil 时保持系统默认行为（不拦截）。
    var onEscapeWithoutPicker: (() -> Void)? = nil
    /// ⌘V 粘贴到图片时回调（返回 nil 表示未启用图片输入，走系统默认粘贴）。
    /// 图片从粘贴板提取（截图 PNG/TIFF、图片文件 URL），处理成聊天附件后上抛。
    var onImagesPasted: (([AIImageAttachment]) -> Void)? = nil
    /// Theme so colors match the rest of the panel
    var theme: PreviewTheme
    /// Font size matching editor settings
    var fontSize: CGFloat = 13.5

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(plainText: $plainText,
                    mentionTokens: $mentionTokens,
                    isFocused: $isFocused,
                    onSubmit: onSubmit,
                    onEscapeWithoutPicker: onEscapeWithoutPicker,
                    onImagesPasted: onImagesPasted,
                    theme: theme,
                    fontSize: fontSize)
    }

    // ── 返回 NSScrollView，textView 作为 documentView ──────────────────────
    // 这是解决"太高 / 点击区域 / 滚动击穿"三个问题的根本方案：
    // • SwiftUI frame 控制显示高度（min 22, max 120）
    // • NSScrollView 自动处理超出内容的滚动，不溢出
    // • 整个 scrollView 区域都可点击，hit test 正确
    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.textView

        // textView 随宽度伸展，高度由内容决定（在 scrollView 内无限扩展）
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.textContainer?.widthTracksTextView  = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.drawsBackground        = false
        scrollView.borderType             = .noBorder
        scrollView.hasVerticalScroller    = true
        scrollView.autohidesScrollers     = true
        scrollView.hasHorizontalScroller  = false
        scrollView.documentView           = tv

        context.coordinator.scrollView = scrollView
        context.coordinator.applyTheme(theme, fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyTheme(theme, fontSize: fontSize)
        // 父视图每次 body 求值都会重建闭包，这里同步最新值，避免 Coordinator 持有过期闭包
        context.coordinator.onEscapeWithoutPicker = onEscapeWithoutPicker
        context.coordinator.onImagesPasted = onImagesPasted
        let tv = context.coordinator.textView
        // 外部（send 后）清空 plainText → 同步清空 textView
        if plainText.isEmpty && !tv.string.isEmpty {
            context.coordinator.clearAll()
        } else if !plainText.isEmpty && tv.string.isEmpty {
            // 外部注入（如「问 AI」带入选区引用）到空输入框 → 同步显示，否则 NSTextView 不会刷新
            context.coordinator.setExternalText(plainText)
        }
        if isFocused && tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
    }

    // MARK: - Coordinator (owns NSTextView + state)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        // MARK: State

        @Binding var plainText: String
        @Binding var mentionTokens: [AtMentionToken]
        @Binding var isFocused: Bool
        var onSubmit: () -> Void
        /// picker 未显示时按下 Esc 的回调（见 AtMentionComposerView.onEscapeWithoutPicker）
        var onEscapeWithoutPicker: (() -> Void)?
        /// 图片粘贴回调（见 AtMentionComposerView.onImagesPasted）
        var onImagesPasted: (([AIImageAttachment]) -> Void)?
        var theme: PreviewTheme
        var fontSize: CGFloat

        let textView: MentionTextView
        weak var scrollView: NSScrollView?

        /// The query currently being typed after the most recent bare @
        /// nil = not in mention-typing mode
        private(set) var activeQuery: String? = nil
        /// Character index of the @ that opened the current mention session
        private var atSignIndex: Int? = nil

        // MARK: Init

        init(plainText: Binding<String>,
             mentionTokens: Binding<[AtMentionToken]>,
             isFocused: Binding<Bool>,
             onSubmit: @escaping () -> Void,
             onEscapeWithoutPicker: (() -> Void)? = nil,
             onImagesPasted: (([AIImageAttachment]) -> Void)? = nil,
             theme: PreviewTheme,
             fontSize: CGFloat) {
            _plainText    = plainText
            _mentionTokens = mentionTokens
            _isFocused    = isFocused
            self.onSubmit = onSubmit
            self.onEscapeWithoutPicker = onEscapeWithoutPicker
            self.onImagesPasted = onImagesPasted
            self.theme    = theme
            self.fontSize = fontSize
            textView = MentionTextView()
            super.init()
            textView.delegate = self
            textView.mentionCoordinator = self
            // 监听外部发来的"确认选择"通知（从 SwiftUI popover → Coordinator）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleConfirmCandidate(_:)),
                name: .atMentionConfirmCandidate,
                object: nil
            )
        }

        @objc private func handleConfirmCandidate(_ n: Notification) {
            guard let candidate = n.object as? AtMentionCandidate else { return }
            confirmMention(candidate)
        }

        // MARK: Theme

        func applyTheme(_ theme: PreviewTheme, fontSize: CGFloat) {
            // guard：主题/字号没变就不触碰 NSTextView（避免每次 SwiftUI pass 都重设）
            guard theme.rawValue != self.theme.rawValue || fontSize != self.fontSize else { return }
            self.theme    = theme
            self.fontSize = fontSize
            textView.backgroundColor     = .clear
            textView.textColor           = theme.foregroundNSColor
            textView.insertionPointColor = theme.foregroundNSColor
            textView.font                = NSFont.systemFont(ofSize: fontSize)
            textView.typingAttributes    = baseTypingAttributes()
        }

        func baseTypingAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: theme.foregroundNSColor
            ]
        }

        // MARK: Insert confirmed mention chip

        /// Called by the popover when the user picks a candidate.
        func confirmMention(_ candidate: AtMentionCandidate) {
            guard let atIdx = atSignIndex,
                  let storage = textView.textStorage else { return }

            let token = AtMentionToken(kind: candidate.kind)

            // Build chip attributed string
            let attachment = MentionAttachment(token: token, theme: theme, fontSize: fontSize)
            let chipStr = NSAttributedString(attachment: attachment)

            // Replace "@query" range with chip + trailing space
            let currentLen = storage.length
            let replaceStart = min(atIdx, currentLen)

            // Compute the actual replace range: from @ to end of typed query
            let nsStr = storage.string as NSString
            var end = replaceStart
            while end < nsStr.length {
                // 代理对 half 的 unicodeChar 为 nil，视为非空白继续扫描
                if let uc = nsStr.character(at: end).unicodeChar, " \n\t".contains(uc) { break }
                end += 1
            }
            let actualRange = NSRange(location: replaceStart, length: end - replaceStart)

            storage.beginEditing()
            let space = NSAttributedString(string: " ", attributes: baseTypingAttributes())
            let combined = NSMutableAttributedString(attributedString: chipStr)
            combined.append(space)
            storage.replaceCharacters(in: actualRange, with: combined)
            storage.endEditing()

            // Move caret after chip + space
            let newCaret = replaceStart + combined.length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))

            // Register token
            mentionTokens.append(token)

            // Reset mention state
            activeQuery = nil
            atSignIndex = nil

            syncPlainText()
            notifyChange()
        }

        func cancelMention() {
            activeQuery = nil
            atSignIndex = nil
        }

        // MARK: Clear

        func clearAll() {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            mentionTokens.removeAll()
            activeQuery = nil
            atSignIndex = nil
            plainText = ""
        }

        /// 外部注入纯文本（如「问 AI」带入选区引用）到空输入框。
        /// updateNSView 仅在 textView 为空时调用，避免覆盖用户正在输入的内容或 @mention。
        func setExternalText(_ text: String) {
            guard let storage = textView.textStorage else { return }
            var attrs = textView.typingAttributes
            if attrs[.font] == nil, let f = textView.font { attrs[.font] = f }
            storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
            // 光标移到末尾，方便用户接着输入问题
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            if plainText != text { plainText = text }
        }

        // MARK: 图片粘贴

        /// ⌘V 时优先拦截粘贴板里的图片（截图 PNG/TIFF、图片文件 URL）→ 聊天附件。
        /// 返回 true = 已消费，调用方不再走系统默认文本粘贴。
        func handleImagePaste() -> Bool {
            guard let onImagesPasted else { return false }
            let attachments = AIImageProcessor.attachments(from: .general)
            guard !attachments.isEmpty else { return false }
            onImagesPasted(attachments)
            return true
        }

        // MARK: Plain text sync

        /// Derives plain text: replace attachment chars with @displayName
        func syncPlainText() {
            guard let storage = textView.textStorage else { return }
            // 只桥接一次：此前在 enumerateAttributes 闭包内反复 `storage.string as NSString`，
            // 每个 attribute run 都桥接一次全文，长文本下是 O(runs × length)。
            let nsString = storage.string as NSString
            let result = NSMutableString()
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? MentionAttachment {
                    result.append("@\(attachment.token.displayName)")
                } else {
                    result.append(nsString.substring(with: range))
                }
            }
            let newText = result as String
            // 只有内容真的变了才写 Binding（避免触发不必要的 SwiftUI 重渲染）
            if newText != plainText { plainText = newText }
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView,
                      shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            true // let the default handling proceed; we inspect in textDidChange
        }

        func textDidChange(_ notification: Notification) {
            // IME 组字期间不做 token 重建：marked text 尚未上屏，此时扫描
            // textStorage 做破坏性重建有误判风险（与回车/Esc 的组字防护同理）
            if !textView.hasMarkedText() {
                rebuildMentionTokens()
            }
            syncPlainText()
            detectMentionTrigger()
            notifyChange()
        }

        /// 根据 textStorage 现存的 mention chip 重建 token 列表（顺序与文本中一致）。
        /// 用户删除 chip 后 token 必须同步移除，否则 send() 仍会注入已删除引用的文件内容。
        private func rebuildMentionTokens() {
            guard let storage = textView.textStorage else { return }
            var tokens: [AtMentionToken] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? MentionAttachment {
                    tokens.append(attachment.token)
                }
            }
            // token 实例与 attachment 内的一一对应，未增删时数组相等，避免不必要的 Binding 写入
            if tokens != mentionTokens { mentionTokens = tokens }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // If caret moves away from the current @ query zone, cancel
            if activeQuery != nil, let atIdx = atSignIndex {
                let caret = textView.selectedRange().location
                if caret <= atIdx { cancelMention() }
            }
        }

        func textDidBeginEditing(_ notification: Notification) { isFocused = true }
        func textDidEndEditing(_ notification: Notification)   { isFocused = false }

        // MARK: Mention trigger detection

        private func detectMentionTrigger() {
            guard let storage = textView.textStorage else { return }
            let caret = textView.selectedRange().location
            guard caret > 0 else { cancelMention(); return }

            let nsStr = storage.string as NSString

            // Walk back from caret to find the nearest @ not inside an attachment
            var scanIdx = caret - 1
            var query = ""
            while scanIdx >= 0 {
                let ch = nsStr.character(at: scanIdx)
                // UTF-16 代理对（emoji 等）没有独立的 Unicode.Scalar，强制解包会崩：
                // 低位 half 与前一个高位 half 合成完整字符；孤立 half 直接放弃检测。
                var step = 1
                let c: Character
                if let scalar = Unicode.Scalar(ch) {
                    c = Character(scalar)
                } else if UTF16.isTrailSurrogate(ch), scanIdx > 0,
                          UTF16.isLeadSurrogate(nsStr.character(at: scanIdx - 1)) {
                    c = Character(String(decoding: [nsStr.character(at: scanIdx - 1), ch], as: UTF16.self))
                    step = 2
                } else {
                    break
                }
                if c == "@" {
                    // Verify this is NOT inside an attachment range
                    var isAttachment = false
                    storage.enumerateAttributes(in: NSRange(location: scanIdx, length: 1)) { attrs, _, _ in
                        if attrs[.attachment] != nil { isAttachment = true }
                    }
                    if !isAttachment {
                        // Check the character before @ is whitespace / start
                        // （代理对 half 没有 Scalar，视为非空白，不触发 mention）
                        let beforeIsWhitespace: Bool
                        if scanIdx == 0 {
                            beforeIsWhitespace = true
                        } else if let s = Unicode.Scalar(nsStr.character(at: scanIdx - 1)) {
                            beforeIsWhitespace = " \n\t".contains(Character(s))
                        } else {
                            beforeIsWhitespace = false
                        }
                        if beforeIsWhitespace {
                            // Valid mention trigger
                            activeQuery = String(query.reversed())
                            atSignIndex = scanIdx
                            return
                        }
                    }
                    break
                }
                // Bail out if we hit a space or newline (no @ before non-space)
                if " \n\t".contains(c) { break }
                query.append(c)
                scanIdx -= step
            }
            // No valid @ found
            if activeQuery != nil { cancelMention() }
        }

        // 防抖计时器：避免每次按键连发多条 notification（滚键盘时可能 textDidChange + detectTrigger 各发一次）
        @ObservationIgnored private var debounceWork: DispatchWorkItem?

        private func notifyChange() {
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .atMentionQueryChanged, object: self)
            }
            debounceWork = work
            // 16ms ≈ 1 帧，足够合并同一按键产生的多次调用，又不引入可感知延迟
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }
    }
}

// MARK: - NSUInteger → unichar helper
private extension UInt16 {
    /// 安全转换：代理对的一半（emoji 等）没有独立的 Unicode.Scalar，返回 nil。
    var unicodeChar: Character? {
        Unicode.Scalar(self).map(Character.init)
    }
}

// MARK: - MentionTextView (NSTextView subclass)

/// Thin NSTextView subclass:
/// - Intercepts Return (submit) and Escape (cancel mention / close AI panel)
/// - Delegates all mention logic to Coordinator
@MainActor
final class MentionTextView: NSTextView {

    weak var mentionCoordinator: AtMentionComposerView.Coordinator?

    /// ⌘V：粘贴板含图片时交给聊天附件链路（缩略图 chips），否则走系统默认文本粘贴
    override func paste(_ sender: Any?) {
        if mentionCoordinator?.handleImagePaste() == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isPickerVisible = mentionCoordinator?.activeQuery != nil

        switch event.keyCode {
        case 36: // Return
            if !event.modifierFlags.contains(.shift) {
                // IME 组字（marked text）期间回车归输入法上屏/确认候选，
                // 不能拦截成发送——否则拼音还没上屏就被发出并清空（丢字）。
                guard !hasMarkedText() else { break }
                if isPickerVisible {
                    // 让 picker 先处理（确认高亮项）
                    NotificationCenter.default.post(
                        name: .atMentionKeyEvent,
                        object: AtMentionKeyEvent.confirm
                    )
                } else {
                    mentionCoordinator?.onSubmit()
                }
                return
            }
        case 53: // Escape
            // Esc 归属顺序（唯一链路，详见 AIAssistantLauncher 的 onExitCommand 注释）：
            // 1. IME 组字中 → 归输入法（取消组字），走 super 不拦截
            // 2. mention picker 显示中 → 只关 picker
            // 3. 其余 → 归 AI 面板（关闭面板），显式回调上报，不走 super——
            //    NSTextView 会把 Esc 转成 cancelOperation: 吞掉，SwiftUI 的 onExitCommand 收不到
            if isPickerVisible, !hasMarkedText() {
                // 同理：组字期间 Esc 优先给输入法取消组字，而不是关 mention picker。
                NotificationCenter.default.post(
                    name: .atMentionKeyEvent,
                    object: AtMentionKeyEvent.dismiss
                )
                mentionCoordinator?.cancelMention()
                return
            }
            if !hasMarkedText(), let onEscape = mentionCoordinator?.onEscapeWithoutPicker {
                onEscape()
                return
            }
        case 125: // ↓ — handled by moveDown override
            break
        case 126: // ↑ — handled by moveUp override
            break
        default:
            break
        }
        super.keyDown(with: event)
    }

    // intrinsicContentSize 不再 override：
    // 高度由 SwiftUI frame(minHeight:maxHeight:) 约束，NSScrollView 内容滚动。
    // 保留 didChangeText 让 NSScrollView 在内容变化时自动滚到底部（类 Terminal 行为）。
    override func didChangeText() {
        super.didChangeText()
        // 仅在插入点位于文末时跟随滚动（pin-to-bottom）；无条件 scrollToEndOfDocument
        // 会让用户无法上滚查看/编辑前面的内容，并且每次输入都强制布局。
        let length = (string as NSString).length
        if selectedRange().location >= length {
            scrollToEndOfDocument(nil)
        }
    }

    // 方向键需要 override moveUp/moveDown，因为 NSTextView 在 interpretKeyEvents 阶段
    // 就消费了方向键，keyDown 里的 keyCode 判断可能不可靠。
    override func moveUp(_ sender: Any?) {
        guard mentionCoordinator?.activeQuery != nil else { super.moveUp(sender); return }
        NotificationCenter.default.post(name: .atMentionKeyEvent, object: AtMentionKeyEvent.moveUp)
        // 不调 super，阻止光标移动（否则 textViewDidChangeSelection 会取消 mention）
    }

    override func moveDown(_ sender: Any?) {
        guard mentionCoordinator?.activeQuery != nil else { super.moveDown(sender); return }
        NotificationCenter.default.post(name: .atMentionKeyEvent, object: AtMentionKeyEvent.moveDown)
        // 不调 super，阻止光标移动
    }
}

// MARK: - MentionAttachment (NSTextAttachment chip)

/// A custom NSTextAttachment that draws a tinted pill for a confirmed @mention.
final class MentionAttachment: NSTextAttachment {

    let token: AtMentionToken
    let theme: PreviewTheme
    let fontSize: CGFloat

    init(token: AtMentionToken, theme: PreviewTheme, fontSize: CGFloat) {
        self.token    = token
        self.theme    = theme
        self.fontSize = fontSize
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MentionAttachmentCell(token: token, theme: theme, fontSize: fontSize)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class MentionAttachmentCell: NSTextAttachmentCell {

    let token: AtMentionToken

    private let hPad: CGFloat = 6
    private let vPad: CGFloat = 2

    // 所有颜色/字体只在 init 时算一次，draw/cellSize 直接用缓存
    private let chipText: String
    private let cachedTextAttributes: [NSAttributedString.Key: Any]
    private let cachedForeground: NSColor
    private let cachedBackground: NSColor
    private let cachedBorder: NSColor

    init(token: AtMentionToken, theme: PreviewTheme, fontSize: CGFloat) {
        self.token = token
        self.chipText = "@\(token.displayName)"

        let isDir = token.kind.isDirectory
        cachedForeground = isDir
            ? NSColor(Color.purple.opacity(0.9))
            : NSColor(Color.appAccent.opacity(0.9))
        cachedBackground = isDir
            ? NSColor(Color.purple.opacity(0.12))
            : NSColor(Color.selectionFill)
        cachedBorder = isDir
            ? NSColor(Color.purple.opacity(0.28))
            : NSColor(Color.appAccent.opacity(0.28))
        cachedTextAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize - 1, weight: .medium),
            .foregroundColor: cachedForeground
        ]
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize {
        let textSize = chipText.size(withAttributes: cachedTextAttributes)
        return NSSize(width: textSize.width + hPad * 2 + 2, height: textSize.height + vPad * 2)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -(vPad))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // 内缩 0.5pt 是有意的像素对齐：0.75pt 描边若贴 cell 边缘会被裁掉外侧一半，
        // 内缩半像素后两侧完整可见（描边宽度本身不套 DS.Stroke——它是 NSTextAttachment
        // cell 内的高亮 chip，与卡片/分隔线的两档语义不同类）。
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 4, yRadius: 4)
        cachedBackground.setFill()
        path.fill()
        cachedBorder.setStroke()
        path.lineWidth = 0.75
        path.stroke()
        chipText.draw(in: cellFrame.insetBy(dx: hPad, dy: vPad),
                      withAttributes: cachedTextAttributes)
    }
}

// MARK: - Keyboard event enum (NSTextView → SwiftUI picker)

enum AtMentionKeyEvent {
    case moveUp, moveDown, confirm, dismiss
}

// MARK: - Notification

extension Notification.Name {
    static let atMentionQueryChanged     = Notification.Name("AtMentionQueryChanged")
    static let atMentionConfirmCandidate = Notification.Name("AtMentionConfirmCandidate")
    static let atMentionKeyEvent         = Notification.Name("AtMentionKeyEvent")
}

// MARK: - AtMentionPickerView (SwiftUI popover)

/// The floating file picker that appears while the user is typing after @.
@MainActor
struct AtMentionPickerView: View {
    @Environment(AppState.self) private var state
    let query: String
    let theme: PreviewTheme
    let onSelect: (AtMentionCandidate) -> Void
    let onDismiss: () -> Void

    @State private var highlighted = 0

    /// 当前高亮项的 id（供 row 判断是否高亮，避免用 index 做 identity）
    private func highlightedID(in list: [AtMentionCandidate]) -> AtMentionCandidate.ID? {
        guard list.indices.contains(highlighted) else { return nil }
        return list[highlighted].id
    }

    // 同步计算候选，直接读 state.mentionItems（AppState 存储属性，@Observable 自动追踪）
    private var candidates: [AtMentionCandidate] {
        AtMentionParser.candidates(
            query: query,
            allFiles: state.mentionItems,
            rootURL: state.rootURL,
            currentDocumentURL: state.selectedTab?.url
        )
    }

    var body: some View {
        // mentionItems 现在是 AppState 的存储属性，candidates 读取它时 @Observable 自动追踪
        let currentCandidates = candidates

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "at")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.craftSecondary)
                Text(query.isEmpty ? L("ai.mention.pickerTitle") : L("ai.mention.pickerSearch", query))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.craftSecondary)
                Spacer()
                Text(L("ai.mention.pickerHint"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.primary.opacity(theme.isDark ? 0.12 : 0.07))
                .frame(height: 0.5)

            if currentCandidates.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                    Text(L("ai.mention.noMatches"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(theme.craftSecondary)
                .padding(.vertical, 16)
            } else {
                let rowHeight: CGFloat = 40
                // 固定上限约 5 行高度，超出则滚动，避免列表过高挤压输入框/对话区
                let maxVisibleRows = 5
                let listHeight = min(
                    CGFloat(currentCandidates.count) * (rowHeight + 1) + 8,
                    CGFloat(maxVisibleRows) * (rowHeight + 1) + 8
                )
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(currentCandidates) { cand in
                                AtMentionCandidateRow(
                                    candidate: cand,
                                    isHighlighted: cand.id == highlightedID(in: currentCandidates),
                                    theme: theme
                                )
                                .frame(height: rowHeight)
                                .id(cand.id)
                                .onTapGesture { onSelect(cand) }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    .frame(height: listHeight)
                    .onChange(of: highlighted) { _, new in
                        guard currentCandidates.indices.contains(new) else { return }
                        withAnimation(DS.Motion.micro) {
                            proxy.scrollTo(currentCandidates[new].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.isDark ? Color(white: 0.15) : Color(white: 0.99))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(theme.isDark ? 0.18 : 0.10), lineWidth: DS.Stroke.hairline)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 16, x: 0, y: 6)
        .shadow(color: .black.opacity(theme.isDark ? 0.20 : 0.06), radius: 4, x: 0, y: 2)
        // highlight 随候选列表变化自动 clamp
        .onChange(of: currentCandidates.count) { _, count in
            if highlighted >= count { highlighted = max(0, count - 1) }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .atMentionKeyEvent)) { notif in
            guard let ev = notif.object as? AtMentionKeyEvent else { return }
            switch ev {
            case .moveUp:    moveHighlight(-1, in: currentCandidates)
            case .moveDown:  moveHighlight(1, in: currentCandidates)
            case .confirm:   commitHighlighted(in: currentCandidates)
            case .dismiss:   onDismiss()
            }
        }
    }

    private func moveHighlight(_ delta: Int, in list: [AtMentionCandidate]) {
        guard !list.isEmpty else { return }
        highlighted = (highlighted + delta + list.count) % list.count
    }

    private func commitHighlighted(in list: [AtMentionCandidate]) {
        guard list.indices.contains(highlighted) else { return }
        onSelect(list[highlighted])
    }
}

// MARK: - Candidate row

private struct AtMentionCandidateRow: View {
    let candidate: AtMentionCandidate
    let isHighlighted: Bool
    let theme: PreviewTheme

    private var accentColor: Color {
        candidate.kind.isDirectory ? .purple : Color.appAccent
    }

    var body: some View {
        HStack(spacing: 5) {
            // Icon
            Image(systemName: candidate.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHighlighted ? accentColor : theme.craftSecondary)
                .frame(width: 16)

            // Name + path
            VStack(alignment: .leading, spacing: 0) {
                Text(candidate.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.craftPrimary)
                    .lineLimit(1)
                if !candidate.isBuiltin && candidate.relPath != candidate.displayName {
                    let parent = (candidate.relPath as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.craftSecondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            if candidate.isBuiltin {
                Text(L("ai.mention.builtin"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.craftSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.craftHover))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted
                      ? accentColor.opacity(0.10)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(DS.Motion.micro, value: isHighlighted)
    }
}
