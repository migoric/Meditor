import AppKit
import CoreSpotlight
import Foundation

/// AppKit 层入口适配（Spotlight 点击结果打开等系统回调）。
///
/// SwiftUI App 生命周期本身不暴露 NSApplicationDelegate，这里用
/// `@NSApplicationDelegateAdaptor` 挂接。AppState 由 MEditorApp 在首个窗口
/// onAppear 时注入；冷启动点击 Spotlight 结果时 AppState 可能尚未注入，
/// 先入 pendingOpenURLs，待注入后由 consumePendingOpens() 补开。
@MainActor
final class MEditorAppDelegate: NSObject, NSApplicationDelegate {

    /// Spotlight 结果点击的 NSUserActivity type 字符串值。macOS SDK 未导出
    /// CSSearchableItemActionIdentifier 常量（iOS only），这里用其字面值，
    /// 与 Info.plist 的 NSUserActivityTypes 声明保持一致。
    static let spotlightActivityType = "com.apple.corespotlightitem"

    weak var appState: AppState?
    private var pendingOpenURLs: [URL] = []

    /// Spotlight 结果点击：activityType = com.apple.corespotlightitem，
    /// userInfo[CSSearchableItemActivityIdentifier] 携带索引时的 uniqueIdentifier（文件绝对路径）。
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == Self.spotlightActivityType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              !identifier.isEmpty else { return false }
        let url = URL(fileURLWithPath: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        openOrEnqueue(url)
        return true
    }

    /// AppState 注入前的 Spotlight 打开请求在此补开（冷启动竞态）。
    /// 必须在 restoreSession 之后调用，避免与恢复的会话互相覆盖。
    func consumePendingOpens() {
        guard appState != nil, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        urls.forEach { openOrEnqueue($0) }
    }

    /// 关闭最后一个窗口时**不**退出应用。
    ///
    /// SwiftUI 的单例 `Window` 场景默认会在关闭唯一窗口时终止进程——最小复现实测：
    /// `NSApp.windows.first?.close()` 之后进程立即以 exit(0) 结束，而
    /// `applicationShouldTerminateAfterLastWindowClosed` 确实被调用；只有返回 false
    /// 才拦得住。返回 false 后应用驻留 Dock，且窗口对象仍然活着
    /// （实测 `NSApp.windows` 计数不变、只是 `isVisible` 变 false），
    /// 所以唤回窗口不必重建，标签页 / 滚动位置 / 光标原样保留。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标（当前没有可见窗口）时把主窗口唤回。
    ///
    /// 只认 `MainWindowRegistry` 登记的主窗口：`NSApp.windows` 里还混着设置窗口、
    /// Sparkle 更新面板与演示窗口，一概 order-front 会把它们一起拽出来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = MainWindowRegistry.window {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 退出前确保未保存内容真正落盘。
    ///
    /// SwiftUI 的 `.onDisappear` 里调 saveTab 只是挂出 detached Task，进程可能在
    /// 写盘完成前就退出（⌘Q 丢数据）。这里用 `.terminateLater` + 异步等待，
    /// 等所有 tab 的写盘任务和会话快照都完成后才真正终止。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard appState.openTabs.contains(where: { $0.isModified }) else {
            appState.flushSession()
            return .terminateNow
        }
        Task { @MainActor in
            await appState.saveAllModifiedTabsForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// AppIntent（打开文档）与 Spotlight 共用的打开入口。
    func openOrEnqueue(_ url: URL) {
        guard let appState else {
            pendingOpenURLs.append(url)
            return
        }
        if let root = appState.rootURL {
            if appState.fileTreeManager.isSameOrDescendant(url, of: root) {
                appState.openFile(FileItem(url: url, isDirectory: false))
            } else {
                // 属于另一个工作区：不打断当前工作区，按散文件打开
                appState.openLooseFile(url)
            }
        } else {
            // 无工作区：先把父目录作为工作区打开，让侧边栏有上下文（与 handleOpenURL 一致）
            appState.openFolder(url.deletingLastPathComponent())
            appState.openFile(FileItem(url: url, isDirectory: false))
        }
    }
}
