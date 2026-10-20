import EventKit
import SwiftUI

// MARK: - Event Row

struct EventRow: View {
    let event: CalendarEventItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Color accent bar
            Color(hex: event.colorHex)
                .frame(width: 4)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 4, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 0, topTrailingRadius: 0
                ))

            HStack(spacing: 6) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(hex: event.colorHex).opacity(isHovered ? 0.14 : 0.08))
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 4, topTrailingRadius: 4
            ))
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(DS.Motion.micro, value: isHovered)
    }

    private var timeLabel: String {
        if event.isAllDay { return L("calendar.allDay") }
        return "\(CalendarFmt.timeShort.string(from: event.startDate)) – \(CalendarFmt.timeShort.string(from: event.endDate))"
    }
}

// MARK: - CalendarEventItem

struct CalendarEventItem: Identifiable {
    let event: EKEvent

    init(_ event: EKEvent) { self.event = event }

    var id: String { event.eventIdentifier ?? UUID().uuidString }
    var title: String { event.title ?? L("event.untitled") }
    var startDate: Date { event.startDate }
    var endDate: Date { event.endDate }
    var isAllDay: Bool { event.isAllDay }
    var source: String { "system" }

    var colorHex: String {
        let c = event.calendar.cgColor
        let comps = c?.components ?? [0.4, 0.6, 1.0, 1.0]
        let r = Int((!comps.isEmpty ? comps[0] : 0) * 255)
        let g = Int((comps.count > 1 ? comps[1] : 0) * 255)
        let b = Int((comps.count > 2 ? comps[2] : 0) * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }

    var notes: String? { event.notes }
    var location: String? { event.location }
}

extension EKEvent: @retroactive Identifiable {
    public var id: String { eventIdentifier ?? UUID().uuidString }
}

// MARK: - EventDetailPopoverItem

@MainActor
struct EventDetailPopoverItem: View {
    let item: CalendarEventItem
    let onDismiss: () -> Void
    @State private var showDeleteConfirm = false
    @Environment(\.calendarService) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: item.colorHex))
                            .frame(width: 10, height: 10)
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                detailRow(icon: "clock", text: timeText)
                if let loc = item.location, !loc.isEmpty {
                    detailRow(icon: "mappin", text: loc)
                }
                if let notes = item.notes, !notes.isEmpty {
                    detailRow(icon: "note.text", text: notes)
                }
            }
            .padding(16)

            // Actions
            if item.event.calendar.allowsContentModifications {
                Divider()
                HStack {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L("common.delete"), systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .confirmationDialog(L("event.deleteConfirm"), isPresented: $showDeleteConfirm) {
                        Button(L("common.delete"), role: .destructive) {
                            service.deleteEvent(item.event)
                            onDismiss()
                        }
                        Button(L("common.cancel"), role: .cancel) {}
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 300)
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
    }

    private var timeText: String {
        if item.isAllDay {
            return CalendarFmt.dateMedium.string(from: item.startDate)
        }
        return "\(CalendarFmt.dateTimeMedium.string(from: item.startDate)) – \(CalendarFmt.timeShort.string(from: item.endDate))"
    }
}
