import AppKit

/// 主窗口登记表。
///
/// 「关闭最后一个窗口不退出应用」（见 `MEditorAppDelegate`）需要一个**精确**的
/// 唤回入口：`NSApp.windows` 里同时混着设置窗口、Sparkle 更新面板
/// （`SparkleUserDriver` 自建）和演示窗口（`PresentationWindowController`），
/// 一律 `makeKeyAndOrderFront` 会把它们一起拽到前台。这里只登记
/// `WindowConfigurator` 实际挂上的那个主窗口。
///
/// 用 weak：窗口生命周期由 SwiftUI 持有。关闭窗口后对象并不会被销毁
/// （实测 `NSApp.windows` 计数不变、仅 `isVisible` 变 false），但本表
/// 不该成为延长它寿命的那一方。
@MainActor
enum MainWindowRegistry {
    static weak var window: NSWindow?
}
