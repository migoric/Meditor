import SwiftUI
import UniformTypeIdentifiers

/// 根视图：原生 `TabView` 承载「文档 / 设置」两个一级页面，文档页内 push 进入编辑器。
/// 一级页面切换、tab 栏滚动收起、底部附件栏（打开 / AI / 新建）全部走 iOS 原生组件，
/// 不再自绘悬浮胶囊底栏；品牌（朱砂强调色）经 `tint` 注入 tab 栏。
struct RootView: View {
    @Environment(DocumentStore.self) private var store

    enum Page: Hashable { case home, settings }

    @State private var page: Page = .home
    @State private var showDocument = false
    @State private var aiHero = AIHeroState()
    @State private var plusHero = PlusHeroState()
    @State private var showingFilePicker = false
    /// hero 连续变形命名空间：＋ 钮放大成整页纸底（`PlusZoomOverlay`）。
    @Namespace private var heroNS

    private static let importableTypes: [UTType] = [
        .plainText, .html,
        UTType(filenameExtension: "md"),
        UTType(filenameExtension: "markdown"),
    ].compactMap { $0 }

    var body: some View {
        ZStack {
            TabView(selection: $page) {
                Tab("文档", systemImage: "doc.text", value: .home) {
                    NavigationStack {
                        DocumentHomeView(onOpenDocument: { showDocument = true })
                            .navigationDestination(isPresented: $showDocument) {
                                DocumentView()
                            }
                    }
                }

                Tab("设置", systemImage: "gearshape", value: .settings) {
                    SettingsView()
                }
            }
            // 朱砂色染 tab 栏选中态；内容区控件各自显式取 PaperTheme.accent，不受影响
            .tint(PaperTheme.accent)
            // 向下滚动时 tab 栏自动收起（iOS 26 原生行为，替代自绘悬浮栏的显隐逻辑）
            .tabBarMinimizeBehavior(.onScrollDown)
            // 底部附件栏：挂在 tab 栏上的原生附属区，不再自绘玻璃胶囊。
            // 仅文档 tab 显示——打开文件 / AI / 新建都是文档向动作，设置页是表单，
            // 挂上去只是噪音（Safari 的原生底部工具栏同样是按 tab 上下文化的）。
            // 文档页打开时也整块隐藏（该页有自己的底部动作条）。
            .tabViewBottomAccessory {
                if !showDocument && page == .home {
                    bottomAccessory
                }
            }
            // 外部来源（微信传入 / Agent 打开）成功打开自动推进文档页并回到列表 tab；
            // 文档被删除则退回列表。列表内打开走 onOpenDocument 闭包（同一篇重开也有效）。
            .onChange(of: store.sandboxURL) { _, url in
                showDocument = url != nil
                if url != nil { page = .home }
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
            // AI 面板：原生 sheet（可拖拽抓手 / 多档高度 / 交互式下滑关闭），
            // 状态仍走 AIHeroState，BarAIButton 与文档页的「AI 改写」入口无需改动。
            .sheet(isPresented: aiSheet) {
                AIChatSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task(priority: .low) {
                // 首帧后预热 WKWebView 进程（无 JS），mermaid 文档打开时省去进程创建
                MermaidRenderer.shared.prewarm()
            }
            .task {
                for await action in QuickActionHandler.shared.stream {
                    switch action {
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

            // ＋ 新建 hero：圆钮放大成整页纸底，随后创建并推入新文档，纸底淡出。
            // matchedGeometryEffect 是 SwiftUI 原生 API，品牌连续性不靠自绘 chrome。
            if plusHero.isZooming {
                PlusZoomOverlay(namespace: heroNS)
            }
        }
        .environment(aiHero)
        .environment(plusHero)
        .environment(\.heroNamespace, heroNS)
    }

    /// AI sheet 的呈现绑定：直接读 AIHeroState，避免再造一份平行状态。
    private var aiSheet: Binding<Bool> {
        Binding(
            get: { aiHero.isOpen },
            set: { aiHero.isOpen = $0 }
        )
    }

    // MARK: - 底部附件栏

    /// 挂在 tab 栏上的原生附属区：左「打开文件」，右「AI 助手 / 新建」。
    /// iOS 26 玻璃的正确用法：多个交互元素同置 `GlassEffectContainer`，
    /// **每个元素各自** `.buttonStyle(.glass)`，容器只统一采样——不要给容器
    /// 整体再套一层 `.glassEffect(in: .capsule)`，那样整条会糊成一实色块，
    /// 与下面的原生 tab 栏胶囊叠成「双层抽屉把手」。
    /// 文档页打开时整块隐藏（该页有自己的底部动作条）。
    /// 挂在 tab 栏上的原生附属区：打开文件 / AI 助手 / 新建，通栏等距分布。
    /// 实证：系统为 `tabViewBottomAccessory` 自带整条玻璃背景（探针实验：
    /// 内容只放一个 Text 也照常出现玻璃条），因此按钮**不再**各自
    /// `.buttonStyle(.glass)`——那是玻璃叠玻璃；图标直接落在系统玻璃条上，
    /// 即 Safari 底部工具栏 + tab 栏的原生组合形态。
    /// 文档页打开时整块隐藏（该页有自己的底部动作条）。
    private var bottomAccessory: some View {
        HStack(spacing: 0) {
            Button { showingFilePicker = true } label: {
                Image(systemName: "folder")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(PaperTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("打开文件")

            BarAIButton(context: "root")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())

            BarPlusButton(context: "root")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
    }
}
