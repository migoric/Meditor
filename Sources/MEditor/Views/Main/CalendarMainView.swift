import EventKit
import SwiftUI

// MARK: - View Mode

private enum CalendarViewMode: String, CaseIterable {
    case month
    case week

    var displayName: String {
        switch self {
        case .month: return L("calendar.mode.month")
        case .week:  return L("calendar.mode.week")
        }
    }
}

// MARK: - CalendarMainView

/// 全宽日历主视图：月视图/周视图、导航、创建事件、事件详情。
@MainActor
struct CalendarMainView: View {
    @State private var viewMode: CalendarViewMode = .month
    @State private var referenceDate: Date = Date()
    @State private var events: [EKEvent] = []
    @State private var authStatus: EKAuthorizationStatus = .notDetermined
    @State private var isLoading = false
    @State private var selectedDate: Date? = nil
    @State private var selectedEvent: CalendarEventItem? = nil
    @State private var showCreateSheet = false
    @State private var createForDate: Date? = nil
    @State private var calendarFilter: Set<String> = []     // empty = all
    @State private var allCalendars: [EKCalendar] = []

    @Environment(\.calendarService) private var service

    // Visible range for the current view
    private var visibleRange: (Date, Date) {
        let cal = Calendar.current
        switch viewMode {
        case .month:
            let comps = cal.dateComponents([.year, .month], from: referenceDate)
            let first = cal.date(from: comps) ?? referenceDate
            // Extend to grid edges (Mon..Sun)
            let gridStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: first)) ?? first
            let gridEnd   = cal.date(byAdding: .day, value: 42, to: gridStart) ?? gridStart
            return (gridStart, gridEnd)
        case .week:
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: referenceDate)) ?? referenceDate
            let weekEnd   = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            return (weekStart, weekEnd)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)

            if authStatus != .fullAccess {
                unauthorizedView
            } else {
                Group {
                    switch viewMode {
                    case .month: monthGrid
                    case .week:  weekList
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: referenceDate) { _, _ in Task { await reload() } }
        .onChange(of: viewMode)      { _, _ in Task { await reload() } }
        .sheet(isPresented: $showCreateSheet, onDismiss: { Task { await reload() } }) {
            CreateEventSheet(defaultDate: createForDate ?? Date(), calendars: allCalendars)
        }
        .popover(item: $selectedEvent, arrowEdge: .trailing) { item in
            EventDetailPopoverItem(item: item) {
                selectedEvent = nil
                Task { await reload() }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // 日历颜色图标
            Image(systemName: "calendar")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.appAccent)

            Text(navigationTitle)
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 140, alignment: .leading)

            Spacer()

            // 今天
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { referenceDate = Date() }
            } label: {
                Text(L("calendar.today"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)

            // 上一页
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { navigate(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            // 下一页
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { navigate(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            // 视图切换
            Picker("", selection: $viewMode) {
                ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            // 新建事件
            Button {
                createForDate = nil
                showCreateSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .help(L("calendar.newEvent"))

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("calendar.refresh"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var navigationTitle: String {
        switch viewMode {
        case .month:
            return CalendarFmt.monthTitle.string(from: referenceDate)
        case .week:
            let (s, e) = visibleRange
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: e) ?? e
            return "\(CalendarFmt.weekStart.string(from: s)) – \(CalendarFmt.weekEnd.string(from: lastDay))"
        }
    }

    // MARK: - Month Grid

    private var monthGrid: some View {
        let cal = Calendar.current
        let (gridStart, _) = visibleRange
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        let currentMonth = cal.component(.month, from: referenceDate)

        return VStack(spacing: 0) {
            // 星期标题行
            HStack(spacing: 0) {
                ForEach(Array(CalendarFmt.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            Divider().opacity(0.3)

            // 用 GeometryReader 拿到实际可用高度，平均分给 6 行
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        MonthDayCell(
                            date: day,
                            isCurrentMonth: cal.component(.month, from: day) == currentMonth,
                            isToday: cal.isDateInToday(day),
                            isSelected: selectedDate.map { cal.isDate($0, inSameDayAs: day) } ?? false,
                            events: eventsOn(day)
                        )
                        .frame(height: rowHeight)   // 精确等分，不留白
                        .onTapGesture { selectedDate = day }
                        .contextMenu {
                            Button(L("calendar.newEvent")) {
                                createForDate = day
                                showCreateSheet = true
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 选中日期事件列表 — 紧跟 grid 下方
            if let sel = selectedDate {
                Divider().opacity(0.3)
                selectedDayEvents(for: sel)
                    .frame(height: 140)
            }
        }
    }

    // MARK: - Selected Day Events Panel

    private func selectedDayEvents(for date: Date) -> some View {
        let dayEvents = eventsOn(date)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(CalendarFmt.dayHeader.string(from: date))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                Spacer()
                Button {
                    createForDate = date
                    showCreateSheet = true
                } label: {
                    Label(L("calendar.new"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .padding(.trailing, 16)
                .padding(.top, 10)
            }
            if dayEvents.isEmpty {
                Text(L("calendar.noEvents"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(dayEvents) { event in
                            EventRow(event: event)
                                .onTapGesture { selectedEvent = event }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Week Timeline

    private var weekList: some View {
        let cal = Calendar.current
        let (start, end) = visibleRange
        let days = stride(from: start, to: end, by: 86400).map {
            Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate)
        }

        // Build events dict keyed by day start
        var eventsByDay: [Date: [CalendarEventItem]] = [:]
        for day in days {
            let dayStart = cal.startOfDay(for: day)
            eventsByDay[dayStart] = eventsOn(day)
        }

        return VStack(spacing: 0) {
            WeekTimelineView(
                days: days,
                events: eventsByDay,
                onSelectEvent: { selectedEvent = $0 },
                onCreateEvent: { date in
                    createForDate = date
                    showCreateSheet = true
                }
            )
        }
    }

    private func weekDayHeaders(days: [Date]) -> some View {
        let cal = Calendar.current
        let timeAxisWidth: CGFloat = 48
        return HStack(spacing: 0) {
            Color.clear.frame(width: timeAxisWidth)
            ForEach(days, id: \.self) { day in
                let isToday = cal.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(weekdayLabel(day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isToday ? Color.appAccent : .secondary)
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 18, weight: isToday ? .bold : .light))
                        .foregroundStyle(isToday ? Color.white : .primary)
                        .frame(width: 32, height: 32)
                        .background {
                            if isToday { Circle().fill(Color.appAccent) }
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    private func weekdayLabel(_ date: Date) -> String {
        CalendarFmt.weekdayShort.string(from: date)
    }

    // MARK: - Unauthorized

    private var unauthorizedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("calendar.accessHint"))
                .font(DS.Font.label())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("calendar.requestAccess")) {
                Task {
                    let granted = await service.requestAccess()
                    authStatus = EKEventStore.authorizationStatus(for: .event)
                    if granted { await reload() }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
    }

    // MARK: - Helpers

    private func eventsOn(_ date: Date) -> [CalendarEventItem] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { event in
            event.startDate < dayEnd && event.endDate > dayStart
        }.map { CalendarEventItem($0) }
        .sorted { $0.startDate < $1.startDate }
    }

    private func navigate(by delta: Int) {
        let cal = Calendar.current
        switch viewMode {
        case .month:
            referenceDate = cal.date(byAdding: .month, value: delta, to: referenceDate) ?? referenceDate
        case .week:
            referenceDate = cal.date(byAdding: .weekOfYear, value: delta, to: referenceDate) ?? referenceDate
        }
    }

    private func load() async {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        allCalendars = service.allCalendars()
        if authStatus == .fullAccess { await reload() }
    }

    private func reload() async {
        guard authStatus == .fullAccess else { return }
        isLoading = true
        let (s, e) = visibleRange
        events = service.fetchEvents(from: s, to: e, calendars: nil)
        isLoading = false
    }
}
