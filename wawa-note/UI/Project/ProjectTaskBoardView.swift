import SwiftUI
import SwiftData

struct ProjectTaskBoardView: View {
    let tasks: [TaskItem]
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var editingTask: TaskItem?
    @State private var showNewTask = false
    @State private var newTaskStatus: TaskStatus = .todo

    private let columns: [TaskStatus] = [.todo, .inProgress, .done, .cancelled]

    var body: some View {
        VStack(spacing: 0) {
            if tasks.isEmpty && !showNewTask {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "checklist.unchecked")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No tasks yet")
                        .font(.headline)
                    Text("Promote a meeting to a project or add a task manually.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button {
                        newTaskStatus = .todo
                        showNewTask = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
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
        .sheet(item: $editingTask) { task in
            TaskEditorView(mode: .edit(task: task))
        }
        .sheet(isPresented: $showNewTask) {
            TaskEditorView(mode: .create(projectID: projectID))
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

                Button {
                    newTaskStatus = status
                    showNewTask = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(columnTasks, id: \.id) { task in
                        taskCard(task, status: status)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func taskCard(_ task: TaskItem, status: TaskStatus) -> some View {
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
                if let next = nextStatus(status) {
                    Button {
                        advanceTask(task, to: next)
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
        .onTapGesture {
            editingTask = task
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTask(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if let prev = previousStatus(status) {
                Button {
                    advanceTask(task, to: prev)
                } label: {
                    Label("Move Back", systemImage: "arrow.left.circle")
                }
                .tint(.gray)
            }
        }
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

    private func deleteTask(_ task: TaskItem) {
        let svc = TaskService(context: modelContext)
        try? svc.deleteTask(task)
    }

    private func nextStatus(_ current: TaskStatus) -> TaskStatus? {
        switch current {
        case .todo: .inProgress
        case .inProgress: .done
        case .done: nil
        case .cancelled: nil
        }
    }

    private func previousStatus(_ current: TaskStatus) -> TaskStatus? {
        switch current {
        case .todo: nil
        case .inProgress: .todo
        case .done: .inProgress
        case .cancelled: nil
        }
    }

    private func statusLabel(_ status: TaskStatus) -> String {
        switch status {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    private func priorityColor(_ p: TaskPriority) -> Color {
        switch p {
        case .critical: .red
        case .high: .orange
        case .medium: .blue
        case .low: .green
        }
    }
}
