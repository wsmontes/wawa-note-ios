import SwiftUI
import EventKit

struct DayTimelineView: View {
    @EnvironmentObject private var calendarSync: CalendarSyncService

    let date: Date
    let items: [KnowledgeItem]

    private let cal = Calendar.current
    private let hourRange = 0..<24

    var body: some View {
        let events = calendarSync.unifiedEvents(for: date, items: items)
        let timedEvents = events.filter { !$0.isAllDay }
        let layout = computeLayout(for: timedEvents)
        let allDayEvents = events.filter { $0.isAllDay }

        VStack(spacing: 0) {
            if !allDayEvents.isEmpty {
                DayHeaderView(events: allDayEvents)
            }
            timelineScroll(events: timedEvents, layout: layout)
        }
        .navigationTitle(cal.startOfDay(for: date).formatted(.dateTime.day().month(.wide).weekday(.wide)))
    }

    // MARK: - Concurrent event layout

    /// For each event, determines its column index and total columns in its overlap cluster.
    /// Events that overlap are placed side-by-side instead of stacking invisibly.
    private func computeLayout(for events: [CalendarEvent]) -> [String: EventColumn] {
        guard !events.isEmpty else { return [:] }

        let sorted = events.sorted { a, b in
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            return a.endDate > b.endDate
        }

        // Group overlapping events into clusters using a sweep line
        var clusters: [[CalendarEvent]] = []
        var currentCluster: [CalendarEvent] = []
        var clusterEnd = Date.distantPast

        for event in sorted {
            if event.startDate >= clusterEnd {
                if !currentCluster.isEmpty {
                    clusters.append(currentCluster)
                }
                currentCluster = [event]
                clusterEnd = event.endDate
            } else {
                currentCluster.append(event)
                clusterEnd = max(clusterEnd, event.endDate)
            }
        }
        if !currentCluster.isEmpty { clusters.append(currentCluster) }

        // For each cluster, assign columns
        var result: [String: EventColumn] = [:]

        for cluster in clusters {
            // Columns: each is the end time of the last event placed in it
            var columnEnds: [Date] = []

            for event in cluster {
                // Find first available column
                var colIndex = 0
                for (i, endTime) in columnEnds.enumerated() {
                    if event.startDate >= endTime {
                        colIndex = i
                        break
                    }
                    colIndex = i + 1
                }

                if colIndex < columnEnds.count {
                    columnEnds[colIndex] = event.endDate
                } else {
                    columnEnds.append(event.endDate)
                }

                result[event.id] = EventColumn(
                    column: colIndex,
                    totalColumns: columnEnds.count
                )
            }

            // Second pass: update totalColumns now that all events are placed
            for event in cluster {
                result[event.id]?.totalColumns = columnEnds.count
            }
        }

        return result
    }

    // MARK: - Timeline

    private func timelineScroll(events: [CalendarEvent], layout: [String: EventColumn]) -> some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Hour slots
                VStack(spacing: 0) {
                    ForEach(hourRange, id: \.self) { hour in
                        HourSlot(hour: hour)
                    }
                }

                // Event cards positioned at time offsets with side-by-side layout
                ForEach(events) { event in
                    let column = layout[event.id] ?? EventColumn(column: 0, totalColumns: 1)
                    EventCard(event: event, column: column)
                        .offset(x: xOffset(for: column), y: yOffset(for: event.startDate))
                        .padding(.leading, 48)
                        .padding(.trailing, 0)
                }
            }
        }
    }

    private func xOffset(for column: EventColumn) -> CGFloat {
        guard column.totalColumns > 1 else { return 0 }
        let slotWidth = availableTimelineWidth / CGFloat(column.totalColumns)
        return slotWidth * CGFloat(column.column)
    }

    private var availableTimelineWidth: CGFloat {
        // Approximate — the timeline area after the hour label column.
        // 48pt is the leading padding reserved for hour labels.
        UIScreen.main.bounds.width - 48 - 8 // 8pt trailing margin
    }

    private func yOffset(for eventDate: Date) -> CGFloat {
        let hour = cal.component(.hour, from: eventDate)
        let minute = cal.component(.minute, from: eventDate)
        return CGFloat(hour) * HourSlot.height + CGFloat(minute) / 60.0 * HourSlot.height
    }
}

// MARK: - Event layout data

private struct EventColumn {
    let column: Int
    var totalColumns: Int
}

// MARK: - Day Header

private struct DayHeaderView: View {
    let events: [CalendarEvent]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(events) { event in
                HStack {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text(event.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Hour Slot

private struct HourSlot: View {
    let hour: Int
    static let height: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            Text(formattedHour)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 4)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
        }
        .frame(height: Self.height)
    }

    private var formattedHour: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) else {
            return "\(hour):00"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Event Card

private struct EventCard: View {
    let event: CalendarEvent
    let column: EventColumn

    @State private var showPreview = false

    var body: some View {
        Button {
            showPreview = true
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(event.isAllDay ? 1 : 2)
                Text(timeRange)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: cardWidth, alignment: .leading)
            .frame(height: cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(event.isFromWawaNote ? Color.accentColor.opacity(0.2) : Color.blue.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(event.isFromWawaNote ? Color.accentColor : Color.blue, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPreview) {
            if event.isFromWawaNote, let item = event.item {
                NavigationStack {
                    KnowledgeDetailView(item: item)
                }
            } else {
                EventPreviewSheet(event: event)
            }
        }
    }

    private var cardWidth: CGFloat {
        guard column.totalColumns > 1 else { return 300 } // won't be clipped
        let slotWidth = (UIScreen.main.bounds.width - 52) / CGFloat(column.totalColumns)
        return max(slotWidth - 4, 60) // 4pt gap between columns
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if event.isAllDay { return "All Day" }
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }

    private var cardHeight: CGFloat {
        let minutes = max(event.durationMinutes, 15)
        return CGFloat(minutes) / 60.0 * HourSlot.height
    }
}
