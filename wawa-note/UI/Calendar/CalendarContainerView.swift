import SwiftUI
import SwiftData

struct CalendarContainerView: View {
    @EnvironmentObject private var calendarSync: CalendarSyncService
    @Query(filter: #Predicate<KnowledgeItem> { $0.typeRaw == "meeting" }, sort: \KnowledgeItem.createdAt, order: .reverse) private var items: [KnowledgeItem]

    @State private var displayedMonth: Date

    init() {
        _displayedMonth = State(initialValue: Date())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MonthHeaderView(displayedMonth: $displayedMonth)
                dayOfWeekHeader
                MonthGridView(
                    month: displayedMonth,
                    eventDates: calendarSync.eventDatesForMonth(containing: displayedMonth, items: items)
                )
            }
            .navigationDestination(for: Date.self) { day in
                DayTimelineView(date: day, items: items)
            }
            .task {
                if !calendarSync.hasPermission {
                    _ = await calendarSync.requestPermission()
                }
            }
        }
    }

    private var dayOfWeekHeader: some View {
        let cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols
        // Start with Sunday as first day
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[i])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

// MARK: - Month Header

private struct MonthHeaderView: View {
    @Binding var displayedMonth: Date

    var body: some View {
        HStack {
            Button {
                withAnimation { displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth }
            } label: {
                Image(systemName: "chevron.left")
            }

            Spacer()
            Text(monthYearString)
                .font(.headline)
            Spacer()

            Button {
                withAnimation { displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth }
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }
}

// MARK: - Month Grid

private struct MonthGridView: View {
    let month: Date
    let eventDates: Set<Date>

    private let cal = Calendar.current

    var body: some View {
        let days = computeDays()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(days) { dayInfo in
                if dayInfo.isCurrentMonth {
                    NavigationLink(value: dayInfo.date) {
                        DayCell(day: dayInfo, eventDates: eventDates)
                    }
                    .buttonStyle(.plain)
                } else {
                    DayCell(day: dayInfo, eventDates: eventDates)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func computeDays() -> [DayInfo] {
        guard let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) else {
            return []
        }
        let weekday = cal.component(.weekday, from: firstOfMonth) // 1=Sun, 7=Sat
        let leadingEmpty = weekday - 1

        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let totalCells = 42 // 6 rows × 7 cols — always show full grid

        var days: [DayInfo] = []

        // Leading days from previous month
        if leadingEmpty > 0, let prevMonth = cal.date(byAdding: .month, value: -1, to: firstOfMonth) {
            let prevDays = cal.range(of: .day, in: .month, for: prevMonth)?.count ?? 30
            for i in (prevDays - leadingEmpty + 1)...prevDays {
                let date = cal.date(byAdding: .day, value: i - 1, to: prevMonth) ?? prevMonth
                days.append(DayInfo(id: "prev-\(i)", date: date, dayNumber: i, isCurrentMonth: false, isToday: cal.isDateInToday(date)))
            }
        }

        // Current month days
        for day in 1...daysInMonth {
            let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) ?? firstOfMonth
            days.append(DayInfo(id: "curr-\(day)", date: date, dayNumber: day, isCurrentMonth: true, isToday: cal.isDateInToday(date)))
        }

        // Trailing days for next month
        let remaining = totalCells - days.count
        if remaining > 0, let nextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth) {
            for day in 1...remaining {
                let date = cal.date(byAdding: .day, value: day - 1, to: nextMonth) ?? nextMonth
                days.append(DayInfo(id: "next-\(day)", date: date, dayNumber: day, isCurrentMonth: false, isToday: cal.isDateInToday(date)))
            }
        }

        return days
    }
}

// MARK: - Day Cell

private struct DayCell: View {
    let day: DayInfo
    let eventDates: Set<Date>

    private let cal = Calendar.current
    private var hasEvents: Bool {
        eventDates.contains(cal.startOfDay(for: day.date))
    }

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                if day.isToday {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                }
                Text("\(day.dayNumber)")
                    .font(.system(size: 14, weight: day.isToday ? .bold : .regular))
                    .foregroundStyle(day.isCurrentMonth ? (day.isToday ? .white : .primary) : .secondary.opacity(0.4))
            }
            Circle()
                .fill(hasEvents ? Color.accentColor : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(height: 36)
    }
}

// MARK: - DayInfo

private struct DayInfo: Identifiable {
    let id: String
    let date: Date
    let dayNumber: Int
    let isCurrentMonth: Bool
    let isToday: Bool
}
