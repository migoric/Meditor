import SwiftUI

/// 侧边栏待办列表视图：扫描工作区 .md 文件中的 checkbox 并展示为可交互列表。
@MainActor
struct TodoSidebarView: View {
    @Environment(AppState.self) private var state
    private var theme: PreviewTheme { state.themeStore.current }
    private var store: TodoStore { state.todoStore }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
        }
        .background(.clear)
        .task(id: state.rootURL) {
            await store.reload(rootURL: state.rootURL)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(L("sidebar.tasks"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.craftPrimary)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await store.reload(rootURL: state.rootURL) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.craftSecondary)
                }
                .buttonStyle(.plain)
                .help(L("todo.refresh"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.rootURL == nil {
            emptyMessage(L("todo.noRoot"), icon: "folder.badge.questionmark")
        } else if store.todos.isEmpty && !store.isLoading {
            emptyMessage(L("todo.empty"), icon: "checkmark.circle")
        } else {
            todoList
        }
    }

    private var todoList: some View {
        List {
            let pending = store.todos.filter { !$0.isChecked }
            let done    = store.todos.filter { $0.isChecked }

            if !pending.isEmpty {
                Section(header: CraftSectionLabel(title: L("todo.sectionPending", pending.count))) {
                    ForEach(pending) { item in
                        TodoRow(item: item, theme: theme, onTap: { jumpTo(item) }, onToggle: { toggle(item) })
                    }
                }
                .listRowInsets(.init(top: 1, leading: 12, bottom: 1, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !done.isEmpty {
                Section(header: CraftSectionLabel(title: L("todo.sectionDone", done.count))) {
                    ForEach(done) { item in
                        TodoRow(item: item, theme: theme, onTap: { jumpTo(item) }, onToggle: { toggle(item) })
                    }
                }
                .listRowInsets(.init(top: 1, leading: 12, bottom: 1, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private func jumpTo(_ item: TodoItem) {
        let fileItem = FileItem(url: item.fileURL, isDirectory: false)
        state.openFile(fileItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            state.requestEditorScroll(to: item.lineIndex)
        }
    }

    private func toggle(_ item: TodoItem) {
        Task {
            do {
                try await store.toggle(item)
                if let tab = state.selectedTab, tab.url == item.fileURL,
                   let newContent = try? String(contentsOf: item.fileURL, encoding: .utf8) {
                    tab.content = newContent
                    tab.contentRevision &+= 1
                }
            } catch {
                state.setError(error.localizedDescription)
            }
        }
    }
}

// MARK: - Row

private struct TodoRow: View {
    let item: TodoItem
    let theme: PreviewTheme
    let onTap: () -> Void
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isChecked ? Color.appAccent : theme.craftSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isChecked ? theme.craftSecondary : theme.craftPrimary)
                    .strikethrough(item.isChecked, color: theme.craftSecondary)
                    .lineLimit(2)
                Text(item.fileURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(DS.Motion.micro, value: isHovered)
    }
}

// MARK: - Section Header

private struct CraftSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.top, 5)
            .padding(.bottom, 1)
    }
}
