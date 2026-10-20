import SwiftUI

/// 文件历史面板：菜单「工具 → 文件历史…」触发（AppState.showingLocalHistory 驱动）。
///
/// 左侧为当前文件的本地保存快照列表（新的在前，时间 + 大小）；
/// 右侧 diff 预览复用 DiffReview 的 DiffWebView / ParagraphDiffer：
/// - 选 1 份快照 → 快照 vs 当前内容，可一键恢复；
/// - 选 2 份快照 → 两份快照互相对比（旧左新右）。
/// 恢复走 AppState.restoreHistorySnapshot（先快照当前内容 + 编辑器可撤销写回）。
@MainActor
struct LocalHistorySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [HistorySnapshot] = []
    /// 保持点选顺序，最多 2 个（先进先出淘汰）。
    @State private var selectedIDs: [String] = []
    @State private var oldContent: String?
    @State private var newContent: String?
    @State private var oldLabel = ""
    @State private var newLabel = ""
    /// 选中项变化时取消在途读取的 token。
    @State private var loadGeneration = 0

    private var tab: EditorTab? { state.selectedTab }

    var body: some View {
        let theme = state.themeStore.current
        VStack(spacing: 0) {
            header(theme)
            theme.separator.opacity(theme.isDark ? 0.28 : 0.18).frame(height: 1)
            if snapshots.isEmpty {
                emptyState(theme)
            } else {
                HSplitView {
                    snapshotList(theme)
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                    diffPreview(theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(theme)
            }
        }
        .frame(width: 820, height: 500)
        .background(theme.chromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { reload() }
        .onChange(of: tab?.id) { _, _ in reload() }
    }

    // MARK: - Header

    private func header(_ theme: PreviewTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(theme.craftSecondary)
                .font(.system(size: 13))
            Text(L("history.title"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.craftPrimary)
            if let tab {
                Text(tab.name)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.craftSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(L("history.snapshotCount", snapshots.count))
                .font(.system(size: 11))
                .foregroundStyle(theme.craftSecondary)

            Button(L("common.close")) { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.chromeBackground)
    }

    // MARK: - Snapshot list

    private func snapshotList(_ theme: PreviewTheme) -> some View {
        List {
            ForEach(snapshots) { snapshot in
                snapshotRow(snapshot, theme)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.chromeBackground)
    }

    private func snapshotRow(_ snapshot: HistorySnapshot, _ theme: PreviewTheme) -> some View {
        let isSelected = selectedIDs.contains(snapshot.id)
        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.appAccent : theme.craftSecondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.date.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.craftPrimary)
                Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.craftSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(theme.chromeBackground)
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(snapshot) }
    }

    // MARK: - Diff preview

    @ViewBuilder
    private func diffPreview(_ theme: PreviewTheme) -> some View {
        if let oldContent, let newContent {
            let diffs = ParagraphDiffer.diff(original: oldContent, modified: newContent)
            VStack(spacing: 0) {
                HSplitView {
                    diffPane(oldContent, diffs: diffs, isRight: false,
                             label: oldLabel, accent: Color(hex: "EF4444"), theme: theme)
                    diffPane(newContent, diffs: diffs, isRight: true,
                             label: newLabel, accent: Color(hex: "22C55E"), theme: theme)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L("history.comparePrompt"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffPane(_ content: String, diffs: [ParagraphDiff], isRight: Bool,
                          label: String, accent: Color, theme: PreviewTheme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isRight ? "text.alignright" : "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            // diffId 传空串：保留 pending 高亮但不渲染接受/跳过按钮（只读对比）
            DiffWebView(
                paragraphs: paneEntries(content: content, diffs: diffs, isRight: isRight),
                isRight: isRight,
                isHTMLMode: false,
                rawHTML: ""
            )
        }
        .frame(minWidth: 220)
    }

    private func paneEntries(content: String, diffs: [ParagraphDiff], isRight: Bool) -> [DiffWebView.ParaEntry] {
        ParagraphDiffer.splitParagraphs(content).enumerated().map { i, text in
            let changed = diffs.contains { isRight ? $0.modifiedIndex == i : $0.originalIndex == i }
            return DiffWebView.ParaEntry(text: text, diffId: "", status: changed ? "pending" : "unchanged")
        }
    }

    // MARK: - Footer（恢复操作）

    private func footer(_ theme: PreviewTheme) -> some View {
        HStack {
            Text(L("history.restoreHint"))
                .font(.system(size: 11))
                .foregroundStyle(theme.craftSecondary)
            Spacer()
            Button {
                restoreSelected()
            } label: {
                Label(L("history.restore"), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedIDs.count != 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.chromeBackground)
        .overlay(alignment: .top) {
            theme.separator.opacity(theme.isDark ? 0.28 : 0.18).frame(height: 1)
        }
    }

    private func emptyState(_ theme: PreviewTheme) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("history.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(L("history.emptyMessage"))
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chromeBackground)
    }

    // MARK: - Actions

    private func reload() {
        guard let tab else {
            snapshots = []
            selectedIDs = []
            return
        }
        snapshots = state.historyStore.snapshots(for: tab.url)
        selectedIDs = selectedIDs.filter { id in snapshots.contains { $0.id == id } }
        refreshPreview()
    }

    private func toggleSelection(_ snapshot: HistorySnapshot) {
        if let idx = selectedIDs.firstIndex(of: snapshot.id) {
            selectedIDs.remove(at: idx)
        } else {
            selectedIDs.append(snapshot.id)
            if selectedIDs.count > 2 { selectedIDs.removeFirst() }
        }
        refreshPreview()
    }

    /// 根据选中状态重载对比双方内容（快照读盘放后台，generation 防乱序回写）。
    private func refreshPreview() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let store = state.historyStore
        let current = tab?.content

        let selected = selectedIDs.compactMap { id in snapshots.first { $0.id == id } }
        let pair: (old: HistorySnapshot, new: HistorySnapshot?)? = {
            switch selected.count {
            case 1: return (selected[0], nil)                    // vs 当前内容
            case 2:
                let sorted = selected.sorted { $0.date < $1.date }
                return (sorted[0], sorted[1])                    // 两份互比（旧 vs 新）
            default: return nil
            }
        }()

        guard let pair else {
            oldContent = nil; newContent = nil
            return
        }

        oldLabel = Self.shortDate(pair.old.date)
        newLabel = pair.new.map { Self.shortDate($0.date) } ?? L("history.current")
        let newSnapshot = pair.new
        Task.detached(priority: .userInitiated) {
            let old = try? store.readSnapshot(pair.old)
            let new: String?
            if let newSnapshot {
                new = try? store.readSnapshot(newSnapshot)
            } else {
                new = current
            }
            await MainActor.run {
                guard generation == loadGeneration else { return }
                guard let old, let new else {
                    oldContent = nil; newContent = nil
                    return
                }
                oldContent = old
                newContent = new
            }
        }
    }

    private func restoreSelected() {
        guard selectedIDs.count == 1,
              let snapshot = snapshots.first(where: { $0.id == selectedIDs[0] }),
              let tab else { return }
        state.restoreHistorySnapshot(snapshot, for: tab)
        dismiss()
    }

    private static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Sheet 挂载（ViewModifier）

/// 历史 sheet 以修饰器挂载（ContentView 顶层修饰链已逼近编译器类型检查时限，
/// 再加 sheet 会超时——与 exportSheets 同一规避手法）。
extension View {
    func localHistorySheet(state: AppState) -> some View {
        modifier(LocalHistorySheetModifier(state: state))
    }
}

private struct LocalHistorySheetModifier: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { state.showingLocalHistory },
                set: { state.showingLocalHistory = $0 }
            )) {
                LocalHistorySheet()
                    .environment(state)
                    .presentationBackground(.regularMaterial)
            }
    }
}
