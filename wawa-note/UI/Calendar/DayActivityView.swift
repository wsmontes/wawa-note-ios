import SwiftData
import SwiftUI
import WawaNoteCore

struct DayActivityView: View {
  let date: Date

  @EnvironmentObject private var calendarSync: CalendarSyncService
  @Environment(\.modelContext) private var modelContext
  @Query private var dayItems: [KnowledgeItem]
  @State private var mode: DayMode = .activity
  @State private var onThisDayEntries: [TimelineEntry] = []
  @State private var calendarEvents: [CalendarEvent] = []
  @State private var showNewNote = false
  @State private var showNewJournal = false

  enum DayMode: String, CaseIterable {
    case activity = "Activity"
    case schedule = "Schedule"
  }

  init(date: Date) {
    self.date = date
    let cal = Calendar.current
    let start = cal.startOfDay(for: date)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
    _dayItems = Query(
      filter: #Predicate { $0.createdAt >= start && $0.createdAt < end },
      sort: \KnowledgeItem.createdAt, order: .forward
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        onThisDaySection
        journalSection
        modePicker
        contentSection
      }
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle(date.formatted(date: .abbreviated, time: .omitted))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            showNewNote = true
          } label: {
            Label("New Note", systemImage: "square.and.pencil")
          }
          Button {
            showNewJournal = true
          } label: {
            Label("New Journal", systemImage: "book")
          }
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(isPresented: $showNewNote) {
      NoteEditorView(mode: .create(type: .note, folderID: nil, initialTag: nil))
    }
    .sheet(isPresented: $showNewJournal) {
      JournalEditorView(mode: .create(folderID: nil))
    }
    .task {
      let service = OnThisDayService(context: modelContext)
      onThisDayEntries = service.entries(for: date)
      calendarEvents = calendarSync.unifiedEvents(for: date, items: dayItems)
    }
  }

  // MARK: - On This Day

  @ViewBuilder
  private var onThisDaySection: some View {
    if !onThisDayEntries.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        sectionHeader("On This Day")

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(onThisDayEntries) { entry in
              NavigationLink {
                if let item = entry.wawaItem {
                  KnowledgeDetailView(item: item)
                }
              } label: {
                onThisDayCard(entry)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
        }
      }
      .padding(.top, 16)
    }
  }

  private func onThisDayCard(_ entry: TimelineEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(String(Calendar.current.component(.year, from: entry.createdAt)))
        .font(.caption.bold())
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        Image(systemName: entry.typeIcon)
          .font(.caption2)
          .foregroundStyle(entry.typeColor)
        Text(entry.title)
          .font(.caption)
          .lineLimit(2)
      }
    }
    .frame(width: 120)
    .padding(10)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Journal

  @ViewBuilder
  private var journalSection: some View {
    let journalToday = dayItems.first { $0.type == .journalEntry }
    VStack(alignment: .leading, spacing: 8) {
      if let journal = journalToday {
        NavigationLink {
          KnowledgeDetailView(item: journal)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "book.fill")
              .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
              Text(journal.title)
                .font(.subheadline).fontWeight(.medium)
              if let mood = TimelineEntry.extractMood(from: journal.tags) {
                Text("Mood: \(mood)")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
          .padding(12)
          .background(Color(.systemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      } else {
        Button {
          showNewJournal = true
        } label: {
          HStack {
            Image(systemName: "book")
            Text("No journal for today. Write one?")
            Spacer()
            Image(systemName: "pencil")
          }
          .font(.subheadline)
          .padding(12)
          .background(Color(.systemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  // MARK: - Mode picker

  private var modePicker: some View {
    Picker("Mode", selection: $mode) {
      ForEach(DayMode.allCases, id: \.self) { m in
        Text(m.rawValue).tag(m)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  // MARK: - Content

  @ViewBuilder
  private var contentSection: some View {
    switch mode {
    case .activity:
      activityFeed
    case .schedule:
      scheduleView
    }
  }

  private var activityFeed: some View {
    VStack(spacing: 8) {
      if dayItems.isEmpty {
        Text("No activity on this day")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 32)
      } else {
        ForEach(dayItems) { item in
          let entry = TimelineEntry(item: item)
          NavigationLink {
            KnowledgeDetailView(item: item)
          } label: {
            activityCard(entry)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 16)
  }

  private func activityCard(_ entry: TimelineEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(entry.timeString)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 60, alignment: .leading)

      Image(systemName: entry.typeIcon)
        .font(.subheadline)
        .foregroundStyle(entry.typeColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.title)
          .font(.subheadline)
          .lineLimit(2)
        if let body = entry.bodySnippet {
          Text(body)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 8) {
          if let mood = entry.mood {
            Text("Mood: \(mood)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if let duration = entry.durationMinutes {
            Text("\(duration)m")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Schedule (WawaNote + iPhone events)

  private var scheduleView: some View {
    VStack(spacing: 0) {
      if calendarEvents.isEmpty {
        Text("No events on this day")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 32)
      } else {
        ForEach(Array(calendarEvents.enumerated()), id: \.element.id) { _, event in
          scheduleCard(event)
        }
      }
    }
  }

  private func scheduleCard(_ event: CalendarEvent) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 2) {
        Text(event.startDate.formatted(date: .omitted, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
        if !event.isAllDay {
          Text(event.endDate.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 70, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(event.title)
          .font(.subheadline)
          .lineLimit(2)

        HStack(spacing: 6) {
          Circle()
            .fill(event.isFromWawaNote ? Color.accentColor : .blue)
            .frame(width: 6, height: 6)
          Text(event.isFromWawaNote ? "Wawa Note" : "iPhone Calendar")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if event.isFromWawaNote, let item = event.item {
          HStack(spacing: 4) {
            Image(systemName: item.type.icon)
              .font(.caption2)
              .foregroundStyle(item.type.color)
            Text(item.type.label)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        if let location = event.location, !location.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "mappin")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(location)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
      Spacer()

      if event.isFromWawaNote, let item = event.item {
        NavigationLink {
          KnowledgeDetailView(item: item)
        } label: {
          Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(12)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal, 16)
    .padding(.vertical, 3)
  }

  // MARK: - Helpers

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .padding(.horizontal, 16)
  }
}
