import SwiftUI
import AppKit

// MARK: - Memory tab
//
// 记忆面板的职责不是「展示数据」，而是回答用户三个问题：
//   ① agent 到底记住了什么（逐条可读、可改、可删）；
//   ② 哪几条每轮都在注入（pin / 使用次数 / 注入预算）；
//   ③ 为什么某条没生效（不在列表里 / 在归档里 / 文件不可写）。
// 只做①的面板等于一个 Markdown 预览器，那不如直接在编辑器里看。

extension SettingsView {

    private var memoryService: MemoryService { .shared }

    var memoryContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                memoryStatusBanner

                settingsGroup(title: L("memory.group.convention")) {
                    memoryConventionRow
                }

                settingsGroup(title: L("memory.group.entries", memoryAll.count)) {
                    // 0 条时不给筛选框：一个筛不到任何东西的输入框只是把卡片撑高，
                    // 还会让人以为下面本该有列表。
                    if !memoryAll.isEmpty {
                        memorySearchField
                        rowDivider
                    }
                    if memoryAll.isEmpty {
                        memoryEmptyRow
                    } else {
                        // 键用 recordKey（scope + id）而不是 id：id 是内容寻址的，两层里
                        // 同一条正文的 id 一样，用它做键会让两个视图撞 id。
                        ForEach(Array(memoryVisible.enumerated()), id: \.element.recordKey) { index, record in
                            memoryRow(record)
                            if index != memoryVisible.count - 1 { rowDivider }
                        }
                    }
                }

                if !memoryArchived.isEmpty {
                    settingsGroup(title: L("memory.group.archive", memoryArchived.count)) {
                        ForEach(Array(memoryArchived.enumerated()), id: \.element.recordKey) { index, record in
                            archivedRow(record)
                            if index != memoryArchived.count - 1 { rowDivider }
                        }
                    }
                }

