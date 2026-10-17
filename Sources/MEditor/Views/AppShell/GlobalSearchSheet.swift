import SwiftUI

/// Global content search presented as a sheet over the main window.
/// Trigger via ⌘⇧F.
///
/// Implementation notes:
/// - 与 Agent 的 search_workspace 共用 WorkspaceIndexService（内存行缓存 + 子串扫描），
///   输入即搜靠 200ms 防抖 + actor 后台查询，不阻塞主线程。
/// - 结果复用 QuickOpen 的浮层范式：行预览 + 相对路径:行号，回车/双击跳转。
/// - 跳转落地：openFile 后 requestEditorScroll(select: true)——光标落到目标行
///   并用系统 Find 指示器闪烁高亮整行。
@MainActor
struct GlobalSearchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [WorkspaceSearchMatch] = []
    @State private var highlighted = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = state.themeStore.current
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(theme.craftSecondary)
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                TextField(L("globalSearch.placeholder"), text: $query)
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

            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(width: 560, height: 400)
        .background(theme.chromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            highlighted = 0
            searchFocused = true
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        // 面板打开期间索引首次构建完成 → 立即补一次搜索（此前显示「索引构建中」）
        .onChange(of: state.workspaceIndexReady) { _, ready in
            if ready { scheduleSearch() }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Search（200ms 防抖，后台 actor 查询）

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            isSearching = false
            highlighted = 0
            return
        }
        isSearching = true
        let index = state.workspaceIndex
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let matches = await index.search(
                query: q, extensions: [], includeFileNames: true, maxTotal: 100, maxPerFile: 5)
            guard !Task.isCancelled else { return }
            results = matches
            highlighted = 0
            isSearching = false
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        let theme = state.themeStore.current
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(results.enumerated()), id: \.offset) { idx, match in
                    resultRow(match, index: idx)
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

    @ViewBuilder
    private func resultRow(_ match: WorkspaceSearchMatch, index idx: Int) -> some View {
        let theme = state.themeStore.current
        let isFileNameMatch = match.lineNumber == 0
        HStack(spacing: 8) {
            Image(systemName: isFileNameMatch ? "doc.text" : "text.alignleft")
                .foregroundStyle(theme.craftSecondary)
                .font(.system(size: 11))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(isFileNameMatch
                     ? (match.relativePath as NSString).lastPathComponent
                     : match.line.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.craftPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(isFileNameMatch ? match.relativePath : "\(match.relativePath):\(match.lineNumber)")
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

    private var emptyState: some View {
        let theme = state.themeStore.current
        let message: String
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = L("globalSearch.typeToSearch")
        } else if !state.workspaceIndexReady {
            message = L("globalSearch.indexing")
        } else if isSearching {
            message = L("globalSearch.searching")
        } else {
            message = L("common.noMatches")
        }
        return VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chromeBackground)
    }

    // MARK: - Actions

    private func commitSelection() {
        guard highlighted >= 0, highlighted < results.count else { return }
        let match = results[highlighted]
        guard let root = state.rootURL else { return }
        let url = root.appendingPathComponent(match.relativePath)
        state.openFile(FileItem(url: url, isDirectory: false))
        if match.lineNumber > 0 {
            // 0-based 行号；select: true → 光标落行 + Find 指示器闪烁高亮
            state.requestEditorScroll(to: match.lineNumber - 1, select: true)
        }
        dismiss()
    }

    private func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { highlighted = 0; return }
        highlighted = min(max(0, highlighted + delta), results.count - 1)
    }
}
