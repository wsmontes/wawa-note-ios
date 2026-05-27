import SwiftUI
import SwiftData

struct ProjectTaskBoardView: View {
    let tasks: [TaskItem]
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext

    private let columns: [TaskStatus] = [.todo, .inProgress, .done]

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 12) {
                Spacer().frame(height: 40)
                Image(systemName: "checklist.unchecked")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No tasks yet")
                    .font(.headline)
                Text("Promote a meeting to a project to extract action items as tasks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                ForEach(columns, id: \.rawValue) { status in
                    taskColumn(status)
                }
            }
            .padding(12)
        }
    }

    private func taskColumn(_ status: TaskStatus) -> some View {
        let columnTasks = tasks.filter { $0.status == status }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusLabel(status))
                    .font(.footnote)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(columnTasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 4)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(columnTasks, id: \.id) { task in
                        taskCard(task, newStatus: nextStatus(status))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func taskCard(_ task: TaskItem, newStatus: TaskStatus?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.subheadline)
                .lineLimit(3)

            HStack(spacing: 6) {
                if let owner = task.ownerName {
                    Label(owner, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                priorityBadge(task.priority)
                Spacer()
                if let newStatus {
                    Button {
                        advanceTask(task, to: newStatus)
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    private func priorityBadge(_ priority: TaskPriority) -> some View {
        Text(priority.rawValue.capitalized)
            .font(.caption2)
            .foregroundStyle(priorityColor(priority))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(priorityColor(priority).opacity(0.1))
            .clipShape(Capsule())
    }

    private func advanceTask(_ task: TaskItem, to status: TaskStatus) {
        let svc = TaskService(context: modelContext)
        try? svc.updateStatus(task, to: status)
    }

    private func nextStatus(_ current: TaskStatus) -> TaskStatus? {
        switch current {
        case .todo: return .inProgress
        case .inProgress: return .done
        case .done: return nil
        case .cancelled: return nil
        }
    }

    private func statusLabel(_ status: TaskStatus) -> String {
        switch status {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        }
    }

    private func priorityColor(_ p: TaskPriority) -> Color {
        switch p {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .blue
        case .low: return .green
        }
    }
}
