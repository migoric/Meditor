import SwiftUI

/// 预览滚动偏移（内容相对滚动视口的 minY）：DocumentView 用它驱动导航栏透明 ↔ 纸底过渡。
struct PreviewScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Markdown 块级预览：复用共享的 MarkdownText block parser（GFM 表格、LRU 解析缓存，
/// 引用块合并行为与聊天气泡一致），外观保留预览独有的纸墨容器样式与悬挂缩进排版。
struct MarkdownPreviewView: View {
    let source: String

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ReaderSettings.self) private var reader
    @Environment(ChatModel.self) private var model
    @Environment(AIHeroState.self) private var aiHero
    /// 异步解析的 blocks：首次渲染不阻塞，.task 中解析完成后更新。
    @State private var blocks: [MarkdownText.Block]? = nil

    /// 阅读设置缩放后的正文基准字号（17pt × 系数）。
    private var bodySize: CGFloat { reader.scaled(17) }
    /// 行距系数换算的 SwiftUI lineSpacing（以正文字号为基准）。
    private var lineGap: CGFloat { reader.lineGap(for: bodySize) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let blocks {
                    ForEach(blocks) { block in
                        blockView(block)
                        // 块随滚动依次浮起：进入视口时从轻提到落位，页面有呼吸感
                        .scrollTransition(.animated(PaperTheme.Motion.quick)) { content, phase in
                            content
                                .opacity(phase.isIdentity ? 1 : 0.35)
                                .offset(y: phase.isIdentity ? 0 : 14)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PaperTheme.Spacing.page)
            .padding(.vertical, 20)
            .contextMenu {
                Button("AI 优化全文", systemImage: "sparkles") {
                    model.input = "帮我优化这篇文档：\n\n\(source)"
                    aiHero.isOpen = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        model.send()
                    }
                }
                Button("AI 总结要点", systemImage: "text.quote") {
                    model.input = "用 3-5 个要点总结这篇文档：\n\n\(source)"
                    aiHero.isOpen = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        model.send()
                    }
                }
                Button("AI 续写", systemImage: "pencil.line") {
                    model.input = "根据上文继续写：\n\n\(source)"
                    aiHero.isOpen = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        model.send()
                    }
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: PreviewScrollOffsetKey.self,
                        value: geo.frame(in: .named(Self.scrollSpace)).minY
                    )
                }
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        // 底部悬浮栏不挡内容：滚动内容底部留白（数值推导见 PaperTheme.Spacing.bottomBarInset）
        .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
        // 预热 Mermaid + 解析 blocks：推迟 ~50ms 让导航过渡先完成
        .task(priority: .userInitiated) {
            preloadMermaidIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            blocks = MarkdownText.parse(source)
        }
        .onChange(of: source) { preloadMermaidIfNeeded() }
        .onChange(of: colorScheme) { preloadMermaidIfNeeded() }
    }

    private static let scrollSpace = "markdown-preview-scroll"

    /// 文档含 mermaid 块时：预热共享引擎，并把全部图表按文档顺序预渲染进缓存——
    /// JS 解析与首屏渲染并行，屏外的图表也不用等滚动到才开始渲染。
    private func preloadMermaidIfNeeded() {
        guard source.contains("```mermaid") else { return }
        let codes = MarkdownText.parse(source).compactMap { block -> String? in
            guard case .code(let code, let language) = block.kind,
                  language?.lowercased() == "mermaid" else { return nil }
            return code
        }
        MermaidRenderer.shared.preload(codes: codes, scale: displayScale, dark: colorScheme == .dark)
    }

    // MARK: - 渲染

    @ViewBuilder
    private func blockView(_ block: MarkdownText.Block) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(inline(text))
                .font(PaperTheme.Typography.heading(level: level, scaledBy: reader.scaleFactor))
                .foregroundStyle(PaperTheme.ink)
                .lineSpacing(lineGap)
                .padding(.top, level <= 2 ? 14 : 8)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: bodySize))
                .foregroundStyle(PaperTheme.ink)
                .lineSpacing(lineGap)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItemView(marker: .bullet, text: item)
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listItemView(marker: .ordered(idx + 1), text: item)
                }
            }

        case .code(let code, let language):
            if language?.lowercased() == "mermaid" {
                MermaidBlockView(code: code)
            } else {
                codeBlockView(language: language, code: code)
            }

        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(PaperTheme.accent.opacity(0.45))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: reader.scaled(16.5)))
                    .foregroundStyle(PaperTheme.inkSecondary)
                    .lineSpacing(lineGap)
            }
            .padding(.leading, 2)

        case .table(let header, let rows):
            tableView(header, rows)

        case .rule:
            PaperTheme.hairline
                .frame(height: 0.5)
                .padding(.vertical, 6)
        }
    }

    /// 列表项：悬挂缩进（标记悬于左侧，折行与首行文本对齐）。
    /// 任务项前缀 [ ] / [x] 的判定与 MarkdownText 一致。
    private func listItemView(marker: ListMarker, text: String) -> some View {
        let task = Self.taskPrefix(text)
        let isChecked = task?.done ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            markerView(task.map { .task(checked: $0.done) } ?? marker)
                .frame(width: 16, alignment: .trailing)
            Text(inline(task?.text ?? text, strikethrough: isChecked))
                .font(.system(size: bodySize))
                .foregroundStyle(isChecked ? PaperTheme.inkSecondary : PaperTheme.ink)
                .lineSpacing(lineGap)
        }
        .padding(.leading, 2)
    }

    /// 普通代码块：语言标签 + 横向滚动等宽文本。
    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaperTheme.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(PaperTheme.Typography.code(scaledBy: reader.fontScale.rawValue))
                    .foregroundStyle(PaperTheme.ink)
                    .lineSpacing(5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, language == nil ? 14 : 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperTheme.codeBackground, in: RoundedRectangle(cornerRadius: PaperTheme.Radius.medium, style: .continuous))
    }

    /// GFM 表格：纸墨容器 + 表头底色；单元格过窄时文本折行（与聊天气泡表格同策略）。
    /// 容器去描边：柔和投影 + 干净填充，hairline 只留内部单元格分隔。
    private func tableView(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return VStack(spacing: 0) {
            tableRow(header, columns: columns, isHeader: true)
            ForEach(rows.indices, id: \.self) { r in
                tableRow(rows[r], columns: columns, isHeader: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: PaperTheme.Radius.medium, style: .continuous))
        .shadow(color: PaperTheme.cardShadow, radius: 10, y: 3)
    }

    private func tableRow(_ cells: [String], columns: Int, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { c in
                Text(inline(c < cells.count ? cells[c] : ""))
                    .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(PaperTheme.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if c < columns - 1 {
                    PaperTheme.hairline.frame(width: 0.5)
                }
            }
        }
        .background(isHeader ? PaperTheme.paper : Color.clear)
        .overlay(alignment: .bottom) {
            if isHeader {
                PaperTheme.hairline.frame(height: 0.5)
            }
        }
    }

    // MARK: - 列表标记

    enum ListMarker {
        case bullet
        case ordered(Int)
        case task(checked: Bool)
    }

    /// 任务列表项前缀（[ ] / [x]），与 MarkdownText 的判定一致。
    private static func taskPrefix(_ item: String) -> (done: Bool, text: String)? {
        let lower = item.lowercased()
        if lower.hasPrefix("[ ] ") { return (false, String(item.dropFirst(4))) }
        if lower.hasPrefix("[x] ") { return (true, String(item.dropFirst(4))) }
        return nil
    }

    /// 列表标记：圆点 / 序号 / 任务勾选框。
    @ViewBuilder
    private func markerView(_ marker: ListMarker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PaperTheme.accent.opacity(0.8))
        case .ordered(let n):
            Text("\(n).")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(PaperTheme.inkSecondary)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(checked ? PaperTheme.accent : PaperTheme.inkSecondary.opacity(0.6))
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
        }
    }

    /// 行内样式：系统解析 inline intent（粗体 / 斜体 / 删除线），
    /// 再补行内代码底色与链接色。
    private func inline(_ s: String, strikethrough: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var a = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in a.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = .system(size: reader.scaled(15), design: .monospaced)
                a[run.range].backgroundColor = PaperTheme.codeBackground
            }
            if run.link != nil {
                a[run.range].foregroundColor = PaperTheme.link
            }
        }
        if strikethrough {
            a.strikethroughStyle = .single
        }
        return a
    }
}
