import SwiftUI

// MARK: - Share Status Chip

/// 状态栏右侧的分享状态指示器。
/// - LAN 分享进行中：显示 wifi 图标（accent 色），点击复制当前文件链接
/// - GitHub Gist 有上次发布链接：显示云图标，点击复制链接
/// - 两者都无：不显示
@MainActor
struct ShareStatusChip: View {
    let state: AppState
    let theme: PreviewTheme
    @State private var isHovered = false

    var lanURL: String? {
        guard state.shareServer.isRunning,
              let tab = state.selectedTab else { return nil }
        return state.shareServer.shareURLForFile(tab.url)
    }

    var body: some View {
        HStack(spacing: 0) {
            // LAN 分享状态
            if state.shareServer.isRunning {
                Button {
                    if let url = lanURL {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                } label: {
                    shareChipLabel(icon: "wifi", text: L("statusBar.sharing"))
                }
                .buttonStyle(.plain)
                .help(lanURL.map { L("statusBar.copyLANLink") + "\n" + $0 }
                      ?? L("statusBar.sharing"))
                .accessibilityValue(lanURL ?? "")
            }

            // GitHub Gist 上次发布链接
            if let gistURL = state.githubGistManager.lastResultURL {
                if state.shareServer.isRunning {
                    theme.separator.frame(width: 1, height: 10).opacity(0.5).padding(.horizontal, 6)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gistURL, forType: .string)
                } label: {
                    shareChipLabel(icon: "cloud", text: "Gist")
                }
                .buttonStyle(.plain)
                .help(L("statusBar.copyGistLink") + "\n" + gistURL)
                .accessibilityValue(gistURL)
            }

            // 在线分享上次发布链接
            if let linkURL = state.shareLinkPublisher.lastResultURL {
                if state.shareServer.isRunning || state.githubGistManager.lastResultURL != nil {
                    theme.separator.frame(width: 1, height: 10).opacity(0.5).padding(.horizontal, 6)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(linkURL, forType: .string)
                } label: {
                    shareChipLabel(icon: "globe", text: L("sharelink.title"))
                }
                .buttonStyle(.plain)
                .help(linkURL)
                .accessibilityValue(linkURL)
            }
        }
        .animation(DS.Motion.fast, value: state.shareServer.isRunning)
        .animation(DS.Motion.fast, value: state.githubGistManager.lastResultURL != nil)
        .animation(DS.Motion.fast, value: state.shareLinkPublisher.lastResultURL != nil)
    }

    private func shareChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.appAccent)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.appAccent.opacity(0.85))
        }
        .padding(.horizontal, 8)
    }
}
