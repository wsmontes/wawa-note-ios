import SwiftData
import SwiftUI
import WawaNoteCore

struct TimelineExplorerView: View {
  @EnvironmentObject private var calendarSync: CalendarSyncService
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \KnowledgeItem.createdAt, order: .reverse) private var allItems: [KnowledgeItem]

  @State private var displayedMonth: Date
  @State private var daySummaries: [Date: DaySummary] = [:]
  @State private var showPermissionSheet = false

  init() {
    _displayedMonth = State(initialValue: Date())
  }

  var body: some View {
    VStack(spacing: 0) {
      monthHeader
      dayOfWeekHeader
      MonthGridView(
        month: displayedMonth,
        daySummaries: daySummaries,
        onDayLongPress: { _ in }
      )

      if !calendarSync.hasPermission {
        calendarPermissionBanner
      }
    }
    .navigationTitle("Timeline")
    .navigationDestination(for: Date.self) { day in
      DayActivityView(date: day)
    }
    .task {
      if !calendarSync.hasPermission {
        _ = await calendarSync.requestPermission()
      }
    }
    .onAppear { buildSummaries() }
    .onChange(of: displayedMonth) { _, _ in buildSummaries() }
    .onChange(of: allItems.count) { _, _ in buildSummaries() }
  }

  // MARK: - Month header

  private var monthHeader: some View {
    HStack {
      Button {
        withAnimation {
          displayedMonth =
            Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        }
      } label: {
        Image(systemName: "chevron.left")
          .accessibilityLabel("Previous month")
      }

      Spacer()
      Text(monthYearString)
        .font(.headline)
      Spacer()

      Button {
        withAnimation {
          displayedMonth =
            Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        }
      } label: {
        Image(systemName: "chevron.right")
          .accessibilityLabel("Next month")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .overlay(alignment: .trailing) {
      if !Calendar.current.isDate(displayedMonth, equalTo: Date(), toGranularity: .month) {
        Button("Today") {
          withAnimation { displayedMonth = Date() }
        }
        .font(.subheadline)
        .padding(.trailing, 12)
      }
    }
  }

  private var monthYearString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter.string(from: displayedMonth)
  }

  // MARK: - Day of week header (locale-aware)

  private var dayOfWeekHeader: some View {
    let cal = Calendar.current
    let firstWeekday = cal.firstWeekday
    let symbols = cal.shortWeekdaySymbols
    // Rotate so firstWeekday comes first
    let ordered = Array(symbols[(firstWeekday - 1)...] + symbols[..<(firstWeekday - 1)])

    return HStack(spacing: 0) {
      ForEach(0..<7, id: \.self) { i in
        Text(ordered[i])
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 6)
  }

  // MARK: - Permission banner

  private var calendarPermissionBanner: some View {
    Button {
      showPermissionSheet = true
    } label: {
      HStack {
        Image(systemName: "calendar.badge.plus")
          .accessibilityLabel("Connect Calendar")
        Text("Connect iPhone Calendar")
          .font(.subheadline).fontWeight(.medium)
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
      .padding(12)
      .background(Color.blue.opacity(0.08))
      .padding(.horizontal, 16)
      .padding(.top, 8)
    }
    .buttonStyle(.plain)
    .sheet(isPresented: $showPermissionSheet) {
      CalendarPermissionView(onRequestPermission: { await calendarSync.requestPermission() })
    }
  }

  // MARK: - Build summaries

  private func buildSummaries() {
    let builder = DaySummaryBuilder(context: modelContext)
    daySummaries = builder.build(for: displayedMonth, items: allItems)
  }
}
