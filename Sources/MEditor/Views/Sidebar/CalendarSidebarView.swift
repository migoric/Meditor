import EventKit
import SwiftUI

/// 静态缓存的格式化器（DateFormatter 创建昂贵，仅在本文件 @MainActor 视图内使用）。
private enum SidebarFmt {
    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let timeShort: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
}

/// 侧边栏日历视图：展示未来 7 天的日程事件（需用户授权）。
@MainActor
struct CalendarSidebarView: View {
    @State private var events: [EKEvent] = []
    @State private var authStatus: EKAuthorizationStatus = .notDetermined
    @State private var isLoading = false

    @Environment(\.calendarService) private var service

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
        }
        .background(.clear)
        .task {
            await loadIfAuthorized()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(L("sidebar.calendar"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if authStatus == .fullAccess {
                Button {
                    Task { await refreshEvents() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("calendar.refreshHint"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let isAuthorized = (authStatus == .fullAccess)

        if !isAuthorized {
            unauthorizedView
        } else if events.isEmpty && !isLoading {
            emptyView
        } else {
            eventList
        }
    }

    private var unauthorizedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("calendar.accessHint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("calendar.requestAccess")) {
                Task {
                    let granted = await service.requestAccess()
                    authStatus = EKEventStore.authorizationStatus(for: .event)
                    if granted { await refreshEvents() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.appAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("calendar.empty"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedEvents, id: \.0) { (dateKey, dayEvents) in
                    Section {
                        ForEach(dayEvents, id: \.eventIdentifier) { event in
                            CalendarEventRow(event: event)
                        }
                    } header: {
                        Text(sectionTitle(for: dateKey))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .kerning(0.2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - Helpers

    private var groupedEvents: [(String, [EKEvent])] {
        var dict: [(String, [EKEvent])] = []
        var seen: [String: Int] = [:]
        for event in events {
            let key = SidebarFmt.dayKey.string(from: event.startDate)
            if let idx = seen[key] {
                dict[idx].1.append(event)
            } else {
                seen[key] = dict.count
                dict.append((key, [event]))
            }
        }
        return dict
    }

    private func sectionTitle(for dateKey: String) -> String {
        guard let date = SidebarFmt.dayKey.date(from: dateKey) else { return dateKey }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("calendar.today") }
        if cal.isDateInTomorrow(date) { return L("calendar.tomorrow") }
        return CalendarFmt.dayHeader.string(from: date)
    }

    private func loadIfAuthorized() async {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if authStatus == .fullAccess {
            await refreshEvents()
        }
    }

    private func refreshEvents() async {
        isLoading = true
        // CalendarService 是 @MainActor，直接 await 即可
        events = service.fetchEvents(days: 7)
        isLoading = false
    }
}

// MARK: - Event Row

private struct CalendarEventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 10) {
            // 日历颜色标识点
            Circle()
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? L("event.untitled"))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(timeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var timeLabel: String {
        if event.isAllDay { return L("calendar.allDay") }
        return "\(SidebarFmt.timeShort.string(from: event.startDate)) – \(SidebarFmt.timeShort.string(from: event.endDate))"
    }
}
