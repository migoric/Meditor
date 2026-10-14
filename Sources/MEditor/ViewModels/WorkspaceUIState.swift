import Observation
import SwiftUI

enum ActiveMainView {
    case document, todos, calendar
}

@MainActor
@Observable
final class WorkspaceUIState {
    private let settings: AppSettings

    var showsSidebar: Bool {
        didSet { settings.showSidebarOnLaunch = showsSidebar }
    }

    var showsEditor: Bool {
        didSet { settings.showEditorOnLaunch = showsEditor }
    }

    var showsPreview: Bool {
        didSet { settings.showPreviewOnLaunch = showsPreview }
    }

    var sidebarWidth: CGFloat
    var isFocusMode = false
    var activeMainView: ActiveMainView = .document
    /// 侧栏**实测**列宽（由 FileSidebar 上的 GeometryReader 回传）。
    ///
    /// 为什么与 `sidebarWidth` 分开存：`sidebarWidth` 是理想宽（喂给
    /// `navigationSplitViewColumnWidth(ideal:)`），而 toolbar 里 tab 条的宽度
    /// 必须按**真实**列宽算——侧栏可由用户拖到 220...320，用理想宽 260 估算
    /// 会让 tab 条比 detail 列实际可用宽度更宽，macOS 直接把整个 toolbar
    /// item 塞进 ">>" 溢出菜单（整条 tab 栏消失）。
    ///
    /// ⚠️ 这里**不能**回喂 `sidebarWidth`，否则「设 ideal → 布局变化 → 再设
    /// ideal」会自激。两者单向：sidebarWidth → 布局 → measuredSidebarWidth。
    private(set) var measuredSidebarWidth: CGFloat?
    var expandedPaths: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "sidebar.expandedPaths") ?? [])
    }()

    func setExpanded(_ item: FileItem, _ expanded: Bool) {
        if expanded { expandedPaths.insert(item.url.path) }
        else { expandedPaths.remove(item.url.path) }
        UserDefaults.standard.set(Array(expandedPaths), forKey: "sidebar.expandedPaths")
    }

    init(settings: AppSettings? = nil) {
        let settings = settings ?? .shared
        self.settings = settings
        self.showsSidebar = settings.showSidebarOnLaunch
        self.showsEditor = settings.showEditorOnLaunch
        self.showsPreview = settings.showPreviewOnLaunch
        self.sidebarWidth = 260
    }

    init(
        showsSidebar: Bool,
        showsEditor: Bool,
        showsPreview: Bool,
        sidebarWidth: CGFloat = 260,
        settings: AppSettings? = nil
    ) {
        self.settings = settings ?? .shared
        self.showsSidebar = showsSidebar
        self.showsEditor = showsEditor
        self.showsPreview = showsPreview
        self.sidebarWidth = sidebarWidth
    }

    var hasVisibleWorkspacePane: Bool {
        showsEditor || showsPreview
    }

    var showsSidebarInLayout: Bool {
        showsSidebar && !isFocusMode
    }

    var clampedSidebarWidth: CGFloat {
        min(max(sidebarWidth, 200), 320)
    }

    /// tab 条宽度计算该用的侧栏宽：实测优先（侧栏可见时才有实测值）。
    func effectiveSidebarWidthForLayout() -> CGFloat {
        guard showsSidebarInLayout else { return 0 }
        return measuredSidebarWidth ?? clampedSidebarWidth
    }

    /// 由侧栏内容的 GeometryReader 回传真实列宽。`isVisible` 为 false（侧栏收起）
    /// 时清空实测值，避免下次展开瞬间沿用陈旧宽度算错 tab 条。
    func setMeasuredSidebarWidth(_ width: CGFloat, isVisible: Bool) {
        guard isVisible else {
            if measuredSidebarWidth != nil { measuredSidebarWidth = nil }
            return
        }
        // 量化到 0.5pt：拖拽时每帧都会回传，量化后避免无意义的连续失效通知。
        let snapped = (width * 2).rounded() / 2
        if measuredSidebarWidth != snapped { measuredSidebarWidth = snapped }
    }

    func toggleSidebar() {
        showsSidebar.toggle()
    }

    func toggleEditor() {
        showsEditor.toggle()
    }

    func togglePreview() {
        showsPreview.toggle()
    }

    func toggleFocusMode() {
        isFocusMode.toggle()
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width, 200), 320)
    }
}
