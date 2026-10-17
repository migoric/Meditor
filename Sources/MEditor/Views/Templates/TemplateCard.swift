import SwiftUI

struct TemplateCard: View {
    let template: DocumentTemplate
    let isSelected: Bool
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false

    private var kind: TemplateKind { TemplateKind(template) }

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(DS.Color.editorBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .stroke(isSelected ? kind.accent.opacity(0.9) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2 : 1)
                    )
                    .dsElevation(isHovered || isSelected ? DS.Elevation.toast : .floatingBar)

                TemplateThumbnail(kind: kind, accent: kind.accent)
                    .padding(12)
            }
            .frame(height: 96)
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1)

            Text(template.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.78))
                .lineLimit(1)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(DS.Color.editorBg))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .animation(DS.Motion.fast, value: isSelected)
        .animation(DS.Motion.micro, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
