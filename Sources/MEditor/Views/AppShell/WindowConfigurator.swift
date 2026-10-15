import SwiftUI
// NSEvent 非 Sendable，但本地事件监视器只在主线程同步回调；@preconcurrency 关闭
// AppKit 类型的 Sendable 边界检查（Swift 6 下 NSEvent 无法跨 @Sendable 闭包）。
@preconcurrency import AppKit

/// 窗口配置：只做 titleVisibility 隐藏 + 双击放大手势。
/// 布局是 Apple 原生方案（NavigationSplitView + hiddenTitleBar + 系统 toolbar），
/// 不对 titlebar 私有视图做任何手术，macOS 升级不再塌。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            context.coordinator.attachWhenReady(to: v)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// @MainActor：KVO 观察 NSWindow 的 @MainActor 属性（toolbar/titleVisibility），
    /// 非隔离上下文中无法对这些属性形成 key path。
    @MainActor
    class Coordinator: NSObject {
        private var observation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private var rightClickMonitor: Any?
        private weak var window: NSWindow?

        /// makeNSView 时窗口可能尚未挂链（不同启动路径时序不同）——
        /// 轮询等待 window 出现再配置，否则 titleVisibility 等设置会静默丢失
        /// （裸二进制启动时曾观察到「MEditor」标题残留）。
        func attachWhenReady(to view: NSView, attempts: Int = 20) {
            if let w = view.window {
                attach(to: w)
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.attachWhenReady(to: view, attempts: attempts - 1)
                }
            }
        }

        func attach(to window: NSWindow) {
            self.window = window
            // 登记主窗口，供「关窗不退出」后的 Dock 图标唤回使用
            // （NSApp.windows 里还有设置窗口 / 更新面板 / 演示窗口，不能一概唤回）。
            MainWindowRegistry.window = window
            configure(window)
            installToolbarRightClickSwallow()
            // SwiftUI 安装/更新 toolbar（包括后续增删 toolbar item）时会把
            // titleVisibility 重置回 visible，「MEditor」标题因此反复冒出来。
            // didUpdate 每次窗口事件后触发——幂等重放隐藏，成本可忽略。
            observation = window.observe(\.toolbar, options: [.new]) { w, _ in
                if w.toolbar != nil { w.titleVisibility = .hidden }
            }
            // 直接盯 titleVisibility 本身：SwiftUI 重置它的瞬间就同步改回 hidden，
            // 窗口来不及渲染出标题——didUpdate 重放是事后补救，会先闪一帧
            // （增删 toolbar item 时「MEditor」标题闪现就是这么来的）。
            titleObservation = window.observe(\.titleVisibility, options: [.new]) { w, _ in
                if w.titleVisibility != .hidden { w.titleVisibility = .hidden }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { w in
                guard let win = w.object as? NSWindow, win.titleVisibility != .hidden else { return }
                win.titleVisibility = .hidden
            }
        }

        private func configure(_ w: NSWindow) {
            w.titleVisibility = .hidden
            DispatchQueue.main.async {
                self.installDoubleClickZoom(w)
            }
        }

        // MARK: - Toolbar right-click swallow

        /// 右键落在 toolbar 横带的任何空白处（含侧栏上方的左半段），NSToolbar 都会
        /// 弹系统显示模式菜单（Icon and Text / Icon Only / Text Only）——对文档
        /// 工作台毫无意义的设置入口，吞掉。tab 条区域的右键放行：注册顺序上本监视器
        /// 先于 TabBarRightClickGuard 的监视器，返回 event 让它继续走到 tab 守卫弹菜单。
        private func installToolbarRightClickSwallow() {
            guard rightClickMonitor == nil else { return }
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          let root = window.contentView?.superview
                    else { return event }
                    // tab 条区域放行给 tab 守卫
                    if TabAnchorRegistry.shared.isPointInTabStrip(event.locationInWindow, window: window) {
                        return event
                    }
                    // 顶部 chrome 带（与 ChromeDoubleClickZoom 同一 52pt 启发式）内的右键吞掉
                    let loc = root.convert(event.locationInWindow, from: nil)
                    if loc.y >= root.bounds.height - 52 { return nil }
                    return event
                }
            }
        }

        // MARK: - Double-click zoom

        /// Installs a double-click gesture on the top chrome area so that
        /// double-clicking the top of the window zooms it (standard macOS behaviour).
        private func installDoubleClickZoom(_ w: NSWindow) {
            guard let contentView = w.contentView else { return }
            // Walk up to the window's root view (superview of contentView).
            guard let root = contentView.superview else { return }

            // Remove any previously installed recognizer to avoid duplicates.
            root.gestureRecognizers
                .filter { $0 is ChromeDoubleClickZoom }
                .forEach { root.removeGestureRecognizer($0) }

            let gr = ChromeDoubleClickZoom(window: w)
            root.addGestureRecognizer(gr)
        }
    }
}

/// An `NSClickGestureRecognizer` that triggers `window.zoom(_:)` on double-click,
/// but only when the click lands in the top chrome strip (≤ 52 pt from top).
private final class ChromeDoubleClickZoom: NSClickGestureRecognizer {
    private weak var zoomWindow: NSWindow?

    init(window: NSWindow) {
        self.zoomWindow = window
        super.init(target: nil, action: nil)
        numberOfClicksRequired = 2
        target = self
        action = #selector(handleDoubleClick)
        // Don't eat single clicks — let them pass through.
        delaysPrimaryMouseButtonEvents = false
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleDoubleClick(_ sender: NSGestureRecognizer) {
        guard let v = sender.view else { return }
        let loc = sender.location(in: v)
        // Only trigger zoom when the click is in the top chrome strip.
        let chromeHeight: CGFloat = 52
        guard loc.y >= v.bounds.height - chromeHeight else { return }
        zoomWindow?.zoom(nil)
    }
}

/// Marks a SwiftUI region as non-window-draggable.
struct NonDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NonDraggable() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private class NonDraggable: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
