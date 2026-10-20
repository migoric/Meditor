import SwiftUI

/// Shown when the target .html file already exists — lets the user compare
/// sizes and confirm the overwrite without a full diff view.
struct BeautifyDiffSheet: View {
    let newHTML: String
    let existingURL: URL
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var existingSize: Int? = nil

    private var newSize: Int { newHTML.utf8.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear {
            existingSize = (try? Data(contentsOf: existingURL))?.count
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L("beautify.overwriteTitle"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                statCard(label: L("beautify.existingFile"), bytes: existingSize, color: .secondary)
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
                statCard(label: L("beautify.newFile"), bytes: newSize, color: .purple)
            }

            if let existing = existingSize {
                let delta = newSize - existing
                let sign  = delta >= 0 ? "+" : ""
                Text(L("beautify.sizeDelta", "\(sign)\(formatBytes(delta))"))
                    .font(.system(size: 12))
                    .foregroundStyle(delta > 0 ? .blue : delta < 0 ? .orange : .secondary)
            }
        }
        .padding(16)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("common.cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.escape, modifiers: [])
            Button(L("beautify.overwrite"), role: .destructive, action: onConfirm)
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Helpers

    private func statCard(label: String, bytes: Int?, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(bytes.map { formatBytes($0) } ?? "—")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(minWidth: 100)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        f.isAdaptive = true
        return f.string(fromByteCount: Int64(abs(bytes)))
    }
}
