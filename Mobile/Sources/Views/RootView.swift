import SwiftUI
import UniformTypeIdentifiers

/// 根视图：原生 `TabView` 承载「文档 / 设置」两个一级页面（各自独立导航栈），
/// 文档页内 push 进入编辑器。原生 tab 栏隐藏——它放不了「打开 / AI / 新建」
/// 动作钮，与底部附件栏并存还会叠成双层；底部只保留自绘通栏，**单层左右结构**：
/// 左=页面切换胶囊，右=动作胶囊。玻璃用 iOS 26 原生 `.glassEffect`
/// （一条胶囊一层玻璃，内部纯图标——不再玻璃叠玻璃，也不再给容器套大胶囊）。
struct RootView: View {
    @Environment(DocumentStore.self) private var store

    enum Page: Hashable { case home, settings }

    @State private var page: Page = .home
    @State private var showDocument = false
    @State private var aiHero = AIHeroState()
    @State private var plusHero = PlusHeroState()
    @State private var showingFilePicker = false
    /// 打开文件失败的提示（体积超限 / 二进制 / 无权限）。没有它时选完文件毫无反应。
    @State private var importError: String?
    /// hero 连续变形命名空间：＋ 钮放大成整页纸底（`PlusZoomOverlay`）。
    @Namespace private var heroNS
    /// 页面切换胶囊的选中 pill 滑动命名空间（matchedGeometryEffect）。
    @Namespace private var pageIndicator

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
                    .toolbar(.hidden, for: .tabBar)
                }

                Tab("设置", systemImage: "gearshape", value: .settings) {
                    SettingsView()
                        .toolbar(.hidden, for: .tabBar)
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
                    if store.openIncoming(url) {
                        showDocument = true
                    } else {
                        // 同 DocumentHomeView：底栏这个入口失败也必须说清原因，
                        // 否则选完文件什么都不会发生。
                        importError = store.lastError
                    }
                }
            }
            // 从「文件」App / 其他 App 分享进入（原先挂在 App 层，失败时停在首页完全静默——
            // 只有 DocumentView 观察 lastError，而那时它不在视图树里）。
            .onOpenURL { url in
                if store.openIncoming(url) {
                    showDocument = true
                } else {
                    importError = store.lastError
                }
            }
            // AI 面板：原生 sheet（可拖拽抓手 / 多档高度 / 交互式下滑关闭），
            // 状态仍走 AIHeroState，BarAIButton 与文档页的「AI 改写」入口无需改动。
            .sheet(isPresented: aiSheet) {
                AIChatSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert("无法打开文件", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
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
                        } else {
                            // 快捷动作失败同样要回声（文件被移走 / 超限），
                            // 否则长按图标选文档后毫无反应。
                            importError = store.lastError ?? "无法打开该文档，文件可能已被移除。"
                        }
                    }
                }
            }

            // 底部通栏：与 TabView 平级，浮在内容之上；键盘弹出时上推内容但不动底栏。
            // 文档页打开时整条隐藏（该页有自己的底部动作条）。
            VStack(spacing: 0) {
                Spacer()
                if !showDocument {
                    BottomBarView(
                        page: $page,
                        pageIndicator: pageIndicator,
                        showingFilePicker: $showingFilePicker
                    )
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(PaperTheme.Motion.standard, value: showDocument)

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
}

// MARK: - 底部通栏（独立 struct，隔离 page 变化的动画事务）

/// 单层左右结构：左=页面切换胶囊（文档 / 设置），右=动作胶囊（打开 / AI / 新建）。
/// 独立 struct 避免 withAnimation 事务传播到 RootView 其他部分。
/// 玻璃只由胶囊自身承担（`.glassEffect`），内部一律纯图标——曾经犯过的错：
/// 给容器套大胶囊、按钮再各自带玻璃、玻璃钮里嵌圆底，三种叠层采样都会糊。
private struct BottomBarView: View {
    @Binding var page: RootView.Page
    let pageIndicator: Namespace.ID
    @Binding var showingFilePicker: Bool

    var body: some View {
        HStack(spacing: 0) {
            // 左：页面胶囊（一级页面切换，matchedGeometry 滑动选中 pill）
            HStack(spacing: 4) {
                pageButton(.home, icon: "doc.text", label: "文档")
                pageButton(.settings, icon: "gearshape", label: "设置")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)

            Spacer(minLength: 12)

            // 右：动作胶囊（打开 / AI / 新建）
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
            .glassEffect(.regular, in: .capsule)
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
                        Capsule(style: .continuous)
                            .fill(PaperTheme.accentSoft)
                            .matchedGeometryEffect(id: "page-indicator", in: pageIndicator)
                    }
                }
                .contentShape(Capsule())
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: selected)
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
