import SwiftData
import SwiftUI

struct PendingSection: View {
    let projectID: UUID

    @Query private var openTasks: [ProjectDerivedItem]

    init(projectID: UUID) {
        self.projectID = projectID
        let pid = projectID
        let todoRaw = ProjectDerivedStatus.todo.rawValue
        let inProgressRaw = ProjectDerivedStatus.inProgress.rawValue
        _openTasks = Query(
            filter: #Predicate {
                $0.projectID == pid && $0.typeRaw == "task" && ($0.statusRaw == todoRaw || $0.statusRaw == inProgressRaw)
            },
            sort: \ProjectDerivedItem.dueAt, order: .forward
        )
    }

    var body: some View {
        if !openTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pending").font(.headline)

                ForEach(openTasks.prefix(5)) { task in
                    HStack(spacing: 8) {
                        Image(systemName: task.status == .inProgress ? "circle.dotted" : "circle")
                            .font(.caption)
                            .foregroundStyle(task.priorityRaw == "high" || task.priorityRaw == "critical" ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.subheadline)
                            if let owner = task.ownerName {
                                Text("@\(owner)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let due = task.dueAt {
                            Text(due.formatted(.relative(presentation: .numeric)))
                                .font(.caption2).foregroundStyle(due < Date() ? .red : .secondary)
                        }
                    }
                }

                if openTasks.count > 5 {
                    Text("+ \(openTasks.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
