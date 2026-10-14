import SwiftUI

/// Craft 同款玻璃胶囊底：奶白毛玻璃 + 顶部受光渐变/描边 + 双层软影。
/// 根页面底栏与文档页底栏共用，保证两处质感一致；深色（墨夜）自动减弱受光。
struct GlassCapsuleBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            // 竖向微光：顶部受光、底部一线微暗——玻璃有厚度
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isDark ? 0.10 : 0.45), location: 0),
                                .init(color: .white.opacity(isDark ? 0.02 : 0.05), location: 0.55),
                                .init(color: .black.opacity(isDark ? 0.12 : 0.035), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            // 顶部受光描边：上亮下隐，浮起的关键
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isDark ? 0.28 : 0.85),
                                .white.opacity(isDark ? 0.06 : 0.20),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: PaperTheme.Stroke.regular
                    )
            }
            // 外缘发丝线压出轮廓
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(PaperTheme.hairline.opacity(isDark ? 0.6 : 0.35), lineWidth: PaperTheme.Stroke.hairline)
            }
            // 双层软影：远处大扩散 + 近处轻接触
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.06), radius: 22, y: 10)
            .shadow(color: .black.opacity(isDark ? 0.25 : 0.05), radius: 5, y: 2)
    }
}
