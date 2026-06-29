import SwiftUI

struct MonthGridView: View {
    let month: Date
    let daySummaries: [Date: DaySummary]
    let onDayLongPress: ((Date) -> Void)?

    private let cal = Calendar.current

    var body: some View {
        let days = computeDays()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(days) { dayInfo in
                let summary = dayInfo.isCurrentMonth ? daySummaries[cal.startOfDay(for: dayInfo.date)] : nil
                let hasContent = summary != nil

                Group {
                    if dayInfo.isCurrentMonth && hasContent {
                        NavigationLink(value: dayInfo.date) {
                            DayCellView(day: dayInfo, summary: summary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let onLongPress = onDayLongPress {
                                Button {
                                    onLongPress(dayInfo.date)
                                } label: {
                                    Label("New Note", systemImage: "square.and.pencil")
                                }
                                Button {
                                    onLongPress(dayInfo.date)
                                } label: {
                                    Label("New Journal", systemImage: "book")
                                }
                            }
                        }
                    } else {
                        DayCellView(day: dayInfo, summary: summary)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func computeDays() -> [DayInfo] {
        guard let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) else {
            return []
        }
        let firstWeekday = cal.firstWeekday
        let weekday = cal.component(.weekday, from: firstOfMonth)  // 1=Sun, 7=Sat
        let leadingEmpty = (weekday - firstWeekday + 7) % 7

        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let totalCells = 42

        var days: [DayInfo] = []

        if leadingEmpty > 0, let prevMonth = cal.date(byAdding: .month, value: -1, to: firstOfMonth) {
            let prevDays = cal.range(of: .day, in: .month, for: prevMonth)?.count ?? 30
            for i in (prevDays - leadingEmpty + 1)...prevDays {
                let date = cal.date(byAdding: .day, value: i - 1, to: prevMonth) ?? prevMonth
                days.append(DayInfo(id: "prev-\(i)", date: date, dayNumber: i, isCurrentMonth: false, isToday: cal.isDateInToday(date)))
            }
        }

        for day in 1...daysInMonth {
            let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) ?? firstOfMonth
            days.append(DayInfo(id: "curr-\(day)", date: date, dayNumber: day, isCurrentMonth: true, isToday: cal.isDateInToday(date)))
        }

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

struct DayInfo: Identifiable {
    let id: String
    let date: Date
    let dayNumber: Int
    let isCurrentMonth: Bool
    let isToday: Bool
}
