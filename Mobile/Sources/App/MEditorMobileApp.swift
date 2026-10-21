import SwiftUI
import UIKit

/// 接收 Home Screen Quick Action 的共享通道。
@MainActor
final class QuickActionHandler {
    static let shared = QuickActionHandler()
    private init() {}

    enum Action {
        case newDocument
        case openFile
        case openRecent(String)
    }

    private var continuation: AsyncStream<Action>.Continuation?
    var stream: AsyncStream<Action> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "new-document": continuation?.yield(.newDocument)
        case "open-file":    continuation?.yield(.openFile)
        case "open-recent":
            if let path = item.userInfo?["path"] as? String {
                continuation?.yield(.openRecent(path))
            }
        default: break
        }
    }
}

// MARK: - App Delegate（Quick Action 转发）

final class QuickActionDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickActionHandler.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

@main
struct MEditorMobileApp: App {
    @UIApplicationDelegateAdaptor(QuickActionDelegate.self) private var appDelegate
    @State private var recents: RecentHistory
    @State private var store: DocumentStore
    @State private var settings: MobileAISettings
    /// 全局唯一的 AI 会话：Tab 与文档页悬浮入口共用同一段对话。
    @State private var chat: ChatModel
    /// 外观（跟随系统 / 浅色 / 墨夜）与阅读设置：UserDefaults 持久化，全局注入。
    @State private var appearance = AppAppearance()
    @State private var reader = ReaderSettings()

    init() {
        PaperAppearance.apply()
        let recents = RecentHistory()
        let store = DocumentStore(recents: recents)
        let settings = MobileAISettings()
        _recents = State(initialValue: recents)
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _chat = State(initialValue: ChatModel(store: store, settings: settings))
        configureQuickActions()
        #if DEBUG
        // 模拟器设计走查：`xcrun simctl launch … -debugSeedChat YES`
        if UserDefaults.standard.bool(forKey: "debugSeedChat") {
            _chat.wrappedValue.seedDemoConversation()
        }
        #endif
    }

    /// Home Screen 3D Touch / 长按快速操作。
    private func configureQuickActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: "new-document",
                localizedTitle: "新建文档",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.square"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "open-file",
                localizedTitle: "打开文件",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "folder"),
                userInfo: nil
            ),
        ]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recents)
                .environment(store)
                .environment(settings)
                .environment(chat)
                .environment(appearance)
                .environment(reader)
                .tint(PaperTheme.accent)
                .preferredColorScheme(appearance.mode.colorScheme)
        }
        .onChange(of: store.recents.documents.count) { _ in
            updateQuickActions()
        }
    }

    /// 随最近文档动态更新快速操作（顶部显示最近文档快捷入口）。
    private func updateQuickActions() {
        let recentItems = store.recents.documents.prefix(2).map { doc in
            UIApplicationShortcutItem(
                type: "open-recent",
                localizedTitle: doc.fileName,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "doc.text"),
                userInfo: ["path": doc.relativePath as NSString]
            )
        }
        var items = [
            UIApplicationShortcutItem(
                type: "new-document",
                localizedTitle: "新建文档",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.square"),
                userInfo: nil
            ),
        ]
        items.append(contentsOf: recentItems)
        UIApplication.shared.shortcutItems = items
    }
}
