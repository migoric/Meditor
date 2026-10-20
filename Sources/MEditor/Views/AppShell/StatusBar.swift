import SwiftUI

@MainActor
struct StatusBarHost: View {
    @Environment(AppState.self) private var state
    @State private var showStatsPopover = false
    /// 控制"已保存" chip 的显隐，保存成功后显示，2 秒后自动淡出。
    @State private var showSavedChip = false
    @State private var savedChipTask: Task<Void, Never>? = nil

    var body: some View {
        let theme = state.themeStore.current
        HStack(spacing: 0) {
            if let tab = state.selectedTab {
                let stats = DocStats.compute(from: tab.content)

                statusChip("\(state.cursorLine):\(state.cursorColumn)", icon: "character.cursor.ibeam")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("statusBar.cursor"))
                    .accessibilityValue("\(state.cursorLine):\(state.cursorColumn)")
                statusDivider(theme)

                // Tappable word-count chip → shows detailed stats popover
                Button {
                    showStatsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "text.word.spacing")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(stats.chipLabel)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("stats.words"))
                .accessibilityValue(stats.chipLabel)
                .popover(isPresented: $showStatsPopover, arrowEdge: .bottom) {
                    StatsPopover(stats: stats)
                }

                statusDivider(theme)
                statusChip(state.currentFileSize)
                statusDivider(theme)

                let lang = FileTypeConfiguration.shared
                    .editorLanguage(for: tab.url.pathExtension.lowercased())?.rawValue
                    .capitalized ?? "Text"
                statusChip(lang)

                if tab.isModified {
                    statusDivider(theme)
                    HStack(spacing: 3) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text(L("statusBar.modified"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .accessibilityElement(children: .combine)
                }
            }

            // "已保存"短暂提示 chip
            if showSavedChip {
                statusDivider(theme)
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.green.opacity(0.8))
                        .accessibilityHidden(true)
                    Text(L("statusBar.saved"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            }

            Spacer()

            // 分享状态（右对齐）
            ShareStatusChip(state: state, theme: theme)
        }
        .animation(DS.Motion.fast, value: showSavedChip)
        .onChange(of: state.lastSavedAt) { _, _ in
            savedChipTask?.cancel()
            showSavedChip = true
            savedChipTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                showSavedChip = false
            }
        }
        .frame(height: 22)
        .background(.bar)  // 与 tab bar 保持一致的 material
        .overlay(alignment: .top) {
            Color.black.opacity(0.06).frame(height: 1)
        }
    }

    private func statusDivider(_ theme: PreviewTheme) -> some View {
        theme.separator
            .frame(width: 1, height: 10)
            .opacity(0.5)
            .padding(.horizontal, 6)
    }

    private func statusChip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }
}
