import Foundation

// MARK: - Tab forwarding

extension AppState {

    // State
    var openTabs: [EditorTab] {
        get { tabManager.openTabs }
        set { tabManager.openTabs = newValue }
    }
    var selectedTabID: UUID? {
        get { tabManager.selectedTabID }
        set { tabManager.selectedTabID = newValue }
    }
    var selectedTab: EditorTab? {
        get { tabManager.selectedTab }
        set { tabManager.selectedTabID = newValue?.id }
    }
    var pendingCloseTab: EditorTab? {
        get { tabManager.pendingCloseTab }
        set { tabManager.pendingCloseTab = newValue }
    }
    var showingCloseConfirmation: Bool {
        get { tabManager.showingCloseConfirmation }
        set { tabManager.showingCloseConfirmation = newValue }
    }
    var recentlyClosedURLs: [URL] {
        get { tabManager.recentlyClosedURLs }
        set { tabManager.recentlyClosedURLs = newValue }
    }

    // Actions
    @discardableResult
    func openFile(_ item: FileItem) -> Bool                      { tabManager.openFile(item) }
    func applyLoadedContent(tabID: UUID, content: String)        { tabManager.applyLoadedContent(tabID: tabID, content: content) }
    func failLoadingTab(tabID: UUID, url: URL, error: Error)     { tabManager.failLoadingTab(tabID: tabID, url: url, error: error) }
    func closeTab(_ tabID: UUID)                                 { tabManager.closeTab(tabID) }
    func closeOtherTabs(keeping tabID: UUID)                     { tabManager.closeOtherTabs(keeping: tabID) }
    func closeAllTabs()                                          { tabManager.closeAllTabs() }
    func confirmCloseTab(save: Bool)                             { tabManager.confirmCloseTab(save: save) }
    func performCloseTab(_ tabID: UUID)                          { tabManager.performCloseTab(tabID) }
    func updateTabContent(_ tabID: UUID, content: String) {
        tabManager.updateTabContent(tabID, content: content)
        if AppSettings.shared.autoSave { scheduleDebounceSave() }
    }
    func saveTab(_ tab: EditorTab)                               { tabManager.saveTab(tab) }
    func saveCurrentTab()                                        { tabManager.saveCurrentTab() }

    /// 退出流程专用：同步等待所有已修改 tab 落盘 + 会话写盘。
    /// saveTab 是 detached Task，普通 onDisappear 保存不等它，进程可能在 rename
    /// 落盘前就退出（⌘Q 丢数据）。applicationShouldTerminate 用 .terminateLater
    /// 等这个方法返回后再真正退出。
    func saveAllModifiedTabsForTermination() async {
        for tab in openTabs where tab.isModified {
            tabManager.saveTab(tab)
        }
        await tabManager.flushPendingSaves()
        flushSession()
    }
    func selectTab(_ id: UUID)                                   { tabManager.selectTab(id) }
    func reopenLastClosedTab()                                   { tabManager.reopenLastClosedTab() }
    func selectNextTab()                                         { tabManager.selectNextTab() }
    func selectPreviousTab()                                     { tabManager.selectPreviousTab() }
    func moveTab(from src: Int, to dst: Int)                     { tabManager.moveTab(from: src, to: dst) }
}
