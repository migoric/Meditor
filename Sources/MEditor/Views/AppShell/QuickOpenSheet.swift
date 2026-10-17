import SwiftUI

/// Fuzzy file finder presented as a sheet over the main window.
/// Trigger via ⌘P.
///
/// Implementation notes:
/// - Searches a background-built flat file index so opening a folder doesn't
///   have to eagerly hydrate the full sidebar tree.
/// - Ranks results by simple substring + path depth. Good enough for now.
@MainActor
struct QuickOpenSheet: View {
    @Environment(AppState.self) private var state
    @Environment(WorkspaceUIState.self) private var workspaceUI
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    @State private var cachedSections: [PaletteSection] = []
    @State private var cachedFlat: [PaletteItem] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = state.themeStore.current
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.craftSecondary)
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                TextField(L("quickOpen.commandPlaceholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.craftPrimary)
                    .focused($searchFocused)
                    .onSubmit { commitSelection() }
                    .onKeyPress(.upArrow) {
                        moveHighlight(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveHighlight(1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.chromeBackground)

            theme.separator.opacity(theme.isDark ? 0.28 : 0.18).frame(height: 1)

            // Results
            if cachedFlat.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(width: 520, height: 360)
        .background(theme.chromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            highlighted = 0
            searchFocused = true
            rebuildResults()
        }
        .onChange(of: query) { _, _ in
            highlighted = 0
            rebuildResults()
        }
    }

    private func rebuildResults() {
        let cmds = buildCommandResults()
        let files = buildFileResults()
        cachedFlat = cmds + files
        var sections: [PaletteSection] = []
        if !cmds.isEmpty { sections.append(PaletteSection(title: L("quickOpen.actions"), items: cmds)) }
        if !files.isEmpty { sections.append(PaletteSection(title: L("quickOpen.files"), items: files)) }
        cachedSections = sections
    }

    // MARK: - Results

    private var searchableFiles: [FileItem] {
        if !state.indexedFiles.isEmpty { return state.indexedFiles }
        return state.fileItemMap.values.filter { !$0.isDirectory }
    }

    private func buildCommandResults() -> [PaletteItem] {
        filteredCommands.prefix(query.isEmpty ? 5 : 6).map(PaletteItem.command)
    }

    private func buildFileResults() -> [PaletteItem] {
        let allFiles = searchableFiles
        guard !query.isEmpty else {
            let openURLs = Set(state.openTabs.map { $0.url })
            let openFiles = allFiles.filter { openURLs.contains($0.url) }
            let others = allFiles
                .filter { !openURLs.contains($0.url) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return Array((openFiles + others).prefix(45)).map(PaletteItem.file)
        }
        return rank(allFiles, query: query).map(PaletteItem.file)
    }

    private var filteredCommands: [CommandPaletteItem] {
        guard !query.isEmpty else { return commandPalette }

        let q = query.lowercased()
        return commandPalette.compactMap { item in
            let haystacks = [item.title, item.subtitle] + item.keywords
            let bestScore = haystacks.reduce(Int.max) { current, value in
                let candidate = value.lowercased()
                if candidate.hasPrefix(q) { return min(current, 0) }
                if candidate.contains(q) { return min(current, 100 + candidate.count - q.count) }
                return current
            }
            return bestScore == Int.max ? nil : item
        }
        .sorted { lhs, rhs in
            score(for: lhs, query: q) < score(for: rhs, query: q)
        }
    }

    /// Crude relevance ranking: prefers names that contain the query as a
    /// contiguous substring; ties broken by name length (shorter = better).
    private func rank(_ files: [FileItem], query: String) -> [FileItem] {
        let q = query.lowercased()
        let scored: [(FileItem, Int)] = files.compactMap { file in
            let name = file.name.lowercased()
            let path = file.url.path.lowercased()
            if name.hasPrefix(q) { return (file, 0) }
            if name.contains(q)  { return (file, 100 + name.count - q.count) }
            if path.contains(q)  { return (file, 1000 + path.count) }
            return nil
        }
        return scored
            .sorted { $0.1 < $1.1 }
            .prefix(50)
            .map { $0.0 }
    }

    private var resultsList: some View {
        let theme = state.themeStore.current
        return ScrollViewReader { proxy in
            List {
                ForEach(cachedSections) { section in
                    Section {
                        ForEach(section.items) { item in
                            resultRow(item)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.craftSecondary.opacity(0.6))
                            .textCase(nil)
                            .padding(.leading, 10)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chromeBackground)
            .onChange(of: highlighted) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(query.isEmpty ? L("quickOpen.typeToSearch") : L("common.noMatches"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.themeStore.current.chromeBackground)
    }

    // MARK: - Actions

    private func commitSelection() {
        guard highlighted >= 0, highlighted < cachedFlat.count else { return }
        switch cachedFlat[highlighted] {
        case .file(let item):
            state.openFile(item)
        case .command(let item):
            item.action()
        }
        dismiss()
    }

    private func moveHighlight(_ delta: Int) {
        guard !cachedFlat.isEmpty else { highlighted = 0; return }
        highlighted = min(max(0, highlighted + delta), cachedFlat.count - 1)
    }

    private func relativePath(for url: URL) -> String {
        guard let root = state.rootURL else { return url.lastPathComponent }
        let rootPath = root.path
        let path = url.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
        }
        return path
    }

    private func score(for item: CommandPaletteItem, query: String) -> Int {
        let haystacks = [item.title, item.subtitle] + item.keywords
        return haystacks.reduce(Int.max) { current, value in
            let candidate = value.lowercased()
            if candidate.hasPrefix(query) { return min(current, 0) }
            if candidate.contains(query) { return min(current, 100 + candidate.count - query.count) }
            return current
        }
    }

    private var commandPalette: [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "toggle-focus-mode",
                title: L("quickOpen.toggleFocusMode"),
                subtitle: L("quickOpen.toggleFocusModeDesc"),
                icon: "scope",
                keywords: ["focus", "distraction", "zen", "mode"]
            ) {
                workspaceUI.toggleFocusMode()
            },
            CommandPaletteItem(
                id: "toggle-sidebar",
                title: L("quickOpen.toggleSidebar"),
                subtitle: L("quickOpen.toggleSidebarDesc"),
                icon: "sidebar.left",
                keywords: ["sidebar", "navigation", "files"]
            ) {
                workspaceUI.toggleSidebar()
            },
            CommandPaletteItem(
                id: "toggle-editor",
                title: L("quickOpen.toggleEditor"),
                subtitle: L("quickOpen.toggleEditorDesc"),
                icon: "doc.text",
                keywords: ["editor", "edit", "source", "markdown", "编辑器", "源码"]
            ) {
                workspaceUI.toggleEditor()
            },
            CommandPaletteItem(
                id: "toggle-preview",
                title: L("quickOpen.togglePreview"),
                subtitle: L("quickOpen.togglePreviewDesc"),
                icon: "eye",
                keywords: ["preview", "render", "预览"]
            ) {
                workspaceUI.togglePreview()
            },
            CommandPaletteItem(
                id: "open-folder",
                title: L("quickOpen.openFolder"),
                subtitle: L("quickOpen.openFolderDesc"),
                icon: "folder",
                keywords: ["folder", "workspace", "project"]
            ) {
                openFolderPicker()
            },
            CommandPaletteItem(
                id: "new-document",
                title: L("quickOpen.newDocument"),
                subtitle: L("quickOpen.newDocumentDesc"),
                icon: "square.and.pencil",
                keywords: ["new", "template", "document", "file"]
            ) {
                state.templateCreateParentURL = state.rootURL
                state.showingTemplatePicker = true
            },
            CommandPaletteItem(
                id: "cycle-theme",
                title: L("quickOpen.cycleTheme"),
                subtitle: L("quickOpen.cycleThemeDesc"),
                icon: "paintpalette",
                keywords: ["theme", "appearance", "color"]
            ) {
                cycleTheme()
            },
            CommandPaletteItem(
                id: "export-pdf",
                title: L("quickOpen.exportPDF"),
                subtitle: L("quickOpen.exportPDFDesc"),
                icon: "doc.richtext",
                keywords: ["export", "pdf", "share"]
            ) {
                exportPDF()
            }
        ]
    }

    private func openFolderPicker() {
        Task {
            if let url = await state.filePickerService.pickFolder(message: L("panel.chooseFolder")) {
                state.openFolder(url)
            }
        }
    }

    private func cycleTheme() {
        let allThemes = PreviewTheme.allCases
        guard let currentIndex = allThemes.firstIndex(of: state.themeStore.current) else {
            state.themeStore.current = allThemes.first ?? .github
            return
        }
        let nextIndex = allThemes.index(after: currentIndex)
        state.themeStore.current = nextIndex == allThemes.endIndex ? allThemes[allThemes.startIndex] : allThemes[nextIndex]
    }

    private func exportPDF() {
        // 走统一导出入口：预检清单 + PDF 选项 sheet（与预览工具栏一致）
        state.requestExport(.pdf)
    }

    @ViewBuilder
    private func resultRow(_ item: PaletteItem) -> some View {
        let theme = state.themeStore.current
        // Use item.id lookup in cachedFlat — O(N) but called per-row during List render,
        // not during every body evaluation. For ≤50 rows this is negligible.
        let idx = cachedFlat.firstIndex(where: { $0.id == item.id }) ?? 0

        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(theme.craftSecondary)
                .font(.system(size: 11))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftPrimary)

                Text(subtitle(for: item))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(idx == highlighted ? Color.selectionFill : theme.chromeBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .id(idx)
        .onTapGesture(count: 2) {
            highlighted = idx
            commitSelection()
        }
        .onTapGesture {
            highlighted = idx
        }
    }

    private func subtitle(for item: PaletteItem) -> String {
        switch item {
        case .file(let file):
            return relativePath(for: file.url)
        case .command(let command):
            return command.subtitle
        }
    }
}

private struct PaletteSection: Identifiable {
    let title: String
    let items: [PaletteItem]

    var id: String { title }
}

private struct CommandPaletteItem {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let keywords: [String]
    let action: () -> Void
}

private enum PaletteItem: Identifiable {
    case file(FileItem)
    case command(CommandPaletteItem)

    var id: String {
        switch self {
        case .file(let item):
            return "file:\(item.id.absoluteString)"
        case .command(let item):
            return "command:\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .file(let item):
            return item.name
        case .command(let item):
            return item.title
        }
    }

    var subtitle: String {
        switch self {
        case .file(let item):
            return item.url.path
        case .command(let item):
            return item.subtitle
        }
    }

    var icon: String {
        switch self {
        case .file(let item):
            return FileTypeConfiguration.shared.icon(for: item.fileExtension)
        case .command(let item):
            return item.icon
        }
    }
}
