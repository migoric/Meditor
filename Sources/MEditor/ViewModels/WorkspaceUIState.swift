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

    // MARK: - tab 条宽度

    /// 侧栏列宽**预算**，取 `navigationSplitViewColumnWidth` 允许的上限。
    ///
    /// tab 条宽度一律按这个上限扣，而不是按侧栏当前实际宽：侧栏拖多宽都不会
    /// 让预算变紧，越界因而物理上不可能。代价是侧栏窄时 tab 条右侧多一段与
    /// toolbar 同色的空白（最宽 100pt），看不出来；而越界的后果是整条消失。
    static let tabStripSidebarBudget: CGFloat = 320

    /// detail 列里「侧栏开关 + 间距」的实测占用（macOS 26，窗口 560pt 时量得 45pt）。
    /// 系统不保证恒为此值——版本、语言、是否全屏都会微调，所以它只作为预算的**下限**。
    static let tabStripSystemInset: CGFloat = 45

    /// 安全缓冲。tab 条宁可窄一截，也不能越界：macOS 对超宽 toolbar item
    /// **不裁剪**，而是把整个 item 塞进「»」溢出菜单 ⇒ 整条 tab 栏凭空消失。
    static let tabStripSafetyMargin: CGFloat = 40

    /// 宽度下限，兼作「窗口尚未完成首次测量」时的保守取值。
    /// 比单个 tab 的最小宽（104）略大；**不保证**不溢出——它只保证不把宽度
    /// 算成 0。绝不给乐观大值（曾用 1280 兜底，窗口比它窄时首帧就撑破容器）。
    static let tabStripMinimumWidth: CGFloat = 120

    /// toolbar 里 tab 条的宽度。
    ///
    /// 纯函数，单测钉「任何侧栏宽度下都不越界」（见 `TabStripWidthTests`）。
    ///
    /// ⚠️ 不要改回用「侧栏实测宽」：那条链要求 FileSidebar 回传真实列宽，
    /// 一旦回传滞后一帧（拖宽 100pt 时常见），预算就少扣 100pt，tab 条越界。
    func tabsStripWidth(windowWidth: CGFloat) -> CGFloat {
        guard windowWidth > 0 else { return Self.tabStripMinimumWidth }
        let chrome: CGFloat = showsSidebarInLayout
            ? Self.tabStripSidebarBudget + Self.tabStripSystemInset + Self.tabStripSafetyMargin
            : 180                                     // 无侧栏：红绿灯 + 系统开关 + 边距
        return max(Self.tabStripMinimumWidth, windowWidth - chrome)
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
