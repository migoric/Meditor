import SwiftUI

/// Refined LAN-share popover: URL in a copyable pill, primary/destructive button hierarchy.
@MainActor
struct SharePopoverContent: View {
    let server: ShareManager
    let selectedTab: EditorTab?
    let onStop: () -> Void

    @State private var copied = false

    private var fileURL: String? {
        guard let tab = selectedTab else { return nil }
        return server.shareURLForFile(tab.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: DS.Space.sm) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(Color.green.opacity(0.9))
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("share.active"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(server.localAddress.isEmpty ? "Port \(server.port)" : "\(server.localAddress):\(server.port)")
                        .font(DS.Font.mono(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            Divider().padding(.horizontal, DS.Space.lg)

            // URL section
            if let url = fileURL {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text(L("share.currentFile"))
                        .font(DS.Font.caption)
                        .foregroundStyle(.tertiary)

                    // URL row
                    HStack(spacing: DS.Space.sm) {
                        Text(url)
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(.primary.opacity(0.8))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Copy button
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            withAnimation(DS.Motion.springFast) { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(DS.Motion.standard) { copied = false }
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(copied ? Color.green : Color.appAccent)
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                                        .fill(Color.appAccent.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                        .animation(DS.Motion.springFast, value: copied)
                    }
                    .padding(DS.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .fill(DS.Color.pillBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.sm)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: DS.Stroke.regular)
                            )
                    )
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
            }

            Divider().padding(.horizontal, DS.Space.lg)

            // Stop button
            Button(role: .destructive) {
                onStop()
            } label: {
                Label(L("share.stop"), systemImage: "wifi.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.red)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.lg)
        }
        .frame(width: 280)
    }
}
