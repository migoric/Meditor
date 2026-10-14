import XCTest
@testable import MEditor

/// `WorkspaceUIState` 里「实测侧栏宽」的行为约束。
///
/// 背景：toolbar 里 tab 条的宽度必须按侧栏的**真实**列宽算。用理想宽
/// （`sidebarWidth`，固定 260）估算时，用户把侧栏拖到 320 会让 tab 条超出
/// detail 列，macOS 直接把整个 toolbar item 塞进 ">>" 溢出菜单——整条 tab 栏
/// 消失（左侧面板展开后 tab 不显示的根因）。
@MainActor
final class WorkspaceUIStateSidebarWidthTests: XCTestCase {

    /// 构造 `WorkspaceUIState` 会经 `showsSidebar` 的 `didSet` 写 UserDefaults
    /// （`AppSettings.showSidebarOnLaunch`）—— 那是开发机/用户真实偏好。
    /// 所以每个用例结束后把原值写回，不让测试留下持久化副作用。
    private var savedSidebarPrefs: [Bool] = []
    private var savedEditorPrefs: [Bool] = []
    private var savedPreviewPrefs: [Bool] = []

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedSidebarPrefs = [d.object(forKey: "MEditor.showSidebarOnLaunch") != nil
            ? d.bool(forKey: "MEditor.showSidebarOnLaunch") : true]
        savedEditorPrefs = [d.object(forKey: "MEditor.showEditorOnLaunch") != nil
            ? d.bool(forKey: "MEditor.showEditorOnLaunch") : true]
        savedPreviewPrefs = [d.object(forKey: "MEditor.showPreviewOnLaunch") != nil
            ? d.bool(forKey: "MEditor.showPreviewOnLaunch") : true]
    }

    override func tearDown() {
        let d = UserDefaults.standard
        if let v = savedSidebarPrefs.first { d.set(v, forKey: "MEditor.showSidebarOnLaunch") }
        if let v = savedEditorPrefs.first { d.set(v, forKey: "MEditor.showEditorOnLaunch") }
        if let v = savedPreviewPrefs.first { d.set(v, forKey: "MEditor.showPreviewOnLaunch") }
        super.tearDown()
    }

    private func makeState(showsSidebar: Bool = true, sidebarWidth: CGFloat = 260) -> WorkspaceUIState {
        WorkspaceUIState(
            showsSidebar: showsSidebar,
            showsEditor: true,
            showsPreview: true,
            sidebarWidth: sidebarWidth,
            settings: nil   // 走默认 AppSettings.shared
        )
    }

    // MARK: - 回落：未实测时用理想宽

    func test_effectiveWidth_fallsBackToIdealWidth_beforeMeasurement() {
        let state = makeState()
        XCTAssertNil(state.measuredSidebarWidth)
        XCTAssertEqual(state.effectiveSidebarWidthForLayout(), state.clampedSidebarWidth)
    }

    func test_effectiveWidth_usesMeasuredWidth_whenAvailable() {
        let state = makeState(sidebarWidth: 260)
        state.setMeasuredSidebarWidth(320, isVisible: true)
        XCTAssertEqual(state.effectiveSidebarWidthForLayout(), 320,
                       "实测值必须优先于理想宽——这正是 tab 条消失的修复点")
    }

    func test_effectiveWidth_isZero_whenSidebarHidden() {
        let state = makeState(showsSidebar: false)
        state.setMeasuredSidebarWidth(300, isVisible: false)
        XCTAssertEqual(state.effectiveSidebarWidthForLayout(), 0,
                       "侧栏收起时不占用 toolbar 分段，不该扣宽度")
    }

    // MARK: - 焦点模式：布局里没有侧栏

    func test_effectiveWidth_isZero_inFocusMode_evenWhenMeasured() {
        let state = makeState()
        state.setMeasuredSidebarWidth(300, isVisible: true)
        state.isFocusMode = true
        XCTAssertFalse(state.showsSidebarInLayout)
        XCTAssertEqual(state.effectiveSidebarWidthForLayout(), 0)
    }

    // MARK: - 收起时清空实测值

    func test_hidingSidebar_clearsMeasuredWidth() {
        let state = makeState()
        state.setMeasuredSidebarWidth(300, isVisible: true)
        XCTAssertNotNil(state.measuredSidebarWidth)

        state.setMeasuredSidebarWidth(0, isVisible: false)
        XCTAssertNil(state.measuredSidebarWidth,
                     "侧栏收起后必须清空，否则下次展开瞬间会沿用陈旧宽度算错 tab 条")
    }

    func test_hidingSidebar_isIdempotent() {
        let state = makeState()
        state.setMeasuredSidebarWidth(0, isVisible: false)
        state.setMeasuredSidebarWidth(0, isVisible: false)
        XCTAssertNil(state.measuredSidebarWidth)
    }

    // MARK: - 量化：拖拽时每帧回传不应造成连续失效通知

    func test_measuredWidth_snappedToHalfPoint() {
        let state = makeState()
        state.setMeasuredSidebarWidth(300.37, isVisible: true)
        XCTAssertEqual(state.measuredSidebarWidth, 300.5, "量化到 0.5pt，避免拖拽时逐帧失效")
        state.setMeasuredSidebarWidth(300.62, isVisible: true)
        XCTAssertEqual(state.measuredSidebarWidth, 300.5, "量化后相同值不应再次写回")
    }

    // MARK: - 不回喂 sidebarWidth（防自激）

    func test_measurement_doesNotMutateIdealWidth() {
        let state = makeState(sidebarWidth: 260)
        state.setMeasuredSidebarWidth(320, isVisible: true)
        XCTAssertEqual(state.sidebarWidth, 260,
                       "实测值不能回喂 sidebarWidth——否则「设 ideal → 布局变 → 再设 ideal」会自激")
        XCTAssertEqual(state.clampedSidebarWidth, 260)
    }
}