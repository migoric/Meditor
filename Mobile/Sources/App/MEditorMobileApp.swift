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
        // 布局走查：`-debugSeedDocument preview`（或 `edit`）造一篇示意文档并直接打开。
        // 用于在 iPad / 折叠屏各种姿态下量正文栏宽度 —— 否则要先手动点开一个文件，
        // 而 simctl 没有点击能力，宽屏布局就永远只能靠肉眼猜。
        if let mode = UserDefaults.standard.string(forKey: "debugSeedDocument"), !mode.isEmpty {
            store.createDocument()
            store.applyManualEdit(Self.layoutWalkthroughText)
            store.showPreview = (mode != "edit")
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

    #if DEBUG
    /// 布局走查语料：长段落（量行宽）+ 列表 + 代码块 + 表格，覆盖各块类型。
    /// 只在 `-debugSeedDocument preview|edit` 时用到，不参与发布逻辑。
    private static let layoutWalkthroughText = """
    # 折叠屏布局走查

    这一段用来量正文栏的实际宽度。在没有宽度上限的画布上，一行可以塞进九十个以上的汉字，眼睛在换行处会丢掉行首；有了可读宽度上限之后，每一行落在四十个汉字上下，视线只需要很短的回扫距离就能接上下一行。这段话刻意写长，是为了让截图里出现足够多的行，从而量出文字的最小与最大横坐标。

    ## 列表

    - 第一项：编辑区与预览区共用同一套宽度上限
    - 第二项：底栏两条胶囊封顶后仍分列左右
    - 第三项：设置页表单封顶居中，纸底通栏

    ## 代码

    ```swift
    enum AdaptiveChrome {
        static let readingColumn: CGFloat = 720
        static let actionBar: CGFloat = 620
        static let listColumn: CGFloat = 820
    }
    ```

    | 形态 | 宽度 | 期望 |
    | --- | --- | --- |
    | 外屏 | 402pt | 铺满 |
    | 内屏 | ~1000pt | 封顶居中 |

    最后一段同样写长一些，让正文有足够的行数把可读宽度量准，同时确认表格与代码块不会撑破容器。
    """
    #endif

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
