import SwiftUI
// Related JIRA: KAN-54, KAN-144


struct DayCellView: View {
    let day: DayInfo
    let summary: DaySummary?

    private let cal = Calendar.current
    private let maxDots = 3

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if day.isToday {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                }
                HStack(spacing: 1) {
                    Text("\(day.dayNumber)")
                        .font(.system(size: 14, weight: day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isCurrentMonth ? (day.isToday ? .white : .primary) : .secondary.opacity(0.4))
                    if summary?.hasOnThisDay == true {
                        Image(systemName: "sparkle")
                            .font(.system(size: 7))
                            .foregroundStyle(day.isToday ? .white.opacity(0.8) : .orange)
                    }
                }
            }

            if let summary, summary.totalItems > 0 {
                HStack(spacing: 2) {
                    let types = summary.dots(count: maxDots)
                    ForEach(types, id: \.self) { type in
                        Circle()
                            .fill(type.color)
                            .frame(width: 4, height: 4)
                    }
                    if summary.totalItems > maxDots {
                        Text("+\(summary.totalItems - maxDots)")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }
}
