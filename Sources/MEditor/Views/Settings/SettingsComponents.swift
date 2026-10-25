import SwiftUI

// MARK: - Reusable layout helpers (Craft-style grouped cards)

extension SettingsView {
    /// Card background — white in light mode, gently elevated in dark mode.
    var cardFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1)
                : NSColor.white
        })
    }

    var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 16)
    }

    func settingsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.leading, 3)

            VStack(spacing: 0) {
                content()
            }
            // 卡片宽度必须由容器决定，不能由内容撑。
            // 反例（0.13.10 的记忆面板）：节里只有一行「还没有约定」时，Text 只取
            // 固有宽度 ⇒ 卡片跟着缩窄 ⇒ 外层 `VStack(spacing: 0)` 的默认对齐是
            // `.center`，窄卡片被居中 ⇒ 同一栏里两张卡片宽度不同、左边线差出
            // 一百多点。截图量出来中心线重合、宽度一为 774 一为 993。
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: DS.Stroke.regular)
            )
            .dsElevation(.floatingBar)
        }
        // 组本身也撑满：即便将来外层换成 `.center` 对齐，标题也不会跑偏。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 22)
    }

    func settingsRow<Content: View>(
        label: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// Craft-style stacked row: title + subtitle on top, control filling the
    /// width below. Used for wide/compound controls (segmented pickers, text
    /// fields, control+button combos) so they align cleanly.
    func settingsStackedRow<Content: View>(
        label: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Unified settings controls

/// One visual language for every value control (text fields + dropdowns):
/// a rounded, hairline-bordered, fixed-height field.
private struct SettingsFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: DS.Stroke.regular)
            )
    }
}

extension View {
    func settingsField() -> some View { modifier(SettingsFieldStyle()) }
}

/// Dropdown styled identically to the text fields (replaces native popup pickers
/// so the whole settings form reads as one consistent control set).
struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                Button { selection = opt.value } label: {
                    if opt.value == selection {
                        Label(opt.label, systemImage: "checkmark")
                    } else {
                        Text(opt.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .settingsField()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

// MARK: - Settings Nav Item

struct SettingsNavItem: View {
    let icon: String
    let label: String
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color.appAccent : Color.secondary)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)

            Spacer()
        }
        .padding(.horizontal, DS.Space.sm + 2)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm + 1, style: .continuous)
                .fill(
                    isSelected
                        ? DS.Color.selectionFill
                        : isHovered ? DS.Color.rowHover : Color.clear
                )
                .animation(.easeOut(duration: 0.1), value: isSelected)
                .animation(.easeOut(duration: 0.07), value: isHovered)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                SelectionAccentLine(verticalPad: 5)
                    .padding(.leading, -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}


// MARK: - App Icon Badge

/// In-app rendition of the MEditor app icon (blockquote mark on ink).
/// Drawn with the same geometry as `Resources/AppIcon.icns` for consistency.
struct AppIconBadge: View {
    var size: CGFloat = 48

    private static let ink    = Color(red: 0.09, green: 0.09, blue: 0.11)
    private static let accent = Color(red: 0.42, green: 0.55, blue: 1.00)
    private static let line   = Color(white: 0.97)

    var body: some View {
        let radius = size * 0.2237
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                with: .color(Self.ink)
            )

            let w   = sz.width * 0.50
            let bw  = sz.width * 0.075
            let gap = sz.width * 0.07
            let bh  = sz.width * 0.36
            let t   = sz.width * 0.072
            let x0  = rect.midX - w / 2
            let midY = rect.midY

            // Blockquote bar (accent)
            ctx.fill(
                Path(roundedRect: CGRect(x: x0, y: midY - bh/2, width: bw, height: bh), cornerRadius: bw/2),
                with: .color(Self.accent)
            )
            // Two quoted lines (white): top full-width, bottom shorter
            let lx = x0 + bw + gap
            let lw = w - bw - gap
            ctx.fill(
                Path(roundedRect: CGRect(x: lx, y: midY - bh/2, width: lw, height: t), cornerRadius: t/2),
                with: .color(Self.line)
            )
            ctx.fill(
                Path(roundedRect: CGRect(x: lx, y: midY + bh/2 - t, width: lw * 0.66, height: t), cornerRadius: t/2),
                with: .color(Self.line)
            )
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: max(1, size / 48))
        )
        .shadow(color: Color.black.opacity(0.35), radius: size * 0.18, y: size * 0.08)
    }
}
