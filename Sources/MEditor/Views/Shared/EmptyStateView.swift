import SwiftUI

/// Refined empty-state placeholder with icon, message, and optional hint.
struct EmptyStateView: View {
    let systemImage: String
    let message: String
    var hint: String? = nil
    var shortcut: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: DS.Space.lg) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.appAccent.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.appAccent.opacity(0.6))
                }
                .accessibilityHidden(true)

                VStack(spacing: DS.Space.xs) {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.65))
                        .multilineTextAlignment(.center)

                    if let hint {
                        Text(hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .fill(DS.Color.pillBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                                        .stroke(Color.primary.opacity(0.07), lineWidth: DS.Stroke.regular)
                                )
                        )
                }
            }
            .padding(DS.Space.xl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
