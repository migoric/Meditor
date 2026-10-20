import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Mermaid 图表块：走共享渲染引擎（MermaidRenderer）出 PNG 图片展示（SwiftUI Image 不支持
/// SVG，块内展示位图是硬约束），占位 → 图片淡入；不再每块各起一个 WKWebView
/// （旧方案每张图都要解析一遍 3MB 的 JS）。长按可分享矢量 SVG 或 PNG；
/// 小图被容器拉宽时按显示宽度向引擎重渲一档更密的位图，避免放大发虚。
struct MermaidBlockView: View {
    let code: String

    @Environment(\.displayScale) private var displayScale
    /// 外观切换（浅色 / 墨夜）要重渲染：图表 PNG 是按外观配色的位图。
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case rendered(MermaidRenderer.Rendered)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("渲染图表中…")
                        .font(.system(size: 12))
                        .foregroundStyle(PaperTheme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)

            case .rendered(let rendered):
                Image(uiImage: rendered.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    // 超高图（长流程图等）限高 600pt 等比缩小，避免一屏放不下。
                    .frame(maxHeight: rendered.size.height > 600 ? 600 : .infinity)
                    .padding(.vertical, 10)
                    .contextMenu {
                        ShareLink(item: SharedSVG(svg: rendered.svg),
                                  preview: SharePreview("图表（矢量 SVG）")) {
                            Label("分享矢量 SVG", systemImage: "square.and.arrow.up")
                        }
                        ShareLink(item: Image(uiImage: rendered.image),
                                  preview: SharePreview("图表（PNG）", image: Image(uiImage: rendered.image))) {
                            Label("分享 PNG 图片", systemImage: "photo")
                        }
                    }
                    // 容器比图宽时（小图被拉满屏宽），按实际显示宽度补渲一档。
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        resharpen(rendered, displayWidth: width)
                    }

            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PaperTheme.accent)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(PaperTheme.card, in: RoundedRectangle(cornerRadius: PaperTheme.Radius.medium, style: .continuous))
        .shadow(color: PaperTheme.cardShadow, radius: 10, y: 3)
        .task(id: "\(colorScheme == .dark)|\(code)") {
            do {
                let rendered = try await MermaidRenderer.shared.render(
                    code: code, scale: displayScale, dark: colorScheme == .dark
                )
                guard !Task.isCancelled else { return }
                withAnimation(PaperTheme.Motion.standard) { phase = .rendered(rendered) }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 小图被容器拉宽超过已渲染像素时，按显示宽度向引擎重渲一档更密的位图
    /// （引擎侧由 SVG 按目标分辨率重新栅格化；缓存键含缩放，同一档位只渲一次）。
    /// 重渲结果替换 phase 后宽度不变、本函数不会再次被触发；即使触发，
    /// needed ≤ current 的守卫也会让它自然停止。
    private func resharpen(_ rendered: MermaidRenderer.Rendered, displayWidth: CGFloat) {
        let logicalWidth = rendered.size.width
        guard logicalWidth > 0, displayWidth > 0 else { return }
        // 显示清晰需要的像素密度：显示宽度(pt) × 屏幕缩放 ÷ 逻辑宽度(pt)。
        let needed = displayScale * displayWidth / logicalWidth
        let current = rendered.image.scale
        // 富余 25% 以内不折腾——位图轻微放大肉眼难辨，避免边缘场景反复重渲。
        guard needed > current * 1.25 else { return }
        // 量化到 0.25 档稳住缓存键（显示宽度是浮点）；封顶 4 倍逻辑放大。
        let scale = min((needed * 4).rounded(.up) / 4, displayScale * 4)
        guard scale > current else { return }
        Task {
            guard let sharper = try? await MermaidRenderer.shared.render(
                code: code, scale: scale, dark: colorScheme == .dark
            ) else { return }
            withAnimation(PaperTheme.Motion.standard) { phase = .rendered(sharper) }
        }
    }
}

/// 让 SVG 字符串能以 .svg 类型进入系统分享表单（ShareLink 要求 Transferable）。
private struct SharedSVG: Transferable {
    let svg: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .svg) { Data($0.svg.utf8) }
    }
}