                memoryFooter
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
        }
        .onAppear { reloadMemory() }
    }

    // MARK: - 数据

    @MainActor
    private func reloadMemory() {
        // 走 `reload` 而不是 `activate`：`activate` 在「根没变且文件没被改过」时是空操作，
        // 用它当「重新载入」按钮会让按钮看起来毫无反应（这正是 #110 修的 bug）。
        memoryService.reload(root: state.rootURL)
        memoryAll = memoryService.records()
        memoryArchived = memoryService.archivedRecords()
        memoryWarnings = memoryService.loadWarnings
        memoryConvention = memoryService.conventionText
        // 可写性只在 root 变了或这一轮重新载入时才算：`isWritableFile` 要发 stat/access，
        // 放进 body 等于每次重绘都问一遍文件系统。
        memoryWritable = state.rootURL.map(MemoryService.isWorkspaceWritable(root:))
    }

    private var memoryVisible: [MemoryRecord] {
        let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? memoryAll
            : memoryAll.filter {
                $0.entry.text.localizedCaseInsensitiveContains(query)
                    || $0.entry.id.localizedCaseInsensitiveContains(query)
                    || $0.entry.kind.displayName.contains(query)
            }
        return filtered.sorted {
            if $0.entry.kind.sortOrder != $1.entry.kind.sortOrder {
                return $0.entry.kind.sortOrder < $1.entry.kind.sortOrder
            }
            return ($0.counter.updatedAt ?? .distantPast) > ($1.counter.updatedAt ?? .distantPast)
        }
    }

    // MARK: - 状态条

    @ViewBuilder
    private var memoryStatusBanner: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if state.rootURL == nil {
                memoryNote(L("memory.noWorkspace"), icon: "folder.badge.questionmark", tint: .secondary)
            }
            // `== false` 而不是 `!memoryWritable`：`nil`（还没算过）不该报警。
            if memoryWritable == false {
                memoryNote(L("memory.notWritable"), icon: "lock", tint: .orange)
            }
            ForEach(Array(memoryWarnings.enumerated()), id: \.offset) { _, warning in
                memoryNote(warning, icon: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let root = state.rootURL {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "doc.text")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                    Text(MemoryService.displayPath(MemoryService.workspaceFileURL(root: root).path))
                        .font(DS.Font.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // 缩掉家目录后一般放得下；真放不下要保住尾部文件名，
                        // `.head` 会把 `Documents` 切成 `s`。
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.sm)
                    Button(L("memory.reveal")) {
                        let url = MemoryService.workspaceFileURL(root: root)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(root)
                        }
                    }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
                    Button(L("memory.refresh")) { reloadMemory() }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                }
                .padding(.bottom, DS.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoryNote(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(DS.Font.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .padding(.bottom, DS.Space.xs)
    }

    // MARK: - 约定段

    private var memoryConventionRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if memoryConvention.isEmpty {
                Text(L("memory.convention.empty"))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(memoryConvention)
                    .font(DS.Font.label(12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.md)
    }

    // MARK: - 搜索

    private var memorySearchField: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
            TextField(L("memory.search"), text: $memoryQuery)
                .textFieldStyle(.plain)
                .font(DS.Font.label(12))
        }
        .padding(DS.Space.md)
    }

    private var memoryEmptyRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(L("memory.empty"))
                .font(DS.Font.label(12, weight: .medium))
            Text(L("memory.empty.hint"))
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.md)
    }

    // MARK: - 单条

    private func memoryRow(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Text(record.entry.kind.displayName)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                if memoryEditingID == record.recordKey {
                    TextField("", text: $memoryDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.Font.label(12))
                        .lineLimit(1...4)
                } else {
                    Text(record.entry.text)
                        .font(DS.Font.label(12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.xs)
                memoryRowActions(record)
            }

            HStack(spacing: DS.Space.sm) {
                Text("[#\(record.entry.id)]")
                    .font(DS.Font.mono(9))
                    .foregroundStyle(.tertiary)
                if record.counter.useCount > 0 {
                    Text(L("memory.used", record.counter.useCount))
                        .font(DS.Font.mono(9))
                        .foregroundStyle(.tertiary)
                }
                if let source = record.counter.source {
                    Text(source)
                        .font(DS.Font.mono(9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if record.scope == .global {
                    Text(L("memory.scope.global"))
                        .font(DS.Font.mono(9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DS.Space.md)
        .contentShape(Rectangle())
    }

    private func memoryRowActions(_ record: MemoryRecord) -> some View {
        HStack(spacing: DS.Space.sm) {
            if memoryEditingID == record.recordKey {
                Button(L("memory.save")) {
                    memoryService.update(id: record.id, text: memoryDraft, kind: nil, scope: record.scope)
                    memoryEditingID = nil
                    reloadMemory()
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
                Button(L("memory.cancel")) { memoryEditingID = nil }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
            } else {
                Button {
                    memoryService.setPinned(!record.counter.pinned, id: record.id, scope: record.scope)
                    reloadMemory()
                } label: {
                    Image(systemName: record.counter.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(record.counter.pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(record.counter.pinned ? L("memory.unpin") : L("memory.pin"))

                Button {
                    memoryEditingID = record.recordKey
                    memoryDraft = record.entry.text
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("memory.edit"))

                Button {
                    memoryService.delete(id: record.id, scope: record.scope)
                    reloadMemory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("memory.delete"))
            }
        }
    }

    private func archivedRow(_ record: MemoryRecord) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(record.entry.text)
                .font(DS.Font.label(12))
                .foregroundStyle(.secondary)
                .strikethrough(false)
            Spacer(minLength: DS.Space.xs)
            Button(L("memory.restore")) {
                memoryService.restore(id: record.id, scope: record.scope)
                reloadMemory()
            }
            .buttonStyle(.link)
            .font(DS.Font.caption)
            Button(L("memory.delete")) {
                memoryService.delete(id: record.id, scope: record.scope)
                reloadMemory()
            }
            .buttonStyle(.link)
            .font(DS.Font.caption)
        }
        .padding(DS.Space.md)
    }

    // MARK: - 底部说明

    private var memoryFooter: some View {
        Text(L("memory.footer"))
            .font(DS.Font.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, DS.Space.lg)
    }
}
