import SwiftUI
import SwiftData

// MARK: - DEPRECATED: Subsumed by BoardView using ProjectDerivedItem (2026-06-18)
struct ProjectTaskBoardView: View {
    let tasks: [ProjectDerivedItem]
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var editingTask: ProjectDerivedItem?
    @State private var showNewTask = false
    @State private var newTaskStatus: TaskStatus = .todo

    private let columns: [TaskStatus] = [.todo, .inProgress, .done, .cancelled]

    var body: some View {
        VStack(spacing: 0) {
            if tasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "checklist.unchecked")
                        .font(.title).foregroundStyle(.secondary)
                    Text("No tasks yet")
                        .font(.headline)
                    Text("Add a task or promote an item from the library.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    Button { newTaskStatus = .todo; showNewTask = true } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.rawValue) { status in
                                taskColumn(status)
                                    .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 0)
                                    .id(status.rawValue)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .safeAreaInset(edge: .bottom) {
                        columnIndicator
                    }
                }
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(mode: .edit(task: task))
        }
        .sheet(isPresented: $showNewTask) {
            TaskEditorView(mode: .create(projectID: projectID))
        }
    }

    // MARK: - Column

    private func taskColumn(_ status: TaskStatus) -> some View {
        let columnTasks = tasks.filter { $0.statusRaw == status.rawValue }

        return VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(statusLabel(status))
                    .font(.headline)
                Spacer()
                Text("\(columnTasks.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())

                Button {
                    newTaskStatus = status
                    showNewTask = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Card list
            if columnTasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: statusEmptyIcon(status))
                        .font(.title2).foregroundStyle(.tertiary)
                    Text(statusEmptyText(status))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(columnTasks, id: \.id) { task in
                            taskCard(task, status: status)
                                .padding(.horizontal, AppSpacing.md)
                                .onTapGesture {
                                    editingTask = task
                                }
                                .swipeActions(edge: .leading) {
                                    if let prev = previousStatus(status) {
                                        Button {
                                            moveTask(task, to: prev)
                                        } label: {
                                            Label("Move to \(statusLabel(prev))", systemImage: "arrow.left")
                                        }.tint(statusColor(prev))
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if let next = nextStatus(status) {
                                        Button {
                                            moveTask(task, to: next)
                                        } label: {
                                            Label("Move to \(statusLabel(next))", systemImage: "arrow.right")
                                        }.tint(statusColor(next))
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Task card

    private func taskCard(_ task: ProjectDerivedItem, status: TaskStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(task.statusRaw == "cancelled" ? .secondary : .primary)
                        .strikethrough(task.statusRaw == "cancelled")
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let owner = task.ownerName {
                            Label(owner, systemImage: "person").font(.caption2).foregroundStyle(.secondary)
                        }
                        priorityBadge(TaskPriority(rawValue: task.priorityRaw ?? "medium") ?? .medium)
                        if let due = task.dueAt {
                            let urgency = due.timeIntervalSinceNow
                            Text(due.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(urgency < 0 ? .red : urgency < 259200 ? .orange : .secondary)
                        }
                    }

                    // Provenance footer
                    if let sourceID = task.sourceItemID, let sourceItem = findSourceItem(sourceID) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 7))
                            Text(sourceItem.title).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }

                    // Stale indicator
                    if task.statusRaw == TaskStatus.todo.rawValue, task.createdAt.timeIntervalSinceNow < -14 * 86400 {
                        Text("Stale — \(Int(-task.createdAt.timeIntervalSinceNow / 86400))d").font(.system(size: 8)).foregroundStyle(.orange)
                    }
                }
                .opacity(task.statusRaw == TaskStatus.todo.rawValue && task.createdAt.timeIntervalSinceNow < -14 * 86400 ? 0.6 : 1.0)
                Spacer()
                Menu {
                    ForEach(columns, id: \.rawValue) { col in
                        if col != status {
                            Button { moveTask(task, to: col) } label: {
                                Label("Move to \(statusLabel(col))", systemImage: "arrow.right")
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) { deleteTask(task) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    // MARK: - Column indicator

    private var columnIndicator: some View {
        HStack(spacing: 6) {
            ForEach(columns, id: \.rawValue) { status in
                let count = tasks.filter { $0.statusRaw == status.rawValue }.count
                Circle()
                    .fill(count > 0 ? Color.accentColor : Color(.tertiarySystemFill))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Priority

    @State private var sourceItemCache: [UUID: KnowledgeItem] = [:]

    private func findSourceItem(_ id: UUID) -> KnowledgeItem? {
        if let cached = sourceItemCache[id] { return cached }
        if sourceItemCache.isEmpty {
            let desc = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.projectID == projectID })
            if let items = try? modelContext.fetch(desc) {
                for item in items { sourceItemCache[item.id] = item }
            }
        }
        return sourceItemCache[id]
    }

    private func priorityBadge(_ priority: TaskPriority) -> some View {
        Text(priority.rawValue.capitalized)
            .font(.caption2)
            .foregroundStyle(priorityColor(priority))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(priorityColor(priority).opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func moveTask(_ task: ProjectDerivedItem, to status: TaskStatus) {
        let derivedStatus: ProjectDerivedStatus = {
            switch status {
            case .todo: .todo
            case .inProgress: .inProgress
            case .done: .done
            case .cancelled: .cancelled
            }
        }()
        try? ProjectDerivedItemService(context: modelContext).updateStatus(task, to: derivedStatus)
    }

    private func deleteTask(_ task: ProjectDerivedItem) {
        try? ProjectDerivedItemService(context: modelContext).delete(task)
    }

    // MARK: - Labels

    private func previousStatus(_ status: TaskStatus) -> TaskStatus? {
        switch status {
        case .todo: nil
        case .inProgress: .todo
        case .done: .inProgress
        case .cancelled: .done
        }
    }

    private func nextStatus(_ status: TaskStatus) -> TaskStatus? {
        switch status {
        case .todo: .inProgress
        case .inProgress: .done
        case .done: .cancelled
        case .cancelled: nil
        }
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .todo: .blue
        case .inProgress: .orange
        case .done: .green
        case .cancelled: .gray
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

    private func statusEmptyIcon(_ status: TaskStatus) -> String {
        switch status {
        case .todo: "circle"
        case .inProgress: "circle.dotted"
        case .done: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }

    private func statusEmptyText(_ status: TaskStatus) -> String {
        switch status {
        case .todo: "No tasks to do"
        case .inProgress: "Nothing in progress"
        case .done: "Nothing completed yet"
        case .cancelled: "No cancelled tasks"
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
