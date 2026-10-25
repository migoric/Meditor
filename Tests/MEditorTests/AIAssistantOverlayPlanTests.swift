import XCTest
@testable import MEditor

/// 浮层可见性取值：diff 审阅期间 AI 面板必须整层让位。
///
/// 这条约束背后的 bug：diff 审阅挂在文档区（`AppShell`）、浮层挂在 `ContentView`，
/// 后者天然更高一层 —— 420×620 的面板 + 30% 全窗遮罩把 HITL 唯一的确认界面盖住，
/// 用户看不到自己要批准什么。断言不出来就会退化回去（SwiftUI 视图层级没有快照
/// 测试，只能把判定抽成纯值来钉）。
final class AIAssistantOverlayPlanTests: XCTestCase {

    func testMountedAndExpandedShowsPanelWithDim() {
        let plan = AIAssistantOverlayPlan.resolve(
            panelMounted: true, expanded: true, diffReviewPresented: false
        )
        XCTAssertEqual(plan.dimOpacity, AIAssistantOverlayPlan.backgroundDim)
        XCTAssertEqual(plan.panelOpacity, 1)
        XCTAssertTrue(plan.isInteractive)
    }

    /// 挂载了但展开动画还没跑起来（首帧）：面板透明、无遮罩，但已经可以点。
    func testMountedButCollapsedIsTransparentYetInteractive() {
        let plan = AIAssistantOverlayPlan.resolve(
            panelMounted: true, expanded: false, diffReviewPresented: false
        )
        XCTAssertEqual(plan.dimOpacity, 0)
        XCTAssertEqual(plan.panelOpacity, 0)
        XCTAssertTrue(plan.isInteractive)
    }

    /// 核心用例：审阅期间三层输出全部归零 —— 面板不能挡、遮罩不能压暗、
    /// 更不能吃掉点击与 Esc（否则按 Esc 关掉的是背后那个看不见的面板）。
    func testDiffReviewMakesTheWholeOverlayYield() {
        let plan = AIAssistantOverlayPlan.resolve(
            panelMounted: true, expanded: true, diffReviewPresented: true
        )
        XCTAssertEqual(plan.dimOpacity, 0, "审阅期间遮罩必须撤掉，否则确认界面被压暗")
        XCTAssertEqual(plan.panelOpacity, 0, "审阅期间面板必须不可见")
        XCTAssertFalse(plan.isInteractive, "审阅期间整层不能接收点击/键盘")
    }

    /// 没挂载就没有遮罩 —— 不能因为 `expanded` 残留 true 就在空壳上压一层黑。
    func testUnmountedPanelHasNoDim() {
        let plan = AIAssistantOverlayPlan.resolve(
            panelMounted: false, expanded: true, diffReviewPresented: false
        )
        XCTAssertEqual(plan.dimOpacity, 0)
        XCTAssertEqual(plan.panelOpacity, 0)
        XCTAssertFalse(plan.isInteractive)
    }
}
