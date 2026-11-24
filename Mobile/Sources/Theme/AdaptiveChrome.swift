import SwiftUI

/// 宽画布（iPhone Duo 内屏 / iPad）的布局上限。
///
/// 为什么只封顶、不按机型或尺寸类分支：
/// - Apple 对 iPhone Duo 的布局要求只有一条硬约束——**按尺寸类布局，不看方向、不看 idiom**。
///   内屏（7.6"）是 regular × regular，外屏（5.4"）与普通 iPhone 一致，且内屏
///   **不遵循** `UISupportedInterfaceOrientations`：展开后 `UIDevice.orientation`、
///   `windowScene.effectiveGeometry.interfaceOrientation` 都不再等价于窗口形状。
/// - `maxWidth` 只封顶、不撑开：393pt 的 iPhone 上取的就是原值 ⇒ compact 下零副作用。
///   所以这里不需要 `horizontalSizeClass` 分支，也就不存在「尺寸类判断错」这类隐性 bug。
///
/// ⚠️ 本机 SDK 是 Xcode 26.0 / iOS 26.0，**不包含**任何 Duo 专属 API：
/// `defaultTabBarPlacement`、`reservedRegion`、`ArrangementView`、`axisBehavior`、
/// `ToolbarOverflowMenu` 在 `SwiftUI.swiftinterface` 里全部查无此符号。
/// 因此这里只做与 SDK 无关的适配；27 / 27.1 的迁移清单见 `docs/iphone-duo.md`。
enum AdaptiveChrome {
    /// 正文可读宽度上限（pt）。17pt 正文 ≈ 每行 40 个汉字 / 75 个西文字符。
    /// 没有它时，7.6" 内屏展开后正文栏会拉到 1000pt 以上，一行能塞 90 个汉字。
    static let readingColumn: CGFloat = 720

    /// 悬浮动作栏（两条胶囊）的最大宽度。原实现靠 `Spacer` 把两簇贴到屏幕两侧，
    /// 宽画布上两者会拉开 ~900pt，视觉上不再是一组控件。
    static let actionBar: CGFloat = 620

    /// 文档列表 / 设置表单的最大宽度。列表行再宽下去，标题与右侧日期的关联就断了。
    static let listColumn: CGFloat = 820
}

extension View {
    /// 可读宽度封顶 + 水平居中。
    ///
    /// ⚠️ 需要通栏背景时，`.background(...)` 必须加在这个 modifier **之后**
    ///（modifier 末尾已经 `frame(maxWidth: .infinity)`，之后加的背景才是通栏的）。
    func readableColumn(_ maxWidth: CGFloat) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
