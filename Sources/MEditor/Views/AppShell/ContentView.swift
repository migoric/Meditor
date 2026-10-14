import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var workspaceUI = WorkspaceUIState()
    @State private var settings = AppSettings.shared
    /// 窗口内容区实测宽度（GeometryReader 回传），用于动态计算 tab 条宽度。
    @State private var windowContentWidth: CGFloat = 1280

    /// toolbar 里 tab 条的宽度。NavigationSplitView 的 toolbar 按列分段：
    /// tab 条只能占 detail 列那段。可用宽度 = 窗口宽 - 侧栏（可见时） - 边距。
    ///
    /// ⚠️ 估宽 item 会被整体塞进 ">>" 溢出菜单（整条 tab 栏直接消失）。
    /// 两个要点：
    /// 1. 侧栏宽必须用**实测**值（`measuredSidebarWidth`，由 FileSidebar 的
    ///    GeometryReader 回传），不能用 `clampedSidebarWidth` 那个理想宽 260 ——
    ///    用户把侧栏拖到 320 时按 260 算，tab 条就超出 detail 列了。
    /// 2. 宁可**多留**空白也不溢出：多留的尾部空白与 toolbar 同色、看不出来；
    ///    溢出则整个 tab 条消失。所以余量给足（48pt 覆盖系统按钮与分隔线）。
    private var tabsStripWidth: CGFloat {
        let chrome: CGFloat = workspaceUI.showsSidebarInLayout
            ? workspaceUI.effectiveSidebarWidthForLayout() + 48
            : 180                                     // 红绿灯 + 系统开关 + 边距
        return max(240, windowContentWidth - chrome)
    }

    var body: some View {
        Group {
            if state.rootURL == nil {
                welcomeScreen
            } else {
                mainLayout
            }
        }
        .preferredColorScheme(state.themeStore.current.isDark ? .dark : .light)
        // 专注模式：整条 toolbar（含 tab 条）隐藏，只留文档
        .focusToolbarVisibility(workspaceUI.isFocusMode)
        // Global accent — the AI-assistant accent style is applied app-wide so
        // every control (create buttons, pickers, toggles, selection highlights)
        // honors the user's choice (system blue vs shadcn mono).
        .tint(AIAccentStyle.current(settings).fill(state.themeStore.current))
        .environment(workspaceUI)
        .background(WindowConfigurator())
        // tab 栏进系统 toolbar——顶部只有一条横带：左端系统侧栏开关，接着是文件 tab。
        // 注意：SwiftUI 的 toolbar item 定死在理想宽度，不会弹性伸缩——
        // ScrollView 默认理想宽 = 所有 tab 宽度之和，超宽会被整体塞进 ">>" 溢出菜单；
        // 定死宽度又会在右侧留空。所以宽度跟随窗口实测：窗口宽 - 左侧系统件与边距。
        .toolbar {
            // 没有打开的文件时整个 item 移除——空壳固定宽度会在 toolbar 上
            // 留下一条可见的空白胶囊（欢迎页尤其明显）。
            if !state.openTabs.isEmpty {
                // automatic（跟随系统侧栏开关之后左对齐）而不是 principal（居中），
                // 否则 tab 条悬浮在横带中央、左右都是空当，看起来很奇怪。
                ToolbarItem(placement: .automatic) {
                    EditorTabBar()
                        .frame(width: tabsStripWidth)
                        .environment(state)
                }
                .hideSharedGlassBackgroundIfAvailable()
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowContentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, w in windowContentWidth = w }
            }
        )
        .overlayPreferenceValue(SettingsAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if state.showingSettings {
                    let rect: CGRect = anchor.map { proxy[$0] }
                        ?? CGRect(x: proxy.size.width / 2, y: proxy.size.height, width: 0, height: 0)
                    SettingsHeroOverlay(originRect: rect, containerSize: proxy.size)
                        .environment(state)
                        .environment(workspaceUI)
                }
            }
        }
        .overlayPreferenceValue(AIAssistantAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if state.showingAIAssistant {
                    let rect: CGRect = anchor.map { proxy[$0] }
                        ?? CGRect(x: proxy.size.width, y: proxy.size.height, width: 0, height: 0)
                    AIAssistantHeroOverlay(originRect: rect, containerSize: proxy.size)
                        .environment(state)
                        .environment(workspaceUI)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { state.showingBeautifySheet },
            set: { state.showingBeautifySheet = $0 }
        )) {
            BeautifySheet()
                .environment(state)
                .environment(settings)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(
            get: { state.showingQuickOpen },
            set: { state.showingQuickOpen = $0 }
        )) {
            QuickOpenSheet()
                .environment(state)
                .environment(workspaceUI)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(
            get: { state.showingGlobalSearch },
            set: { state.showingGlobalSearch = $0 }
        )) {
            GlobalSearchSheet()
                .environment(state)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(
            get: { state.showingDiagnostics },
            set: { state.showingDiagnostics = $0 }
        )) {
            DiagnosticsSheet()
                .environment(state)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(
            get: { state.showingTemplatePicker },
            set: { state.showingTemplatePicker = $0 }
        )) {
            TemplatePickerSheet(store: state.templateManager.store) { template in
                state.createFromTemplate(template)
            }
            .environment(state)
            .presentationBackground(.regularMaterial)
        }
        .alert(L("template.saveTitle"), isPresented: Binding(
            get: { state.showingSaveTemplate },
            set: { state.showingSaveTemplate = $0 }
        )) {
            TextField(L("template.namePlaceholder"), text: Binding(
                get: { state.saveTemplateName },
                set: { state.saveTemplateName = $0 }
            ))
            Button(L("common.save")) {
                state.saveCurrentAsTemplate(name: state.saveTemplateName)
                state.saveTemplateName = ""
                state.showingSaveTemplate = false
            }
            Button(L("common.cancel"), role: .cancel) {
                state.saveTemplateName = ""
                state.showingSaveTemplate = false
            }
        } message: {
            Text(L("template.saveMessage"))
        }
        .alert(L("alert.errorTitle"), isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button(L("common.ok")) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert(L("alert.saveChangesTitle"), isPresented: Binding(
            get: { state.showingCloseConfirmation },
            set: { if !$0 { state.showingCloseConfirmation = false; state.pendingCloseTab = nil } }
        )) {
            Button(L("common.save"), role: .none) { state.confirmCloseTab(save: true) }
            Button(L("alert.dontSave"), role: .destructive) { state.confirmCloseTab(save: false) }
            Button(L("common.cancel"), role: .cancel) { state.showingCloseConfirmation = false; state.pendingCloseTab = nil }
        } message: {
            if let tab = state.pendingCloseTab {
                Text(L("alert.saveChangesMessage", tab.name))
            }
        }
        .alert(L("alert.largeFile"), isPresented: Binding(
            get: { state.showingLargeFileWarning },
            set: { if !$0 { state.showingLargeFileWarning = false; state.pendingLargeFile = nil } }
        )) {
            Button(L("alert.openAnyway"), role: .none) {
                if let item = state.pendingLargeFile {
                    state.showingLargeFileWarning = false
                    state.pendingLargeFile = nil
                    state.openFileUnchecked(item)
                }
            }
            Button(L("common.cancel"), role: .cancel) {
                state.showingLargeFileWarning = false
                state.pendingLargeFile = nil
            }
        } message: {
            if let item = state.pendingLargeFile {
                Text(L("alert.largeFileMessage", item.name))
            }
        }
        // Close Project confirmation — prevents accidental data loss from the menu item.
        .confirmationDialog(
            "Close Project?",
            isPresented: Binding(
                get: { state.showingCloseProjectConfirmation },
                set: { state.showingCloseProjectConfirmation = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                state.showingCloseProjectConfirmation = false
                state.rootURL = nil
                state.openTabs.removeAll()
                state.selectedTabID = nil
                state.fileTreeManager.clear()
                state.clearPreview()
            }
            Button("Cancel", role: .cancel) {
                state.showingCloseProjectConfirmation = false
            }
        } message: {
            Text("All open tabs will be closed. Unsaved changes will be lost.")
        }
        // Diff review is now inline inside AppShell's document area (no overlay).
    }

    private var welcomeScreen: some View {
        WelcomeView(
            onOpenFolder: openFolder,
            onOpenRecent: { url in state.openFolder(url) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background bleeds into titlebar — no visible separator
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: .top)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var mainLayout: some View {
        AppShell(workspaceUI: workspaceUI, onExport: performExport) {
            sidebarColumn
        } editor: {
            editorColumn
        } preview: {
            previewColumn
        }
        .toastOverlay(message: Binding(
            get: { state.toastMessage },
            set: { state.toastMessage = $0 }
        ))
        .claudeFilePromptOverlay(prompt: Binding(
            get: { state.claudeFilePrompt },
            set: { state.claudeFilePrompt = $0 }
        ))
        // 挂在 mainLayout 而非顶层 body：顶层修饰链已逼近编译器类型检查时限
        .exportSheets(state: state, settings: settings)
        .localHistorySheet(state: state)
    }

    private var sidebarColumn: some View {
        FileSidebar()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorColumn: some View {
        EditorView()
            .background(state.themeStore.current.editorBackground)
    }

    private var previewColumn: some View {
        PreviewPanel()
            .background(state.themeStore.current.editorBackground)
    }

    private func performExport(_ format: PreviewExporter.ExportFormat) {
        state.requestExport(format)
    }

    // MARK: - Actions

    private func openFolder() {
        Task {
            if let url = await state.filePickerService.pickFolder(message: L("panel.chooseFolder")) {
                state.openFolder(url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isDirectory = isDir.boolValue
            DispatchQueue.main.async {
                if isDirectory {
                    state.openFolder(url)
                } else {
                    state.openFile(FileItem(url: url, isDirectory: false))
                }
            }
        }
        return true
    }
}

private extension View {
    /// 专注模式时隐藏整条 window toolbar；低版本系统没有该 API，直接透传。
    /// compiler 守卫：API 在 macOS 15 SDK（Xcode 16 / Swift 6.0）才存在，
    /// 旧 Xcode 本地构建时编译期找不到符号。
    @ViewBuilder
    func focusToolbarVisibility(_ hidden: Bool) -> some View {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            self.toolbarVisibility(hidden ? .hidden : .visible, for: .windowToolbar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private extension View {
    /// 导出相关 sheet（功能7 检查清单 / 功能9 PDF 选项）。
    /// 抽成修饰器：ContentView.body 已接近编译器类型检查时限，再加两个 sheet 会超时。
    func exportSheets(state: AppState, settings: AppSettings) -> some View {
        modifier(ExportSheetsModifier(state: state, settings: settings))
    }
}

private struct ExportSheetsModifier: ViewModifier {
    let state: AppState
    let settings: AppSettings

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { state.exportPreflight },
                set: { state.exportPreflight = $0 }
            )) { context in
                ExportPreflightSheet(context: context)
                    .environment(state)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: Binding(
                get: { state.showingPDFExportOptions },
                set: { state.showingPDFExportOptions = $0 }
            )) {
                PDFExportOptionsSheet()
                    .environment(state)
                    .environment(settings)
                    .presentationBackground(.regularMaterial)
            }
    }
}

private extension ToolbarContent {
    /// macOS 26 Liquid Glass：同一逻辑分组内的 toolbar item（这里是侧栏开关
    /// 和文件 tab 条）会被自动分到同一个共享玻璃背景容器里——即便 tab 条
    /// 自己的内容完全铺满了分配到的宽度，容器边缘仍会露出一块系统默认的圆角
    /// 玻璃背景（尤其是窗口刚打开、还没有任何交互触发系统重绘的那一帧）。
    /// `ToolbarItemGlassDisabler`（EditorTabBar.swift）通过 NSToolbarItem.
    /// isBordered 硬拆，但那条路径依赖异步时序，多次尝试都还是能看到首帧
    /// 露边——这里改用官方声明式 API，在 SwiftUI 渲染阶段就正确处理，没有
    /// NSViewRepresentable 那种「等下一次系统重绘生效」的竞争问题。
    /// compiler 守卫：API 在 macOS 26 SDK（Xcode 26 / Swift 6.2）才存在。
    @ToolbarContentBuilder
    func hideSharedGlassBackgroundIfAvailable() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
