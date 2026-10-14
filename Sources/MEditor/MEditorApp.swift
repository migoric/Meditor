import SwiftUI

@main
@MainActor
struct MEditorApp: App {
    @NSApplicationDelegateAdaptor(MEditorAppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        // MCP 子命令（MEditor mcp [--workspace <path>]）：在启动最早期接管进程，
        // 走纯 CLI 的 stdio 会话循环，不初始化 AppKit / SwiftUI。
        // dispatchMain() 泵主队列（@MainActor 工具上下文依赖它）且永不返回；
        // 会话在 stdin EOF 后 exit() 结束进程。
        if MCPCommand.shouldRun(arguments: CommandLine.arguments) {
            Task {
                let code = await MCPCommand.run(arguments: CommandLine.arguments)
                exit(code)
            }
            dispatchMain()
        }
        _appState = State(initialValue: AppState())
    }

    var body: some Scene {
        Window("MEditor", id: "main") {
            ContentView()
                .environment(appState)
                .environment(appState.aiUI)
                .environment(AppSettings.shared)
                .frame(minWidth: 900, minHeight: 500)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    if let window = NSApp.windows.first {
                        window.setFrameAutosaveName("MEditorMainWindow")
                        window.titleVisibility = .hidden
                        window.titlebarSeparatorStyle = .none
                        window.isMovableByWindowBackground = true
                    }
                    bootSequence()
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .onDisappear {
                    // Save all modified tabs on quit
                    for tab in appState.openTabs where tab.isModified {
                        appState.saveTab(tab)
                    }
                    // Force-flush session to disk so the next launch restores it.
                    appState.flushSession()
                }
        }
        Settings {
            SettingsView()
                .environment(appState)
                .environment(AppSettings.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.openFolder")) {
                    openFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(L("menu.openFile")) {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Close Project") {
                    appState.showingCloseProjectConfirmation = true
                }

                Divider()

                Button(L("menu.newFile")) {
                    appState.showingTemplatePicker = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.rootURL == nil)

                Button(L("menu.saveAsTemplate")) {
                    appState.showingSaveTemplate = true
                }
                .disabled(appState.selectedTab == nil)
            }

            CommandGroup(replacing: .saveItem) {
                Button(L("menu.save")) {
                    appState.saveCurrentTab()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button(L("action.copyRichText")) {
                    appState.copyRichTextToPasteboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!appState.previewExporter.isExportAvailable)
            }

            CommandGroup(replacing: .textFormatting) {
                Button(L("menu.find")) {
                    performFindCommand(tag: 1)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button(L("menu.findNext")) {
                    performFindCommand(tag: 2)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button(L("menu.findPrevious")) {
                    performFindCommand(tag: 3)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button(L("menu.useSelectionForFind")) {
                    let menuItem = NSMenuItem()
                    menuItem.tag = 7
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: menuItem)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button(L("menu.jumpToLine")) {
                    let menuItem = NSMenuItem()
                    menuItem.tag = 12
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: menuItem)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button(L("menu.findInWorkspace")) {
                    appState.showingGlobalSearch = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.rootURL == nil)

                Divider()

                Button(L("menu.replace")) {
                    let menuItem = NSMenuItem()
                    menuItem.tag = 1
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: menuItem)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button(L("menu.bold")) {
                    NSApp.sendAction(#selector(NativeEditorView.Coordinator.meditorToggleBold(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(L("menu.italic")) {
                    NSApp.sendAction(#selector(NativeEditorView.Coordinator.meditorToggleItalic(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button(L("menu.link")) {
                    NSApp.sendAction(#selector(NativeEditorView.Coordinator.meditorInsertLink(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandGroup(replacing: .windowList) {
                Button(L("menu.closeTab")) {
                    if let id = appState.selectedTabID {
                        appState.closeTab(id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                Button(L("menu.reopenClosedTab")) {
                    appState.reopenLastClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(L("menu.nextTab")) {
                    appState.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button(L("menu.previousTab")) {
                    appState.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button(L("menu.quickOpen")) {
                    appState.showingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(appState.rootURL == nil)

                Button(L("menu.commandPalette")) {
                    appState.showingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(appState.rootURL == nil)

                Divider()

                Button(L("menu.presentation")) {
                    appState.startPresentation()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState.selectedTab == nil || appState.selectedTab?.language != .markdown)

                Button(L("menu.exportPresentation")) {
                    appState.exportPresentation()
                }
                .disabled(appState.selectedTab == nil || appState.selectedTab?.language != .markdown)
            }
            CommandMenu(L("menu.tools")) {
                Button(L("menu.aiAssistant")) {
                    withAnimation(DS.Motion.spring) { appState.showingAIAssistant.toggle() }
                }
                .keyboardShortcut("j", modifiers: .command)

                Button(L("menu.documentDiagnostics")) {
                    appState.showingDiagnostics = true
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(appState.rootURL == nil)

                Button(L("menu.localHistory")) {
                    appState.showingLocalHistory = true
                }
                // ⌃⌘H：⌥⌘H 与系统「隐藏其他」冲突
                .keyboardShortcut("h", modifiers: [.command, .control])
                .disabled(appState.selectedTab == nil)
            }
            CommandGroup(after: .appVisibility) {
                Button("Install CLI Tool…") {
                    installCLI()
                }
            }
        }
    }

    // MARK: - 冷启动引导

    /// 冷启动引导序列。**三步顺序有依赖，必须依次执行**——此前三步散在 onAppear 的
    /// 注释块里，靠注释维系顺序（MEditorAppDelegate 自己也承认存在冷启动竞态）。
    /// 收进一个函数后，顺序成为代码结构的一部分：
    ///   1. warmUp — 预热 WKWebView，让首次打开文档即时渲染（只读预热，无依赖）；
    ///   2. restoreSession — 恢复上次会话（根目录 / 打开的 tab / 选中项）；
    ///   3. 注入 appState 并 consumePendingOpens — 补开冷启动期间到达的 Spotlight 点击。
    ///      **必须在 restoreSession 之后**：否则恢复会话的落盘状态会覆盖掉刚打开的外部文档。
    private func bootSequence() {
        WebViewPool.shared.warmUp()
        appState.restoreSession()
        appDelegate.appState = appState
        appDelegate.consumePendingOpens()
    }

    private func installCLI() {
        let script = """
        #!/bin/sh
        open -a MEditor "$@"
        """
        let dest = URL(fileURLWithPath: "/usr/local/bin/meditor")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("meditor_cli")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
            // Use AuthorizationExecuteWithPrivileges via AppleScript to write to /usr/local/bin
            let src = tmp.path
            let appleScript = """
            do shell script "mkdir -p /usr/local/bin && cp '\(src)' '\(dest.path)' && chmod +x '\(dest.path)'" with administrator privileges
            """
            var error: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
            if error == nil {
                let alert = NSAlert()
                alert.messageText = "CLI Tool Installed"
                alert.informativeText = "You can now use `meditor .` in Terminal to open folders."
                alert.runModal()
            } else {
                let alert = NSAlert()
                alert.messageText = "Installation Failed"
                alert.informativeText = error?["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Installation Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func handleOpenURL(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            appState.openFolder(url)
        } else {
            // Ensure the parent folder is opened so the sidebar has context.
            if appState.rootURL == nil {
                let parent = url.deletingLastPathComponent()
                appState.openFolder(parent)
            }
            let item = FileItem(url: url, isDirectory: false)
            appState.openFile(item)
        }
    }

    private func performFindCommand(tag: Int) {
        if appState.previewFindController.handleCommand(tag: tag) {
            return
        }

        let menuItem = NSMenuItem()
        menuItem.tag = tag
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: menuItem)
    }

    private func openFolder() {
        Task {
            if let url = await appState.filePickerService.pickFolder(message: L("panel.chooseFolder")) {
                appState.openFolder(url)
            }
        }
    }

    private func openFile() {
        Task {
            if let url = await appState.filePickerService.pickFile(title: nil, allowedExtensions: ["md", "html", "htm"]) {
                let item = FileItem(url: url, isDirectory: false)
                appState.openFile(item)
            }
        }
    }
}
