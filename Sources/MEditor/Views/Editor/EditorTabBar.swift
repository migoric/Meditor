import SwiftUI
import UniformTypeIdentifiers
// NSEvent 非 Sendable，本地监视器仅主线程同步回调；@preconcurrency 关闭边界检查。
@preconcurrency import AppKit

// MARK: - Tab Bar

@MainActor
struct EditorTabBar: View {
    @Environment(AppState.self) private var state
    @State private var draggedTabID: UUID?

    private var theme: PreviewTheme { state.themeStore.current }

    var body: some View {
        // 在 body 里先把「每个 tab 左侧是否画细分隔线」一次性算好，ForEach 内容
        // 闭包只查字典、不再按下标回读 state.openTabs。崩溃根因：SwiftUI 做
        // ForEach diff（尤其右键菜单「关闭其他/关闭全部」一次关多个 tab）时会用
        // 旧下标重算内容闭包，而 state.openTabs 已变短，openTabs[idx - 1] 越界
        // 触发 Swift 运行时 trap（SIGILL，EXC_BAD_INSTRUCTION）。
        let selectedID = state.selectedTabID
        let separatorBefore = separatorBeforeTabs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(state.openTabs) { tab in
                    let isSelected = tab.id == selectedID
                    TabItem(
                        tab: tab,
                        isSelected: isSelected,
                        isDark: theme.isDark,
                        showLeadingSeparator: (separatorBefore[tab.id] ?? false) && !isSelected,
                        onSelect: { state.selectTab(tab.id) },
                        onClose: { state.closeTab(tab.id) }
                    )
                    .opacity(draggedTabID == tab.id ? 0.45 : 1)
                    .animation(DS.Motion.fast, value: draggedTabID)
                    .onDrag {
                        draggedTabID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text],
                            delegate: TabDropDelegate(tab: tab, draggedTabID: $draggedTabID, state: state))
                    // 锚点视图：右键拦截器靠它把点击位置映射回 tab（见文件底部）
                    .background(TabAnchorView(tabID: tab.id))
                    .contextMenu {
                        Button(L("tab.close")) { state.closeTab(tab.id) }
                        Button(L("tab.closeOthers")) { state.closeOtherTabs(keeping: tab.id) }
                        Button(L("tab.closeAll")) { state.closeAllTabs() }
                        Divider()
                        Button(L("tab.showInFinder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                        }
                        Divider()
                        Button(L("menu.saveAsTemplate")) {
                            state.selectedTab.map { _ in
                                state.showingSaveTemplate = true
                            }
                        }
                        .disabled(state.selectedTab == nil)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)   // pill 在 toolbar 行内纵向撑满
            .animation(.easeInOut(duration: 0.18), value: state.openTabs.map(\.id))
        }
        // toolbar 对无限高度测量会塌掉——给定内容高度，pill 才能在其中拉高
        .frame(height: 44)
        // macOS 26 会给 toolbar 里的 ScrollView 自动加圆角底板——关掉
        .scrollContentBackground(.hidden)
        // 滚动到边缘时系统会叠一层玻璃/渐隐圆晕（前缘那团圆角就是这么来的）——关掉
        .disableScrollEdgeEffectsIfAvailable()
        // macOS 26 的 NSToolbar 还会给每个 item 套 Liquid Glass 胶囊——拆掉
        .background(ToolbarItemGlassDisabler())
        // 右键落进 toolbar 区域会被 NSToolbar 抢走弹系统显示模式菜单——拦截自处理
        .background(TabBarRightClickGuard(state: state))
        // item 尺寸大于内容尺寸时，即便拆了胶囊描边，NSToolbarItem 自身默认的
        // 浅色圆角容器背景仍会在未被内容覆盖的尾部露出一块——垫一层与 toolbar
        // 同色的实底盖住它（比 .scrollContentBackground(.hidden) 更彻底）。
        // AI 助手/设置弹窗打开时，内容区会叠一层黑色调光遮罩，但那层遮罩挂在
        // ContentView 内容区、不会盖到 NSToolbar 原生层——这层不透明实底如果
        // 不跟着变暗，tab 条会「浮」在变暗的下方内容之上，视觉脱节。这里跟着
        // state.aiUI.overlayShown / state.settingsOverlayShown 叠一层同样强度
        // 的暗化——这两个值分别和各自的真实遮罩共享同一处 withAnimation
        // (spring(0.42, 0.80)) 调用，不是自己另开一套动画/延迟去模拟，
        // 保证暗化像素级同步。两个遮罩不透明度不同（AI 0.30 / 设置 0.28），
        // 分别匹配，不用同一个数值。
        .background(
            GeometryReader { proxy in
                theme.windowBackground
                    .overlay(Color.black.opacity(dimmedOpacity))
                    .frame(width: max(proxy.size.width, 0), height: max(proxy.size.height, 0))
            }
        )
    }

    private var dimmedOpacity: Double {
        // 复用浮层自己的取值（而不是再写一个 0.30）：diff 审阅期间浮层让位、
        // 遮罩已撤，tab 条不能还暗着；两处数字也必须始终一致，共用同一份来源。
        let assistant = AIAssistantOverlayPlan.resolve(
            panelMounted: state.showingAIAssistant,
            expanded: state.aiUI.overlayShown,
            diffReviewPresented: state.showingDiffReview
        )
        if assistant.dimOpacity > 0 { return assistant.dimOpacity }
        if state.settingsOverlayShown { return 0.28 }
        return 0
    }

    /// tabID → 该 tab 左侧是否需要细分隔线（有前驱且前驱未被选中）。
    /// 由当前 openTabs 一次性计算（与 ForEach 同一份快照），内容闭包只查表，
    /// 杜绝按下标回读 state.openTabs 的越界 trap。首 tab 无前驱，不在表里。
    private var separatorBeforeTabs: [UUID: Bool] {
        Self.separatorBefore(tabs: state.openTabs, selectedID: state.selectedTabID)
    }

    /// 纯函数版细分隔线判定，供测试直接验证（见 TabSeparatorLogicTests）。
    /// 返回表里只有「有前驱」的 tab；值 = 前驱是否未被选中。
    static func separatorBefore(tabs: [EditorTab], selectedID: UUID?) -> [UUID: Bool] {
        guard tabs.count > 1 else { return [:] }
        var result: [UUID: Bool] = [:]
        result.reserveCapacity(tabs.count)
        for i in tabs.indices where i > 0 {
            result[tabs[i].id] = tabs[i - 1].id != selectedID
        }
        return result
    }
}

// MARK: - Tab Item

private struct TabItem: View {
    let tab: EditorTab
    let isSelected: Bool
    let isDark: Bool
    /// 未选中 tab 之间的细分隔线（Safari 式）；选中 pill 两侧不画。
    let showLeadingSeparator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            if showLeadingSeparator {
                Rectangle()
                    .fill(Color.primary.opacity(isDark ? 0.16 : 0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 3)
            }
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    // File icon
                    Image(systemName: FileTypeConfiguration.shared.icon(for: tab.url.pathExtension))
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isSelected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(Color.secondary.opacity(0.5))
                        )

