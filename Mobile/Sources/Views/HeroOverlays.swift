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

/// AI 助手：朱砂浅底小圆徽 + 衬线「墨」——保留品牌印记但去实心重感。
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
                .background(PaperTheme.seal.opacity(0.12), in: Circle())
                .contentShape(Circle())
                .modifier(HeroMatch(id: "ai-\(context)", namespace: heroNS, hidden: aiHero.isOpen))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("AI 助手")
    }
}

// MARK: - Hero 浮层

/// AI 面板：底部上滑入场（iOS sheet 风格）。
struct AIHeroOverlay: View {
    @Environment(AIHeroState.self) private var aiHero
    @State private var contentVisible = false
    @State private var overlayActive = false
    @State private var showHistory = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // 遮罩
            Color.black.opacity(contentVisible ? 0.22 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .allowsHitTesting(overlayActive)

            // 卡片：底部上滑 + 淡入，内容同时出现
            VStack(spacing: 0) {
                Spacer(minLength: 44)
                if contentVisible {
                    VStack(spacing: 0) {
                        // 顶部：抓手居中，左历史右关闭
                        ZStack {
                            Capsule()
                                .fill(PaperTheme.inkSecondary.opacity(0.3))
                                .frame(width: 36, height: 5)
                            HStack {
                                Button { showHistory = true } label: {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(PaperTheme.inkSecondary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.pressable)
                                .accessibilityLabel("历史会话")
                                Spacer()
                                Button { close() } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(PaperTheme.inkSecondary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.pressable)
                                .accessibilityLabel("关闭")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .padding(.bottom, 3)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture().onEnded { value in
                                if value.translation.height > 40 { close() }
                            }
                        )

                        AIChatView()
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .background(PaperTheme.card, in: RoundedRectangle(cornerRadius: PaperTheme.Radius.xlarge, style: .continuous))
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: PaperTheme.Radius.xlarge, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: PaperTheme.Radius.xlarge,
                        style: .continuous
                    ))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .animation(PaperTheme.Motion.standard, value: contentVisible)
            .sheet(isPresented: $showHistory) {
                AIHistorySheet()
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            withAnimation(PaperTheme.Motion.standard) { contentVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { overlayActive = true }
        }
    }

    private func close() {
        withAnimation(PaperTheme.Motion.standard) { contentVisible = false }
        // 等滑出动画完成后才移除 overlay，避免关闭动画被截断
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard contentVisible == false else { return }
            aiHero.isOpen = false
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
