import SwiftUI

// MARK: - Document Statistics

/// Detailed statistics computed from document text.
struct DocStats {
    let cjkCount: Int      // Chinese/Japanese/Korean characters
    let latinWords: Int    // English/Latin word count
    let totalChars: Int    // All non-whitespace characters
    let lineCount: Int     // Line count

    /// Short label for the status bar chip.
    var chipLabel: String {
        switch (cjkCount > 0, latinWords > 0) {
        case (true, true):  return L("stats.chipChars", cjkCount.formatted())
        case (true, false): return L("stats.chipChars", cjkCount.formatted())
        default:            return L("stats.chipWords", latinWords)
        }
    }

    /// Estimated reading time in minutes (CJK: 350 char/min, Latin: 200 wpm).
    var readingMinutes: Int {
        let t = Double(cjkCount) / 350.0 + Double(latinWords) / 200.0
        return max(1, Int(t.rounded()))
    }

    static func compute(from text: String) -> DocStats {
        var cjk = 0
        var allChars = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            guard v > 0x20 else { continue }   // skip whitespace + control
            allChars += 1
            if isCJKScalar(v) { cjk += 1 }
        }

        // Count only Latin/non-CJK words via Unicode word-boundary enumeration.
        var latin = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            guard let first = text[range].unicodeScalars.first else { return }
            if !isCJKScalar(first.value) { latin += 1 }
        }

        let lines = max(1, text.components(separatedBy: "\n").count)
        return DocStats(cjkCount: cjk, latinWords: latin, totalChars: allChars, lineCount: lines)
    }

    private static func isCJKScalar(_ v: UInt32) -> Bool {
        (v >= 0x4E00 && v <= 0x9FFF)   ||
        (v >= 0x3400 && v <= 0x4DBF)   ||
        (v >= 0x20000 && v <= 0x2A6DF) ||
        (v >= 0xF900 && v <= 0xFAFF)   ||
        (v >= 0x2E80 && v <= 0x2EFF)   ||
        (v >= 0xAC00 && v <= 0xD7AF)   ||
        (v >= 0x3040 && v <= 0x30FF)    // Hiragana + Katakana
    }
}

// MARK: - Stats Popover

struct StatsPopover: View {
    let stats: DocStats
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                Text(L("stats.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            // Stats rows
            VStack(spacing: 0) {
                if stats.cjkCount > 0 {
                    statsRow(label: L("stats.cjk"), value: stats.cjkCount.formatted(), icon: "character")
                }
                if stats.latinWords > 0 {
                    statsRow(label: L("stats.words"), value: "\(stats.latinWords)", icon: "textformat.abc")
                }
                statsRow(label: L("stats.chars"), value: stats.totalChars.formatted(), icon: "character.cursor.ibeam")
                statsRow(label: L("stats.lines"), value: "\(stats.lineCount)", icon: "list.bullet")
                statsRow(label: L("stats.readingTime"), value: L("stats.readingMinutes", stats.readingMinutes), icon: "clock")
            }
            .padding(.vertical, 4)
        }
        .frame(width: 200)
        .background(.regularMaterial)
    }

    private func statsRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