                    // File name
                    Text(tab.name)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(Color.secondary.opacity(isHovered ? 0.95 : 0.7))
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    // Dot or close button
                    closeOrDot
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                // 宽一点的 pill：选中态不再窄巴巴地包住截断标题
                .frame(minWidth: 104, maxWidth: 240, maxHeight: .infinity)
                .background(tabBackground)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(tab.url.path)
            .accessibilityLabel(tab.name)
            .accessibilityValue(tab.isModified ? L("statusBar.modified") : "")
        }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            // 选中态：更实的卡片 + 更强的阴影，在磨砂背景上明显凸起
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDark ? Color(white: 0.26) : Color.white)
                .dsElevation(.floatingBar)
                .shadow(color: .black.opacity(isDark ? 0.2 : 0.06), radius: 1, x: 0, y: 0)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
        }
        // 未选中：不要圆角 pill（hover 圆角时有时无、和选中态形状重复），
        // 用 TabItem 行内的细分隔线区隔，hover 只加深文字。
    }

    @ViewBuilder
    private var closeOrDot: some View {
        ZStack {
            if isHovered || isSelected {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.1))
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .accessibilityLabel(L("tab.close"))
            } else if tab.isModified {
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .animation(DS.Motion.fast, value: isHovered)
        .animation(DS.Motion.fast, value: tab.isModified)
    }
}

// MARK: - Drop Delegate

