import SwiftUI

/// Template picker — Craft-inspired: a search header, sectioned scroll, and
/// rich cards that each render a miniature preview of the template's layout.
@MainActor
struct TemplatePickerSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let store: TemplateStoreProtocol
    let onSelect: (DocumentTemplate) -> Void

    @State private var query = ""
    @State private var selectedID: String? = "blank"
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 16)]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 580, height: 480)
        .background(.clear)
        .onAppear { searchFocused = true }
    }

    // MARK: - Header (search)

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            TextField(L("template.search"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .animation(DS.Motion.fast, value: query.isEmpty)
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if sections.allSatisfy({ $0.items.isEmpty }) {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        ForEach(sections) { section in
                            if !section.items.isEmpty {
                                sectionView(section)
                            }
                        }
                    }
                    .padding(DS.Space.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView(_ section: PickerSection) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.5)

            LazyVGrid(columns: columns, spacing: DS.Space.lg) {
                ForEach(section.items) { template in
                    TemplateCard(
                        template: template,
                        isSelected: selectedID == template.id,
                        onDelete: template.isBuiltin ? nil : { try? store.delete(id: template.id) }
                    )
                    .onTapGesture {
                        withAnimation(DS.Motion.springFast) { selectedID = template.id }
                    }
                    .onTapGesture(count: 2) {
                        selectedID = template.id
                        confirmSelection()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("common.noMatches"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let id = selectedID, let template = store.template(byID: id) {
                HStack(spacing: 7) {
                    TemplateThumbnail(kind: .init(template), accent: TemplateKind(template).accent)
                        .frame(width: 22, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.1)))
                    Text(template.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L("template.selectHint"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(L("common.cancel")) { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button(L("template.create")) { confirmSelection() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(selectedID == nil)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    // MARK: - Sections data

    private struct PickerSection: Identifiable {
        let id: String
        let title: String
        let items: [DocumentTemplate]
    }

    private var sections: [PickerSection] {
        if !query.isEmpty {
            return [PickerSection(id: "search", title: L("template.search"), items: allFiltered)]
        }
        let md   = store.builtinTemplates().filter { $0.category == .markdown }
        let html = store.builtinTemplates().filter { $0.category == .htmlTheme }
        let user = store.userTemplates()

        var result: [PickerSection] = []
        if !md.isEmpty   { result.append(PickerSection(id: "markdown",  title: L("templates.sectionMarkdown"),  items: md)) }
        if !html.isEmpty { result.append(PickerSection(id: "htmlTheme", title: L("templates.sectionHTML"), items: html)) }
        if !user.isEmpty { result.append(PickerSection(id: "mine",      title: L("templates.sectionMine"),  items: user)) }
        return result
    }

    private var allFiltered: [DocumentTemplate] {
        let q = query.lowercased()
        return store.allTemplates().filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private func confirmSelection() {
        guard let id = selectedID, let template = store.template(byID: id) else { return }
        onSelect(template)
        dismiss()
    }
}
