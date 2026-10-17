import SwiftUI

// MARK: - File Action

enum FileAction: Hashable {
    case newFile(URL)
    case newFolder(URL)
    case rename(FileItem)
    case delete(FileItem)
    case copyAbsolutePath(FileItem)
    case copyRelativePath(FileItem)
    case revealInFinder(FileItem)
}

// MARK: - FileSidebar (Apple 原生 Sidebar 风格 —— 备忘录/Finder 同款)

@MainActor
struct FileSidebar: View {
    @Environment(AppState.self) private var state
    @Environment(WorkspaceUIState.self) private var workspaceUI
    @State private var searchText = ""
    @State private var showCreateAlert = false
    @State private var createName = ""
    @State private var createParentURL: URL?
    @State private var createIsFolder = false

    @State private var showRenameAlert = false
    @State private var renameName = ""
    @State private var renameTarget: FileItem?

    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: FileItem?

    @State private var userDocFiles: [URL] = []
    @State private var appDocFiles: [URL] = []
    @State private var userDocExpanded = true
    @State private var appDocExpanded  = true
    @State private var looseExpanded   = true

    private var displayedTree: [FileItem] {
        guard !searchText.isEmpty else { return state.fileTree }
        if !state.indexedFiles.isEmpty {
            return state.indexedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return flattenLoadedMatches(state.fileTree)
    }

    private func flattenLoadedMatches(_ items: [FileItem]) -> [FileItem] {
        var result: [FileItem] = []
        for item in items {
            if !item.isDirectory && item.name.localizedCaseInsensitiveContains(searchText) { result.append(item) }
            if let children = item.children { result.append(contentsOf: flattenLoadedMatches(children)) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题行（原生样式） ──
            SpaceSwitcherRow()

            // ── Search bar ──
            SidebarSearchBar(text: $searchText)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)

            // ── 始终显示文件树 ──
            if searchText.isEmpty { mainContent } else { searchResultsView }

            // ── Bottom toolbar（文件操作 | 视图切换 | 应用开关，一行收编） ──
            SidebarBottomBar(
                activeMainView: workspaceUI.activeMainView,
                onSelectView: { newView in workspaceUI.activeMainView = newView },
                onNewFile: {
                    state.templateCreateParentURL = state.rootURL
                    createIsFolder = false
                    state.showingTemplatePicker = true
                },
                onNewFolder: {
                    createParentURL = state.rootURL; createIsFolder = true
                    createName = ""; showCreateAlert = true
                }
            )
        }
        .background(.clear)
        // 把**实测**列宽回传 workspaceUI：toolbar 里 tab 条的宽度必须按真实列宽
        // 算，不能用 sidebarWidth 那个理想宽（260）——用户把侧栏拖到 320 时，
        // 按 260 算出来的 tab 条会超出 detail 列，macOS 直接把整个 toolbar item
        // 塞进 ">>" 溢出菜单，整条 tab 栏消失（左侧面板展开后 tab 不显示的根因）。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        workspaceUI.setMeasuredSidebarWidth(
                            proxy.size.width,
                            isVisible: workspaceUI.showsSidebarInLayout
                        )
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        workspaceUI.setMeasuredSidebarWidth(w, isVisible: workspaceUI.showsSidebarInLayout)
                    }
            }
        }
        .onChange(of: state.selectedTabID) { _, _ in
            expandToSelectedFile()
        }
        .sheet(isPresented: $showCreateAlert) {
            InputDialog(
                title: L(createIsFolder ? "menu.newFolder" : "menu.newFile"),
                message: L(createIsFolder ? "create.messageFolder" : "create.messageFile"),
                placeholder: L(createIsFolder ? "create.folderName" : "create.fileName"),
                confirmTitle: L("common.create"),
                text: $createName,
                onConfirm: { createItem(); showCreateAlert = false },
                onCancel: { resetCreateState(); showCreateAlert = false }
            )
        }
        .sheet(isPresented: $showRenameAlert) {
            InputDialog(
                title: L("rename.title"),
                message: renameTarget.map { L("rename.messageFormat", $0.name) } ?? "",
                placeholder: L("rename.newName"),
                confirmTitle: L("rename.title"),
                text: $renameName,
                onConfirm: { renameItem(); showRenameAlert = false },
                onCancel: { resetRenameState(); showRenameAlert = false }
            )
        }
        .confirmationDialog(
            L("delete.confirmFormat", itemToDelete?.name ?? ""),
            isPresented: $showDeleteConfirmation, titleVisibility: .visible
        ) {
            Button(L("common.delete"), role: .destructive) {
                if let item = itemToDelete { deleteItem(item) }
                itemToDelete = nil
            }
            Button(L("common.cancel"), role: .cancel) { itemToDelete = nil }
        }
    }

    // MARK: - Main content (when not searching)

    private var mainContent: some View {
        List {
            // User document section
            let userPath = AppSettings.shared.userDocPath
            if let _ = userPath, !userDocFiles.isEmpty {
                Section(isExpanded: $userDocExpanded) {
                    ForEach(userDocFiles, id: \.path) { url in
                        DocFileRow(url: url, isSelected: state.selectedFileID == url)
                            .onTapGesture { state.openFile(FileItem(url: url, isDirectory: false)) }
                    }
                } header: {
                    Text(L("sidebar.userDocs"))
                }
            }

            // App document section
            if !appDocFiles.isEmpty {
                Section(isExpanded: $appDocExpanded) {
                    ForEach(appDocFiles, id: \.path) { url in
                        DocFileRow(url: url, isSelected: state.selectedFileID == url)
                            .onTapGesture { state.openFile(FileItem(url: url, isDirectory: false)) }
                    }
                } header: {
                    Text(L("sidebar.appDocs"))
                }
            }

            // 散文件 section（不属于任何 Workspace 的独立文件）
            if !state.looseFiles.files.isEmpty {
                Section(isExpanded: $looseExpanded) {
                    ForEach(state.looseFiles.files) { file in
                        LooseFileRow(
                            file: file,
                            isSelected: state.selectedTab?.url == file.url
                        )
                        .onTapGesture { state.openLooseFile(file.url) }
                        .contextMenu {
                            Button(L("menu.revealInFinder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            Button(L("sidebar.copyPath")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.url.path, forType: .string)
                            }
                            Divider()
                            Button(L("sidebar.removeFromList"), role: .destructive) {
                                state.looseFiles.remove(file.id)
                            }
                        }
                    }
                } header: {
                    Text(L("sidebar.looseFiles"))
                }
            }

            // Workspace folders section
            if !state.fileTree.isEmpty {
                Section {
                    ForEach(state.fileTree) { item in
                        SidebarTreeNode(
                            item: item,
                            searchText: "",
                            onAction: handleFileAction,
                            onTap: { selectSidebarItem($0) }
                        )
                    }
                } header: {
                    Text(L("sidebar.folders"))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshDocFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .docPathChanged)) { _ in
            refreshDocFiles()
        }
    }

    private func refreshDocFiles() {
        let userPath = AppSettings.shared.userDocPath
        let appPath  = AppSettings.shared.appDocPath
        // 目录枚举放后台线程，避免 onAppear / docPathChanged 时阻塞主线程。
        // 枚举规则收口在 FileService（View 不再直接碰 FileManager）。
        DispatchQueue.global(qos: .userInitiated).async {
            let userFiles = FileService.listDocumentFiles(at: userPath)
            let appFiles  = FileService.listDocumentFiles(at: appPath)
            DispatchQueue.main.async {
                userDocFiles = userFiles
                appDocFiles  = appFiles
            }
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        if displayedTree.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L("common.noMatches"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(displayedTree, id: \.id) { item in
                FileRow(item: item, isSelected: item.id == state.selectedFileID,
                        searchText: searchText, onAction: handleFileAction,
                        gitStatus: state.gitStatusService.status(for: item.url))
                    .help(item.url.path)
                    .contentShape(Rectangle())
                    .onTapGesture { state.openFile(item) }
            }
            .listStyle(.sidebar)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Actions

    private func handleFileAction(_ action: FileAction) {
        switch action {
        case .newFile(let parentURL):
            state.templateCreateParentURL = parentURL
            createIsFolder = false
            state.showingTemplatePicker = true
        case .newFolder(let parentURL):
            createParentURL = parentURL; createIsFolder = true; createName = ""; showCreateAlert = true
        case .rename(let item):
            renameTarget = item; renameName = item.name; showRenameAlert = true
        case .delete(let item):
            itemToDelete = item; showDeleteConfirmation = true
        case .copyAbsolutePath(let item):
            copyToPasteboard(item.url.path)
        case .copyRelativePath(let item):
            copyToPasteboard(FilePathFormatter.relativePath(for: item.url, rootURL: state.rootURL))
        case .revealInFinder(let item):
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    private func createItem() {
        guard let parentURL = createParentURL, !createName.isEmpty else { resetCreateState(); return }
        let fileName = createIsFolder ? createName : (createName.hasSuffix(".md") ? createName : "\(createName).md")
        state.createFileOrFolder(name: fileName, isFolder: createIsFolder, parentURL: parentURL)
        resetCreateState()
    }

    private func resetCreateState() { createName = ""; createParentURL = nil }

    private func renameItem() {
        guard let target = renameTarget, !renameName.isEmpty else { resetRenameState(); return }
        state.renameFileItem(from: target.url, newName: renameName)
        resetRenameState()
    }

    private func resetRenameState() { renameName = ""; renameTarget = nil }
    private func deleteItem(_ item: FileItem) { state.deleteFileItem(at: item.url) }

    private func copyToPasteboard(_ value: String) {
        Pasteboard.copy(value)
    }

    private func selectSidebarItem(_ item: FileItem) { state.selectFile(item) }

    /// Expand all ancestor directories of the currently selected tab's file
    /// so the highlighted row is visible in the tree.
    private func expandToSelectedFile() {
        guard let url = state.selectedTab?.url,
              let root = state.rootURL else { return }
        let rootPath = root.standardizedFileURL.path
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(rootPath), dir.path != rootPath {
            workspaceUI.setExpanded(FileItem(url: dir, isDirectory: true), true)
            state.loadChildrenIfNeeded(for: FileItem(url: dir, isDirectory: true))
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }
}

// MARK: - Space Switcher (原生标题行 —— 备忘录/Finder 同款，无卡片背景)

@MainActor
private struct SpaceSwitcherRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text(state.rootURL?.lastPathComponent ?? "MEditor")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }
}

// MARK: - Search Bar (系统原生搜索框风格)

@MainActor
private struct SidebarSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(L("common.search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: DS.Stroke.regular)
        )
    }
}

/// 底栏（一行收编）：文件操作 | 主区视图切换（待办/日历） | 应用开关（专注/设置）。
@MainActor
private struct SidebarBottomBar: View {
    @Environment(AppState.self) private var state
    @Environment(WorkspaceUIState.self) private var workspaceUI
    let activeMainView: ActiveMainView
    let onSelectView: (ActiveMainView) -> Void
    let onNewFile: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack {
                SidebarIconButton(icon: "doc.badge.plus", help: L("sidebar.newDocument"), action: onNewFile)
                    .disabled(state.rootURL == nil)
                SidebarIconButton(icon: "folder.badge.plus", help: L("sidebar.newFolder"), action: onNewFolder)
                    .disabled(state.rootURL == nil)
                Spacer()
                // 主区视图切换：待办 / 日历（再点一次回到文档）
                SidebarIconButton(
                    icon: "checkmark.circle",
                    help: L("sidebar.tasks"),
                    isActive: activeMainView == .todos
                ) { onSelectView(activeMainView == .todos ? .document : .todos) }
                SidebarIconButton(
                    icon: "calendar",
                    help: L("sidebar.calendar"),
                    isActive: activeMainView == .calendar
                ) { onSelectView(activeMainView == .calendar ? .document : .calendar) }
                Spacer()
                // 专注模式切换
                SidebarIconButton(
                    icon: "scope",
                    help: workspaceUI.isFocusMode ? L("tooltip.exitFocus") : L("tooltip.focusMode"),
                    isActive: workspaceUI.isFocusMode
                ) {
                    withAnimation(DS.Motion.springFast) { workspaceUI.toggleFocusMode() }
                }
                SidebarIconButton(icon: "gearshape", help: L("menu.preferences")) {
                    state.showingSettings = true
                }
                .anchorPreference(key: SettingsAnchorKey.self, value: .bounds) { $0 }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.clear)
        }
    }
}

private struct SidebarIconButton: View {
    let icon: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(
                    isActive ? Color.appAccent
                    : Color.secondary.opacity(isHovered ? 1 : 0.55)
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isActive ? Color.selectionFill
                            : isHovered ? Color.primary.opacity(0.07) : Color.clear
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .animation(DS.Motion.micro, value: isHovered)
    }
}

// MARK: - Doc File Row

@MainActor
private struct DocFileRow: View {
    let url: URL
    let isSelected: Bool
    @State private var isHovered = false

    private var icon: String {
        switch url.pathExtension.lowercased() {
        case "html": return "doc.richtext"
        default:     return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 16, alignment: .center)
            Text(url.lastPathComponent)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                        // 与 FileRow 保持一致：跟随应用内强调色设置，不用纯系统级颜色
                        ? AnyShapeStyle(Color.selectionFill)
                        : isHovered
                            ? AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                            : AnyShapeStyle(Color.clear)
                )
                .padding(.horizontal, 4)
                .animation(.easeOut(duration: 0.09), value: isSelected)
                .animation(.easeOut(duration: 0.07), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - LooseFileRow

/// 侧边栏「散文件」区的单行条目。
private struct LooseFileRow: View {
    let file: LooseFile
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // 来源图标
            Image(systemName: file.source == .claude ? "sparkles" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(file.source == .claude ? Color.appAccent : .secondary)
                .frame(width: 14)

            // 文件名
            Text(file.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected
                    ? Color.appAccent
                    : (isHovered ? Color.primary.opacity(0.07) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(DS.Motion.micro, value: isHovered)
        .help(file.url.path)
    }
}
