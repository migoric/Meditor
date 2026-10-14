import SwiftUI
import UniformTypeIdentifiers

/// 根视图：文档列表 / 设置 两个一级页面（底部页面胶囊切换），文档页推送进入。
/// 底部栏毛玻璃态：左=页面胶囊，右=＋新建与 AI + 打开（均带 hero 展开动画）。
struct RootView: View {
    @Environment(DocumentStore.self) private var store

    enum Page { case home, settings }

    @State private var page: Page = .home
    @State private var showDocument = false
    @State private var aiHero = AIHeroState()
    @State private var plusHero = PlusHeroState()
    @State private var showingFilePicker = false
    @Namespace private var heroNS
    @Namespace private var pageIndicator

    private static let importableTypes: [UTType] = [
        .plainText, .html,
        UTType(filenameExtension: "md"),
        UTType(filenameExtension: "markdown"),
    ].compactMap { $0 }

    var body: some View {
        ZStack {
            // 内容层：填满全屏，键盘弹出时自行上推
            NavigationStack {
                ZStack {
                    DocumentHomeView(onOpenDocument: { showDocument = true })
                        .opacity(page == .home ? 1 : 0)
                        .allowsHitTesting(page == .home)
                        // 不可见页必须移出无障碍树：opacity(0) 本身不移除，
                        // VoiceOver 会读到两页元素，焦点顺序按 ZStack 层序而非可见页。
                        .accessibilityHidden(page != .home)
                    SettingsView()
                        .opacity(page == .settings ? 1 : 0)
                        .allowsHitTesting(page == .settings)
                        .accessibilityHidden(page != .settings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(PaperTheme.Motion.standard, value: page)
                .navigationDestination(isPresented: $showDocument) {
                    DocumentView()
                }
            }
            // 外部来源（微信传入 / Agent 打开）的成功打开自动推进文档页；
            // 文档被删除则退回列表。列表内打开走 onOpenDocument 闭包（同一篇重开也有效）。
            .onChange(of: store.sandboxURL) { _, url in
                showDocument = url != nil
            }
            .onAppear {
                if store.hasDocument {
                    DispatchQueue.main.async { showDocument = true }
                }
                #if DEBUG
                // 设计走查：自动展开 AI 面板（配合 ChatModel 的演示会话注入）
                if UserDefaults.standard.bool(forKey: "debugSeedChat") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { aiHero.isOpen = true }
                }
                #endif
            }

            // 底栏层：与 NavigationStack 平级，浮在内容之上；键盘弹出时上推内容但不动底栏
            VStack(spacing: 0) {
                Spacer()
                if !showDocument {
                    bottomBar
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(PaperTheme.Motion.standard, value: showDocument)

            // hero 浮层：盖在所有之上
            if aiHero.isOpen {
                AIHeroOverlay()
            }
            if plusHero.isZooming {
                PlusZoomOverlay(namespace: heroNS)
            }
        }
        .environment(aiHero)
        .environment(plusHero)
        .environment(\.heroNamespace, heroNS)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.openIncoming(url)
                if store.lastError == nil { showDocument = true }
            }
        }
        .task(priority: .low) {
            // 首帧后预热 WKWebView 进程（无 JS），mermaid 文档打开时省去进程创建
            MermaidRenderer.shared.prewarm()
        }
        .task {
            for await action in QuickActionHandler.shared.stream {                switch action {
                case .newDocument:
                    page = .home
                    store.createDocument()
                    showDocument = true
                case .openFile:
                    page = .home
                    showingFilePicker = true
                case .openRecent(let path):
                    let url = store.workspace.appendingPathComponent(path)
                    if store.loadFromSandbox(url) {
                        page = .home
                        showDocument = true
                    }
                }
            }
        }
    }

    // MARK: - 底部栏

    private var bottomBar: some View {
        BottomBarView(page: $page, pageIndicator: pageIndicator, showingFilePicker: $showingFilePicker)
    }
}

// MARK: - 底部栏（独立 struct，隔离 page 变化的动画事务）

/// 整条底部栏：页面切换胶囊 + 动作按钮。
/// 独立 struct 避免 withAnimation 事务传播到 RootView 其他部分。
private struct BottomBarView: View {
    @Binding var page: RootView.Page
    let pageIndicator: Namespace.ID
    @Binding var showingFilePicker: Bool

    var body: some View {
        HStack(spacing: 0) {
            // 页面胶囊：文档 / 设置（一级页面，matchedGeometry 滑动）
            HStack(spacing: 4) {
                pageButton(.home, icon: "doc.text", label: "文档")
                pageButton(.settings, icon: "gearshape", label: "设置")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(GlassCapsuleBackground())

            Spacer()

            ActionButtons(showingFilePicker: $showingFilePicker)
                .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }

    private func pageButton(_ item: RootView.Page, icon: String, label: String) -> some View {
        let selected = page == item
        return Button {
            withAnimation(PaperTheme.Motion.standard) { page = item }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .symbolEffect(.bounce, value: selected)
                .foregroundStyle(selected ? PaperTheme.accent : PaperTheme.inkSecondary)
                .frame(width: 52)
                .padding(.vertical, 8)
                .background {
                    if selected {
                        GlassSelection(indicator: pageIndicator)
                    }
                }
                .contentShape(Capsule())
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: selected)
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

// MARK: - 选中玻璃指示器（毛玻璃 + TimelineView 流光 shimmer）

/// 胶囊切换的选中 pill：与底栏 GlassCapsuleBackground 统一语言的玻璃质感，
/// 带周期性流光扫过，让表面有真实玻璃的反射感。
/// 使用 TimelineView 驱动 shimmer，不触发 SwiftUI 视图重建，不影响父视图。
private struct GlassSelection: View {
    let indicator: Namespace.ID

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Capsule(style: .continuous)
            .fill(.thickMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(PaperTheme.accent.opacity(0.15))
            }
            .overlay {
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3) / 3
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .white.opacity(0),
                                .white.opacity(0.12),
                                .white.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: geo.size.width * (t * 1.4 - 0.7))
                        .blur(radius: 6)
                        .mask(Capsule(style: .continuous))
                    }
                    // shimmer 每 50ms 重绘一帧：gradient + blur + mask 的图层树若逐帧
                    // 重建会持续消耗 CPU/GPU。drawingGroup() 把整条链光栅化到离屏位图，
                    // 后续帧只平移位图（与 DotGridBackground 同一处理）。
                    .drawingGroup()
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(PaperTheme.hairline, lineWidth: PaperTheme.Stroke.hairline)
            }
            .shadow(color: .black.opacity(isDark ? 0.25 : 0.08), radius: 4, y: 2)
            .matchedGeometryEffect(id: "page-indicator", in: indicator)
    }
}

// MARK: - 动作胶囊（隔离刷新，不受页面切换影响）

/// 右胶囊：打开 + AI + 新建，独立 struct 避免因 page 变化触发父视图重算。
private struct ActionButtons: View {
    @Binding var showingFilePicker: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { showingFilePicker = true } label: {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PaperTheme.ink)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("打开文件")

            BarAIButton(context: "root")
            BarPlusButton(context: "root")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(GlassCapsuleBackground())
    }
}
