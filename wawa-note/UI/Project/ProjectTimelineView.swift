import SwiftUI
import SwiftData

struct ProjectTimelineView: View {
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var events: [TimelineEvent] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading timeline...")
            } else if events.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No events yet")
                        .font(.headline)
                    Text("Events will appear as meetings are recorded, tasks are created, and decisions are made.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                timelineList
            }
        }
        .task { loadTimeline() }
    }

    // MARK: - Timeline

    private var timelineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                    HStack(alignment: .top, spacing: 12) {
                        // Timeline indicator
                        VStack(spacing: 0) {
                            Circle()
                                .fill(eventColor(event.kind))
                                .frame(width: 12, height: 12)

                            if idx < events.count - 1 {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(width: 2)
                                    .frame(maxHeight: .infinity)
                            }
                        }

                        // Event card
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: eventIcon(event.kind))
                                    .font(.caption)
                                    .foregroundStyle(eventColor(event.kind))
                                Text(event.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            if let subtitle = event.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 16)
                    .padding(.bottom, 4)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Load

    private func loadTimeline() {
        var events: [TimelineEvent] = []

        // Items in project
        if let items = try? modelContext.fetch(
            FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.projectID == projectID })
        ) {
            for item in items {
                events.append(TimelineEvent(
                    id: item.id, title: item.title.isEmpty ? "Meeting" : item.title,
                    subtitle: item.type.label, date: item.createdAt, kind: item.type == .meeting ? .meeting : .note
                ))
            }
        }

        // Tasks in project
        if let tasks = try? modelContext.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.projectID == projectID })
        ) {
            for task in tasks {
                events.append(TimelineEvent(
                    id: task.id, title: task.title,
                    subtitle: "Task · \(task.status.rawValue.capitalized)",
                    date: task.createdAt, kind: .task
                ))
                if task.status == .done {
                    events.append(TimelineEvent(
                        id: UUID(), title: "Completed: \(task.title)",
                        subtitle: "Task done", date: task.updatedAt, kind: .done
                    ))
                }
            }
        }

        self.events = events.sorted { $0.date > $1.date }
        self.isLoading = false
    }

    // MARK: - Helpers

    private func eventColor(_ kind: TimelineEventKind) -> Color {
        switch kind {
        case .meeting: return .blue
        case .note: return .orange
        case .task: return .green
        case .done: return .gray
        case .decision: return .purple
        case .person: return .indigo
        }
    }

    private func eventIcon(_ kind: TimelineEventKind) -> String {
        switch kind {
        case .meeting: return "recordingtape"
        case .note: return "note.text"
        case .task: return "checklist"
        case .done: return "checkmark.circle"
        case .decision: return "lightbulb"
        case .person: return "person"
        }
    }
}

// MARK: - Models

enum TimelineEventKind {
    case meeting
    case note
    case task
    case decision
    case person
    case done
}

struct TimelineEvent: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let date: Date
    let kind: TimelineEventKind
}
