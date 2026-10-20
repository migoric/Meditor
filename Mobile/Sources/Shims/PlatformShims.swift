import SwiftUI

// MARK: - 平台替身（Shims）
//
// 共享代码 Models/AIModels.swift 的 AIAccentStyle 引用 macOS 端的
// PreviewTheme（Models/PreviewTheme.swift）与 Color(hex:)（Extensions/Color+Hex.swift）。
// 这两个文件依赖 NSColor，无法编进 iOS target；这里提供移动端最小替身，
// 只覆盖 AIAccentStyle 实际用到的成员（isDark / Color(hex:)）。

enum PreviewTheme: String, CaseIterable, Identifiable {
    case github

    var id: String { rawValue }
    var displayName: String { "GitHub" }

    /// 必须跟随真实外观。此前恒返回 `false` 是个坑：`AIAccentStyle` 在深色下
    /// 会据此选出 fill `#18181B` + onFill `#FAFAFA`，近黑按钮压近黑底。
    ///
    /// 注意：iOS **不使用** `AIAccentStyle`（那是 macOS 的「系统蓝 / shadcn 单色」二选一），
    /// 移动端的强调色由 `PaperTheme.accent` 单一决定。本类型存在只为让共享的
    /// `AIModels.swift` 能编译；`UITraitCollection.current` 在 SwiftUI body 求值期
    /// （主线程）是正确的，其他上下文按系统默认返回，不会崩。
    var isDark: Bool {
        UITraitCollection.current.userInterfaceStyle == .dark
    }
}

extension Color {
    /// Initialize a SwiftUI Color from a CSS hex string (#RGB or #RRGGBB).
    init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}
