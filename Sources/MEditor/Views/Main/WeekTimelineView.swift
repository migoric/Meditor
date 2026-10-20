import SwiftUI

/// 苹果日历风格的周时间轴视图
/// 左侧时间刻度（0-24h），7列对应7天，事件按时间定位
struct WeekTimelineView: View {
    let days: [Date]           // 7 days
    let events: [Date: [CalendarEventItem]]  // keyed by day start
    let onSelectEvent: (CalendarEventItem) -> Void
    let onCreateEvent: (Date) -> Void        // tapped slot → create with that time

    // Layout constants
    private let hourHeight: CGFloat = 56
    private let timeAxisWidth: CGFloat = 48
    private let allDayHeight: CGFloat = 32
    private let totalHours = 24

    private var totalHeight: CGFloat { CGFloat(totalHours) * hourHeight }

    // Scroll to current time on appear

    var body: some View {
        VStack(spacing: 0) {
            // ── Day headers (fixed, outside scroll) ──
            dayHeaderRow
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.2)

            // ── All-day row ──
            allDayRow
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.15)

            // ── Time grid (scrollable) ──
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        timeGrid
                        eventsLayer
                    }
                    .frame(height: totalHeight)
                }
                .onAppear {
                    let scrollHour = max(0, currentHour - 1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo("hour-\(scrollHour)", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Day header row

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth)
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(shortWeekday(day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isToday ? Color.appAccent : .secondary)
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 18, weight: isToday ? .bold : .light))
                        .foregroundStyle(isToday ? Color.white : .primary)
                        .frame(width: 32, height: 32)
                        .background { if isToday { Circle().fill(Color.appAccent) } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - All-day row

    private var allDayRow: some View {
        HStack(spacing: 0) {
            // Time axis placeholder
            Text(L("calendar.allDay"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeAxisWidth)

            // 7 columns
            ForEach(days, id: \.self) { day in
                let dayEvents = allDayEvents(for: day)
                VStack(spacing: 1) {
                    ForEach(dayEvents) { event in
                        Text(event.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: event.colorHex), in: RoundedRectangle(cornerRadius: 3))
                            .onTapGesture { onSelectEvent(event) }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: allDayHeight)
                .padding(.horizontal, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Time grid background

    private var timeGrid: some View {
        HStack(spacing: 0) {
            // Time labels
            VStack(spacing: 0) {
                ForEach(0..<totalHours, id: \.self) { hour in
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                            .frame(width: timeAxisWidth, height: hourHeight)
                            .id("hour-\(hour)")
                        if hour > 0 {
                            Text(hourLabel(hour))
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.secondary)
                                .offset(x: -4, y: -6)
                        }
                    }
                }
            }

            // 7-column grid
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let isToday = Calendar.current.isDateInToday(day)
                    ZStack {
                        // Today column tint
                        if isToday {
                            Color.appAccent.opacity(0.04)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        // Hour dividers
                        VStack(spacing: 0) {
                            ForEach(0..<totalHours, id: \.self) { hour in
                                Color.clear
                                    .frame(height: hourHeight)
                                    .overlay(alignment: .top) {
                                        if hour > 0 {
                                            Divider().opacity(0.1)
                                        }
                                    }
                                    .onTapGesture {
                                        if let t = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                                            onCreateEvent(t)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if day != days.first {
                            Divider().opacity(0.1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Events layer

    private var eventsLayer: some View {
        HStack(spacing: 0) {
            // Time axis spacer
            Color.clear.frame(width: timeAxisWidth)

            // Per-column events
            ForEach(days, id: \.self) { day in
                let timedEvents = timedEventsFor(day)
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(timedEvents) { event in
                        TimelineEventBlock(
                            event: event,
                            hourHeight: hourHeight,
                            onTap: { onSelectEvent(event) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: totalHeight)
            }
        }
        // Current time indicator
        .overlay(alignment: .topLeading) {
            currentTimeIndicator
        }
    }

    // MARK: - Current time indicator

    private var currentTimeIndicator: some View {
        let minutesSinceMidnight = currentHour * 60 + currentMinute
        let yOffset = CGFloat(minutesSinceMidnight) / 60.0 * hourHeight
        return HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth - 4)
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1)
        }
        .offset(y: yOffset)
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func shortWeekday(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        fmt.locale = Locale.current
        return fmt.string(from: date)
    }

    private func allDayEvents(for day: Date) -> [CalendarEventItem] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        return (events[dayStart] ?? []).filter { $0.isAllDay }
    }

    private func timedEventsFor(_ day: Date) -> [CalendarEventItem] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        return (events[dayStart] ?? []).filter { !$0.isAllDay }
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }

    private func hourLabel(_ hour: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let cal = Calendar.current
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return fmt.string(from: date)
    }

    private var currentHour: Int {
        Calendar.current.component(.hour, from: Date())
    }

    private var currentMinute: Int {
        Calendar.current.component(.minute, from: Date())
    }
}

// MARK: - Single timed event block

private struct TimelineEventBlock: View {
    let event: CalendarEventItem
    let hourHeight: CGFloat
    let onTap: () -> Void
    @State private var isHovered = false

    private var yOffset: CGFloat {
        let cal = Calendar.current
        let h = cal.component(.hour, from: event.startDate)
        let m = cal.component(.minute, from: event.startDate)
        return CGFloat(h * 60 + m) / 60.0 * hourHeight
    }

    private var blockHeight: CGFloat {
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let hours = duration / 3600
        let h = max(hours * Double(hourHeight), 20) // min 20pt
        return CGFloat(h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(blockHeight > 32 ? 2 : 1)
            if blockHeight > 28 {
                Text(timeRange)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: blockHeight, maxHeight: blockHeight, alignment: .topLeading)
        .background(Color(hex: event.colorHex).opacity(isHovered ? 1.0 : 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, 2)
        .offset(y: yOffset)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
        .animation(DS.Motion.micro, value: isHovered)
    }

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))"
    }
}
