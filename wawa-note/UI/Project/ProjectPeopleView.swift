import SwiftUI
import SwiftData

// MARK: - DEPRECATED: Subsumed by file browser with type filter (2026-06-18)
struct PersonSummary: Identifiable {
    let id: UUID
    let name: String
    let role: String?
    let taskCount: Int
    let openTaskCount: Int
    let mentionCount: Int
}

struct ProjectPeopleView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: ServiceContainer
    @State private var people: [PersonSummary] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading people...")
                Spacer()
            } else if people.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "person.2").font(.title).foregroundStyle(.secondary)
                    Text("No people identified").font(.headline)
                    Text("People are extracted from analysis and task assignments.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    Section("\(people.count) people") {
                        ForEach(people) { p in
                            personRow(p)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await loadPeople() }
    }

    private func personRow(_ p: PersonSummary) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "person.circle.fill")
                .font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.subheadline).fontWeight(.medium)
                if let role = p.role {
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if p.openTaskCount > 0 {
                    Text("\(p.openTaskCount) open").font(.caption2).foregroundStyle(.orange)
                }
                Text("\(p.taskCount) tasks").font(.caption2).foregroundStyle(.secondary)
                if p.mentionCount > 0 {
                    Text("\(p.mentionCount) mentions").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func loadPeople() async {
        let projSvc = services.projects
        let taskSvc = TaskService(context: modelContext)
        let store = FileArtifactStore()
        guard let tasks = try? taskSvc.tasks(for: projectID),
              let items = try? projSvc.items(in: projectID) else {
            isLoading = false
            return
        }

        var nameToSummary: [String: (id: UUID, role: String?, taskCount: Int, openTaskCount: Int, mentionCount: Int)] = [:]

        // From tasks
        for task in tasks {
            guard let owner = task.ownerName, !owner.isEmpty else { continue }
            var s = nameToSummary[owner] ?? (UUID(), nil, 0, 0, 0)
            s.taskCount += 1
            if task.status == .todo || task.status == .inProgress { s.openTaskCount += 1 }
            nameToSummary[owner] = s
        }

        // From analysis
        for item in items {
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for action in analysis.actionItems {
                guard let owner = action.owner, !owner.isEmpty else { continue }
                var s = nameToSummary[owner] ?? (UUID(), nil, 0, 0, 0)
                s.mentionCount += 1
                nameToSummary[owner] = s
            }
        }

        // From Person model
        let persons = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        for person in persons {
            var s = nameToSummary[person.displayName] ?? (person.id, person.role, 0, 0, 0)
            s.id = person.id
            s.role = person.role
            nameToSummary[person.displayName] = s
        }

        people = nameToSummary.map { PersonSummary(id: $1.id, name: $0, role: $1.role, taskCount: $1.taskCount, openTaskCount: $1.openTaskCount, mentionCount: $1.mentionCount) }
            .sorted { $0.taskCount > $1.taskCount }
        isLoading = false
    }
}
