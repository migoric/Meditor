import SwiftUI

struct TemplateThumbnail: View {
    let kind: TemplateKind
    let accent: Color

    private var faint: Color { Color.primary.opacity(0.14) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch kind {
            case .blank:
                bar(accent, 26)
                Spacer(minLength: 0)
                bar(faint, 40)
            case .meeting:
                bar(accent, 48)
                checkRow(34); checkRow(28)
                miniTable()
            case .tech:
                bar(accent, 46)
                bar(faint, 30, h: 4)
                line(58); line(48)
                miniTable()
            case .weekly:
                bar(accent, 42)
                bulletRow(46); bulletRow(52); bulletRow(38)
            case .journal:
                bar(accent, 36)
                line(56); line(44)
                bar(faint, 26, h: 4)
            case .htmlTheme:
                codeMark()
                line(50); line(40)
            case .generic:
                bar(accent, 40)
                line(56); line(48); line(36)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Building blocks

    private func bar(_ c: Color, _ w: CGFloat, h: CGFloat = 6) -> some View {
        RoundedRectangle(cornerRadius: h / 2, style: .continuous).fill(c).frame(width: w, height: h)
    }
    private func line(_ w: CGFloat) -> some View { bar(faint, w, h: 4) }

    private func checkRow(_ w: CGFloat) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .stroke(faint, lineWidth: DS.Stroke.regular).frame(width: 6, height: 6)
            bar(faint, w, h: 4)
        }
    }
    private func bulletRow(_ w: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle().fill(accent.opacity(0.5)).frame(width: 4, height: 4)
            bar(faint, w, h: 4)
        }
    }
    private func miniTable() -> some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().stroke(faint, lineWidth: 0.8)
                            .frame(width: 18, height: 9)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
    private func codeMark() -> some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
        }
    }
}
