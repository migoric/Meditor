import XCTest
@testable import MEditor

/// `WorkspaceUIState.tabsStripWidth(windowWidth:)` 的行为约束。
///
/// 背景：tab 条是 NSToolbar 里的一个 item，macOS 对**超宽**的 toolbar item
/// 不做裁剪，而是把整个 item 塞进「»」溢出菜单 —— 整条 tab 栏凭空消失
/// （#35 修过一次）。所以正确性判据不是「算得准」，而是
/// **「侧栏拖到最宽时也不越界」**：窄了只是右侧多一段与 toolbar 同色的空白，
/// 宽了则完全不可用。
///
/// 历史回归两处，都已由下面的用例钉住：
/// 1. 余量 48 抵 45 实占 → 只剩 3pt（`test_safetyMargin_*`）；
/// 2. 按「侧栏实测宽」扣预算，回传滞后一帧就少扣 100pt（因此改为按列宽上限扣）。
@MainActor
final class TabStripWidthTests: XCTestCase {

    /// 构造 `WorkspaceUIState` 会经 `showsSidebar` 的 `didSet` 写 UserDefaults
    /// （用户真实偏好），用例结束后写回原值。
    private var savedSidebarPref: Bool?
    private var savedEditorPref: Bool?
    private var savedPreviewPref: Bool?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedSidebarPref = d.object(forKey: "MEditor.showSidebarOnLaunch") as? Bool
        savedEditorPref = d.object(forKey: "MEditor.showEditorOnLaunch") as? Bool
        savedPreviewPref = d.object(forKey: "MEditor.showPreviewOnLaunch") as? Bool
    }

    override func tearDown() {
        let d = UserDefaults.standard
        if let v = savedSidebarPref { d.set(v, forKey: "MEditor.showSidebarOnLaunch") }
        if let v = savedEditorPref { d.set(v, forKey: "MEditor.showEditorOnLaunch") }
        if let v = savedPreviewPref { d.set(v, forKey: "MEditor.showPreviewOnLaunch") }
        super.tearDown()
    }

    private func makeState(showsSidebar: Bool = true, sidebarWidth: CGFloat = 260) -> WorkspaceUIState {
        WorkspaceUIState(
            showsSidebar: showsSidebar,
            showsEditor: true,
            showsPreview: true,
            sidebarWidth: sidebarWidth,
            settings: nil
        )
    }

    private var sidebarChrome: CGFloat {
        WorkspaceUIState.tabStripSidebarBudget
            + WorkspaceUIState.tabStripSystemInset
            + WorkspaceUIState.tabStripSafetyMargin
    }

    // MARK: - 基本算式

    func test_subtractsSidebarBudgetAndChrome() {
        let state = makeState()
        // 1400 − (320 侧栏预算 + 45 系统占用 + 40 缓冲)
        XCTAssertEqual(state.tabsStripWidth(windowWidth: 1400), 1400 - sidebarChrome)
    }

    func test_budgetDoesNotDependOnIdealSidebarWidth() {
        let narrow = makeState(sidebarWidth: 220)
        let wide = makeState(sidebarWidth: 320)
        XCTAssertEqual(narrow.tabsStripWidth(windowWidth: 1200),
                       wide.tabsStripWidth(windowWidth: 1200),
                       "预算必须按列宽上限扣，不能跟着 sidebarWidth 变——否则拖宽就少扣")
    }

    func test_sidebarHidden_freesFullWidthMinusChrome() {
        let state = makeState(showsSidebar: false)
        // 1000 − 180（红绿灯 + 系统开关 + 边距）
        XCTAssertEqual(state.tabsStripWidth(windowWidth: 1000), 820)
    }

    func test_focusMode_treatsSidebarAsAbsent() {
        let state = makeState()
        state.isFocusMode = true
        XCTAssertEqual(state.tabsStripWidth(windowWidth: 1000), 820,
                       "专注模式布局里没有侧栏列，不该扣侧栏预算")
    }

    // MARK: - 边界

    func test_unmeasuredWindow_returnsConservativeWidth() {
        let state = makeState()
        XCTAssertEqual(state.tabsStripWidth(windowWidth: 0),
                       WorkspaceUIState.tabStripMinimumWidth,
                       "窗口未测量时给保守值，绝不能用乐观大值在首帧撑破容器")
    }

    func test_veryNarrowWindow_neverGoesBelowMinimum() {
        let state = makeState()
        XCTAssertEqual(state.tabsStripWidth(windowWidth: 300),
                       WorkspaceUIState.tabStripMinimumWidth)
    }

    // MARK: - 安全余量（真正的回归护栏）

    /// tab 条右缘到窗口右缘必须至少留 30pt —— **按侧栏最宽（320）算**。
    ///
    /// 阈值**刻意写死**、不引用 `tabStripSafetyMargin`：若断言跟着常量走，
    /// 把常量改回旧值（3pt）时用例仍然自洽通过，等于没有护栏。
    /// 旧实现在这里只剩 3pt，应当失败。
    func test_safetyMargin_survivesAllWindowWidths() {
        let requiredMargin: CGFloat = 30
        let state = makeState()
        for window in [CGFloat(1600), 1400, 1140, 1000, 900, 760, 620] {
            let strip = state.tabsStripWidth(windowWidth: window)
            // 最坏情况：用户把侧栏拖到上限
            let used = WorkspaceUIState.tabStripSidebarBudget
                + WorkspaceUIState.tabStripSystemInset + strip
            let margin = window - used
            XCTAssertGreaterThanOrEqual(
                margin, requiredMargin,
                "窗口 \(window) 只剩 \(margin)pt 余量（侧栏按最宽 320 算）——"
                + "低于安全缓冲，任何系统占用浮动都会把 tab 条整条送进溢出菜单"
            )
        }
    }

    /// 侧栏从最窄拖到最宽，tab 条都不许越过窗口右缘。
    func test_neverExceedsWindow_forAnySidebarWidth() {
        let state = makeState()
        for window in [CGFloat(1600), 900, 760] {
            let strip = state.tabsStripWidth(windowWidth: window)
            for sidebar in [CGFloat(200), 220, 260, 300, 320] {
                let used = sidebar + WorkspaceUIState.tabStripSystemInset + strip
                XCTAssertLessThanOrEqual(
                    used, window,
                    "窗口 \(window) / 侧栏 \(sidebar)：tab 条右缘超出窗口 \(used - window)pt"
                )
            }
        }
    }
}
