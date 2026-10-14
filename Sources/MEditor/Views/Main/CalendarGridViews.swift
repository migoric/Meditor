import SwiftUI

// MARK: - Month Day Cell

struct MonthDayCell: View {
    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let events: [CalendarEventItem]
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Day number
            HStack {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 13, weight: isToday ? .bold : .regular))
                    .foregroundStyle(
                        isToday ? Color.white :
                        isCurrentMonth ? Color.primary : Color.secondary.opacity(0.5)
                    )
                    .frame(width: 24, height: 24)
                    .background {
                        if isToday {
                            Circle().fill(Color.appAccent)
                        } else if isSelected {
                            Circle().fill(Color.appAccent.opacity(0.15))
                        }
                    }
                Spacer()
            }
            .padding(.top, 4)
            .padding(.horizontal, 4)

            // Event dots / pills
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(events.prefix(3))) { event in
                    EventPill(event: event, compact: true)
                }
                if events.count > 3 {
                    Text(L("calendar.moreEvents", events.count - 3))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)   // 高度由外部 .frame(height:) 控制
        .background(
            isSelected ? Color.appAccent.opacity(0.06) :
            isHovered  ? Color.primary.opacity(0.03) : Color.clear
        )
        .overlay(
            Rectangle()
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: DS.Stroke.hairline)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(DS.Motion.micro, value: isHovered)
    }
}

// MARK: - Event Pill

private struct EventPill: View {
    let event: CalendarEventItem
    let compact: Bool

    var body: some View {
        HStack(spacing: 3) {
            if !compact {
                Circle()
                    .fill(Color(hex: event.colorHex))
                    .frame(width: 6, height: 6)
            }
            Text(event.title)
                .font(.system(size: compact ? 9.5 : 12))
                .foregroundStyle(compact ? Color.white : Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 4 : 8)
        .padding(.vertical, compact ? 1.5 : 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: event.colorHex).opacity(compact ? 0.85 : 0.15))
        )
    }
}

// MARK: - Week Day Section

private struct WeekDaySection: View {
    let date: Date
    let events: [CalendarEventItem]
    let onSelectEvent: (CalendarEventItem) -> Void
    let onCreateEvent: () -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(date) }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date header row
            HStack(spacing: 8) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 15, weight: isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .frame(width: 28, height: 28)
                    .background {
                        if isToday { Circle().fill(Color.appAccent) }
                    }

                Text(dayOfWeekLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isToday ? Color.appAccent : .secondary)

                Spacer()

                if isHovered {
                    Button { onCreateEvent() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, events.isEmpty ? 10 : 6)

            if !events.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(events) { event in
                            EventRow(event: event)
                                .onTapGesture { onSelectEvent(event) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isToday
                    ? Color.appAccent.opacity(0.06)
                    : isHovered ? Color.primary.opacity(0.03) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isToday ? Color.appAccent.opacity(0.2) : Color.primary.opacity(0.06),
                    lineWidth: isToday ? 1 : 0.5
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { v in withAnimation(DS.Motion.micro) { isHovered = v } }
    }

    private var dayOfWeekLabel: String {
        CalendarFmt.weekdayFull.string(from: date)
    }
}