struct TabDropDelegate: DropDelegate {
    let tab: EditorTab
    @Binding var draggedTabID: UUID?
    let state: AppState

    func performDrop(info: DropInfo) -> Bool { draggedTabID = nil; return true }

    func dropEntered(info: DropInfo) {
        guard let from = draggedTabID, from != tab.id,
              let src = state.openTabs.firstIndex(where: { $0.id == from }),
              let dst = state.openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        state.moveTab(from: src, to: dst)
        draggedTabID = tab.id
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - Toolbar item glass disabler

/// macOS 26：NSToolbar 自动给每个 item 背后垫 Liquid Glass 材质
/// （tab 条两端看到的圆角胶囊边）。官方移除方式是 NSToolbarItem.isBordered = false，
/// SwiftUI 未暴露——从标记视图向上找到所属 item 关掉。
/// 参考 WWDC25 "Build an AppKit app with the new design"。
private struct ToolbarItemGlassDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.arm(containing: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // toolbar 会重建 item（窗口状态变化时）——每次 SwiftUI 更新时幂等重放
        DispatchQueue.main.async { context.coordinator.arm(containing: nsView) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 找到所属 NSToolbarItem 并关 isBordered；同时订阅窗口更新——
    /// toolbar 隐藏/显示（如进出专注模式）会重建 item 并把 isBordered 重置回 true，
    /// didUpdate 每次窗口事件后触发，幂等重放、成本可忽略。
    @MainActor
    final class Coordinator: NSObject {
        private weak var markerView: NSView?
        private var observedWindow: NSWindow?

        func arm(containing view: NSView) {
            markerView = view
            disarm()
            guard let window = view.window, observedWindow !== window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { _ in
                // block 在 .main 队列执行，直接assume；强捕获 self 避免 @Sendable
                // 闭包里 weak var 捕获在严格并发检查（CI Xcode 16）下报错
                MainActor.assumeIsolated { self.disarm() }
            }
        }

        /// 只处理包含标记视图的那个 item——不动系统侧栏开关等其它 item 的玻璃。
        func disarm() {
            // isBordered 是 macOS 26 SDK（Xcode 26 / Swift 6.2）才有的 API——
            // CI 的 Xcode 16 编译期找不到符号，用 compiler 守卫整段摘掉
            #if compiler(>=6.2)
            guard let view = markerView, let toolbar = view.window?.toolbar else { return }
            for item in toolbar.items {
                guard let itemView = item.view, view.isDescendant(of: itemView) else { continue }
                if #available(macOS 26.0, *), item.isBordered {
                    item.isBordered = false
                }
            }
            #endif
        }
    }
}

// MARK: - Scroll edge effects

private extension View {
    /// 关掉 macOS 26 滚动边缘的玻璃/渐隐圆晕：用 `.hard` 在边缘硬裁剪。
    /// 注意参数是 Optional——传 `.none` 会被解析成 nil（= automatic 默认效果），
    /// 不是「关闭效果」。低版本系统本来就没有，直接透传。
    /// #if compiler 守卫：API 只在 macOS 26 SDK（Xcode 26 / Swift 6.2）里存在，
    /// CI 的 Xcode 16（macOS 15 SDK）编译期就找不到符号，#available 救不了。
    @ViewBuilder
    func disableScrollEdgeEffectsIfAvailable() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .scrollEdgeEffectStyle(.hard, for: .leading)
                .scrollEdgeEffectStyle(.hard, for: .trailing)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Right-click guard

/// 右键落在 toolbar 的 tab 条区域时，NSToolbar 会抢在 SwiftUI .contextMenu 之前
/// 弹出系统显示模式菜单（Icon and Text / Icon Only / Text Only）。
/// 这里用本地事件监视器在事件派发给视图层之前拦截：命中 tab 时弹我们自己的
/// NSMenu（内容与 SwiftUI contextMenu 一致），命中空白区直接吞掉——两种情况
/// 系统菜单都不再出现。
struct TabBarRightClickGuard: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.state = state
        DispatchQueue.main.async { context.coordinator.arm(marker: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
        DispatchQueue.main.async { context.coordinator.arm(marker: nsView) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // 若菜单还在追踪（例如关闭最后一个 tab 触发 toolbar item 拆除），先让
        // 追踪会话干净退出——否则会话持有的视图引用可能在 Coordinator 销毁后
        // 悬垂，objc_release 在错误对象上触发 EXC_BAD_ACCESS。
        coordinator.cancelActiveMenu()
        coordinator.disarm()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var marker: NSView?
        var state: AppState?
        private var monitor: Any?
        /// 当前正在追踪的右键菜单（仅同步弹出期间非 nil）。
        private var activeMenu: NSMenu?

        func arm(marker: NSView) {
            self.marker = marker
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                // 本地监视器在事件派发前、主线程上回调——直接 assume，模式同
                // ToolbarItemGlassDisabler 的 didUpdate 闭包
                MainActor.assumeIsolated {
                    guard let self, self.handleRightClick(event) else { return event }
                    return nil
                }
            }
        }

        func disarm() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// 关闭正在追踪的菜单（若存在）。dismantle 时调用，保证 Coordinator 销毁
        /// 前追踪会话已退出，菜单 item 的 target（本对象）不会悬垂。
        func cancelActiveMenu() {
            activeMenu?.cancelTracking()
            activeMenu = nil
        }

        /// 返回 true 表示事件已消费（不再传给 toolbar/其他视图）。
        func handleRightClick(_ event: NSEvent) -> Bool {
            // 已有菜单在追踪（用户又点了一次右键）：吞掉事件，绝不重入
            // popUpContextMenu——AppKit 不允许同时追踪两个菜单，重入会抛异常。
            guard activeMenu == nil else { return true }
            guard let marker, let window = marker.window, event.window === window,
                  let toolbar = window.toolbar,
                  let itemView = toolbar.items.first(where: {
                      $0.view.map { marker.isDescendant(of: $0) } ?? false
                  })?.view
            else { return false }
            let loc = itemView.convert(event.locationInWindow, from: nil)
            guard itemView.bounds.contains(loc) else { return false }
            if let state,
               let tabID = TabAnchorRegistry.shared.tabID(at: loc, in: itemView, window: window),
               let tab = state.openTabs.first(where: { $0.id == tabID }) {
                state.selectTab(tabID)   // Safari 习惯：右键先选中再弹菜单
                let menu = TabContextMenu.make(tab: tab, state: state, target: self)
                activeMenu = menu
                // 弹出视图用稳定的 toolbar item 容器，而不是 hitTest 出来的 tab
                // 内部视图——后者在菜单里点「关闭」会被 SwiftUI 立刻拆掉，而菜单
                // 追踪会话仍持有它（弱/autorelease 语义），会话结束释放时就会
                // 命中已释放对象 → objc_release EXC_BAD_ACCESS。itemView 与 tab
                // 条同寿命，追踪期间不会提前销毁。
                NSMenu.popUpContextMenu(menu, with: event, for: itemView)
                activeMenu = nil
            }
            // 空白区：什么都不弹，但也吞掉，挡住系统显示模式菜单
            return true
        }

        // MARK: - Menu actions

        @objc func closeTabAction(_ sender: NSMenuItem) {
            withTab(sender) { state, tab in state.closeTab(tab.id) }
        }

        @objc func closeOthersAction(_ sender: NSMenuItem) {
            withTab(sender) { state, tab in state.closeOtherTabs(keeping: tab.id) }
        }

        @objc func closeAllAction(_ sender: NSMenuItem) {
            withTab(sender) { state, _ in state.closeAllTabs() }
        }

        @objc func showInFinderAction(_ sender: NSMenuItem) {
            withTab(sender) { _, tab in NSWorkspace.shared.activateFileViewerSelecting([tab.url]) }
        }

        @objc func saveAsTemplateAction(_ sender: NSMenuItem) {
            withTab(sender) { state, _ in state.showingSaveTemplate = true }
        }

        private func withTab(_ sender: NSMenuItem, _ body: (AppState, EditorTab) -> Void) {
            guard let state,
                  let id = sender.representedObject as? UUID,
                  let tab = state.openTabs.first(where: { $0.id == id }) else { return }
            body(state, tab)
        }
    }
}

// MARK: - Tab context menu builder

/// 与 TabItem 上 SwiftUI .contextMenu 同款的 AppKit 版菜单（右键走事件监视器，
/// SwiftUI 菜单实际到不了用户面前，但保留无害——万一 Apple 修复了路由即自动恢复）。
@MainActor
enum TabContextMenu {
    typealias ActionTarget = TabBarRightClickGuard.Coordinator

    static func make(tab: EditorTab, state: AppState, target: ActionTarget) -> NSMenu {
        // RetainedContextMenu 在追踪期间强持有 target：NSMenuItem.target 是
        // unsafe_unretained，若关闭 tab 触发 SwiftUI 拆 toolbar item、Coordinator
        // 先行销毁，追踪会话再向悬垂 target 派发 action 就会崩。菜单由追踪会话
        // 强持有，用它替 target 续命，会话结束自然释放。
        let menu = RetainedContextMenu()
        menu.retainedTarget = target
        func add(_ key: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: L(key), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = tab.id
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("tab.close", #selector(ActionTarget.closeTabAction(_:)))
        add("tab.closeOthers", #selector(ActionTarget.closeOthersAction(_:)))
        add("tab.closeAll", #selector(ActionTarget.closeAllAction(_:)))
        menu.addItem(.separator())
        add("tab.showInFinder", #selector(ActionTarget.showInFinderAction(_:)))
        menu.addItem(.separator())
        // 与 SwiftUI 版一致：没有选中 tab 时禁用（右键已先 selectTab，实际总可用）
        add("menu.saveAsTemplate", #selector(ActionTarget.saveAsTemplateAction(_:)),
            enabled: state.selectedTab != nil)
        return menu
    }
}

/// 菜单追踪期间强持有 action target 的 NSMenu 子类。
/// 追踪会话持有菜单（强），菜单持有 target → 追踪期间 target 必然存活。
private final class RetainedContextMenu: NSMenu {
    var retainedTarget: AnyObject?
}

// MARK: - Tab anchor registry

/// tabID → 锚点视图 的弱引用注册表。锚点以 .background 挂在每个 tab 上，
/// 尺寸跟随 tab 内容。右键命中判定走纯几何：把每个锚点的 frame 换算到
/// tab 条（toolbar item）坐标系，点击落在哪个锚点矩形里就属于哪个 tab——
/// 不假设 SwiftUI 视图树的嵌套方式（实测层级比「兄弟节点」模型深，沿
/// superview 链找锚点不可靠）。
@MainActor
final class TabAnchorRegistry {
    static let shared = TabAnchorRegistry()

    private var table = NSMapTable<NSView, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func register(_ view: NSView, tabID: UUID) {
        table.setObject(tabID.uuidString as NSString, forKey: view)
    }

    func unregister(_ view: NSView) {
        table.removeObject(forKey: view)
    }

    /// 点击点（window 坐标系）是否落在任一注册锚点的矩形内。
    /// 供窗口级右键监视器区分「tab 条区域（放行给 TabBarRightClickGuard 弹菜单）」
    /// 和「toolbar 其余区域（吞掉，挡系统显示模式菜单）」。
    func isPointInTabStrip(_ windowPoint: NSPoint, window: NSWindow) -> Bool {
        for case let anchor as NSView in table.keyEnumerator() where anchor.window === window {
            let rect = anchor.convert(anchor.bounds, to: nil)
            if rect.insetBy(dx: -2, dy: -2).contains(windowPoint) { return true }
        }
        return false
    }

    /// 点击点（coordinateSpace 坐标系）落在哪个注册锚点的矩形内；多个重叠时取面积最小者。
    func tabID(at point: NSPoint, in coordinateSpace: NSView, window: NSWindow) -> UUID? {
        var best: (id: UUID, area: CGFloat)?
        for case let anchor as NSView in table.keyEnumerator() {
            guard anchor.window === window,
                  let raw = table.object(forKey: anchor) as String?,
                  let id = UUID(uuidString: raw) else { continue }
            let rect = anchor.convert(anchor.bounds, to: coordinateSpace)
            guard rect.contains(point) else { continue }
            let area = rect.width * rect.height
            if area < (best?.area ?? .greatestFiniteMagnitude) {
                best = (id, area)
            }
        }
        return best?.id
    }
}

/// 每个 tab 的锚点标记视图（不可见、不响应事件——纯身份标记）。
private struct TabAnchorView: NSViewRepresentable {
    let tabID: UUID

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        TabAnchorRegistry.shared.register(v, tabID: tabID)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TabAnchorRegistry.shared.register(nsView, tabID: tabID)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        TabAnchorRegistry.shared.unregister(nsView)
    }
}
