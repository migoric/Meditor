import SwiftUI

/// 全宽待办主视图 — 点击底部 tab 的"待办"后替换主内容区。
@MainActor
struct TodoMainView: View {
    @Environment(AppState.self) private var state
    @State private var showingAddTodo = false

    private var store: TodoStore { state.todoStore }

    private var theme: PreviewTheme { state.themeStore.current }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            content
        }
        .background(theme.windowBackground)
        .task(id: state.rootURL) {
            await store.reload(rootURL: state.rootURL)
        }
        .sheet(isPresented: $showingAddTodo) {
            AddTodoSheet(theme: theme) { text, fileURL in
                addTodo(text: text, to: fileURL)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.appAccent)

            Text(L("sidebar.tasks"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.craftPrimary)

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    showingAddTodo = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.craftSecondary)
                }
                .buttonStyle(.plain)
                .help(L("todo.add"))

                Button {
                    Task { await store.reload(rootURL: state.rootURL) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Font.label())
                        .foregroundStyle(theme.craftSecondary)
                }
                .buttonStyle(.plain)
                .help(L("todo.refresh"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
                Section(header: sectionHeader(L("todo.sectionPending", pending.count))) {
                    ForEach(pending) { item in
                        TodoMainRow(item: item, theme: theme,
                                    onTap: { jumpTo(item) }, onToggle: { toggle(item) })
                    }
                }
                .listRowInsets(.init(top: 2, leading: 24, bottom: 2, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !done.isEmpty {
                Section(header: sectionHeader(L("todo.sectionDone", done.count))) {
                    ForEach(done) { item in
                        TodoMainRow(item: item, theme: theme,
                                    onTap: { jumpTo(item) }, onToggle: { toggle(item) })
                    }
                }
                .listRowInsets(.init(top: 2, leading: 24, bottom: 2, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func emptyMessage(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(DS.Font.label())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
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
                // 如果该文件当前已打开，同步编辑器内容
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

    private func addTodo(text: String, to fileURL: URL) {
        Task {
            do {
                let newContent = try await store.addTodo(text: text, to: fileURL)
                if let tab = state.selectedTab, tab.url == fileURL {
                    tab.content = newContent
                    tab.contentRevision &+= 1
                }
                state.showToast(L("todo.addedToast"), icon: "checkmark.circle")
            } catch {
                state.setError(error.localizedDescription)
            }
        }
    }
}

// MARK: - Row

private struct TodoMainRow: View {
    let item: TodoItem
    let theme: PreviewTheme
    let onTap: () -> Void
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.isChecked ? Color.appAccent : theme.craftSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 14))
                    .foregroundStyle(item.isChecked ? theme.craftSecondary : theme.craftPrimary)
                    .strikethrough(item.isChecked, color: theme.craftSecondary)
                    .lineLimit(2)
                Text(item.fileURL.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.craftSecondary.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(DS.Motion.micro, value: isHovered)
    }
}

// MARK: - AddTodoSheet

@MainActor
struct AddTodoSheet: View {
    let theme: PreviewTheme
    /// 回调：(待办文本, 目标文件URL)
    let onAdd: (String, URL) -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var todoText: String = ""
    @FocusState private var textFieldFocused: Bool

    /// 可写入的目标文件：当前打开的 md 文件，否则 rootURL/inbox.md
    private var targetFileURL: URL? {
        if let tab = state.selectedTab, tab.url.pathExtension.lowercased() == "md" {
            return tab.url
        }
        if let root = state.rootURL {
            return root.appendingPathComponent("inbox.md")
        }
        return nil
    }

    private var targetFileName: String {
        targetFileURL?.lastPathComponent ?? L("todo.unknownFile")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 标题
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.appAccent)
                Text(L("todo.add"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.craftPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.craftSecondary)
                }
                .buttonStyle(.plain)
            }

            // 输入框
            VStack(alignment: .leading, spacing: 6) {
                Text(L("todo.contentLabel"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.craftSecondary)
                TextField(L("todo.inputPlaceholder"), text: $todoText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.craftPrimary)
                    .focused($textFieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { confirmAdd() }
            }

            // 目标文件提示
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(L("todo.willWrite"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(targetFileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appAccent.opacity(0.8))
            }

            // 按钮区
            HStack {
                Spacer()
                Button(L("common.cancel")) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.craftSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: Capsule())

                Button(L("common.add")) {
                    confirmAdd()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(todoText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.appAccent.opacity(0.4) : Color.appAccent, in: Capsule())
                .disabled(todoText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(theme.windowBackground)
        .onAppear { textFieldFocused = true }
    }

    private func confirmAdd() {
        let trimmed = todoText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let fileURL = targetFileURL else { return }
        onAdd(trimmed, fileURL)
        dismiss()
    }
}
