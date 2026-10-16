import SwiftUI

/// AI 面板的展开状态（RootView 注入 environment）。
@Observable
final class AIHeroState {
    var isOpen = false
}

/// 新建文档的 hero 展开状态（RootView 注入 environment）。
@Observable
final class PlusHeroState {
    var isZooming = false
    var zoomID = "plus"
}

private struct HeroNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

// MARK: - 底栏共享按钮（＋ 新建 / AI 助手）

/// matchedGeometry 的可选包装：无 namespace 时退化为普通视图。
private struct HeroMatch: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let hidden: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content
                .matchedGeometryEffect(id: id, in: namespace, isSource: !hidden)
                .opacity(hidden ? 0 : 1)
        } else {
            content
        }
    }
}

/// ＋ 新建：与左胶囊一致的线图标（plus 墨色），轻量不突兀。
/// 点击 hero 放大成整页纸底再推入新文档。
struct BarPlusButton: View {
    /// 按钮所在栏位的标识（"root" / "doc"），用于区分 matchedGeometry 源。
    let context: String

    @Environment(PlusHeroState.self) private var plusHero
    @Environment(\.heroNamespace) private var heroNS

    var body: some View {
        Button {
            plusHero.zoomID = "plus-\(context)"
            withAnimation(PaperTheme.Motion.standard) { plusHero.isZooming = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PaperTheme.ink)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .modifier(HeroMatch(id: "plus-\(context)", namespace: heroNS, hidden: plusHero.isZooming))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("新建文档")
    }
}

/// AI 助手：朱砂色 sparkles 图标。不另加圆底——玻璃按钮自身即容器，
/// 再嵌一个圆底会和 folder / plus 三种长相打架（品牌区分靠图标颜色就够）。
struct BarAIButton: View {
    let context: String

    @Environment(AIHeroState.self) private var aiHero
    @Environment(\.heroNamespace) private var heroNS

    var body: some View {
        Button {
            withAnimation(PaperTheme.Motion.standard) { aiHero.isOpen = true }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PaperTheme.accent)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .modifier(HeroMatch(id: "ai-\(context)", namespace: heroNS, hidden: aiHero.isOpen))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("AI 助手")
    }
}

// MARK: - AI 面板（原生 sheet 内容）

/// AI 面板：以原生 sheet 呈现（抓手、多档高度、交互式下滑关闭全部由系统提供）。
/// 只补一件 overlay 时代替不了的事——导航栏里的「历史会话」入口。
struct AIChatSheet: View {
    @Environment(AIHeroState.self) private var aiHero
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            AIChatView()
                .navigationTitle("AI 助手")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("历史会话")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { aiHero.isOpen = false } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭")
                    }
                }
        }
        .sheet(isPresented: $showHistory) {
            AIHistorySheet()
                .presentationDetents([.medium, .large])
        }
    }
}

/// 新建文档 hero：＋ 圆钮放大成整页纸底，随后创建并推入新文档，纸底淡出。
struct PlusZoomOverlay: View {
    let namespace: Namespace.ID

    @Environment(PlusHeroState.self) private var plusHero
    @Environment(DocumentStore.self) private var store

    var body: some View {
        PaperTheme.paper
            .ignoresSafeArea()
            .matchedGeometryEffect(id: plusHero.zoomID, in: namespace)
            .task {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                store.createDocument()
                withAnimation(PaperTheme.Motion.standard) { plusHero.isZooming = false }
            }
    }
}
