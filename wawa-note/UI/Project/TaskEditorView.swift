import SwiftUI
import SwiftData

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum Mode {
        case create(projectID: UUID?)
        case edit(task: TaskItem)
    }

    let mode: Mode

    @State private var title: String
    @State private var ownerName: String
    @State private var priority: TaskPriority
    @State private var dueAt: Date?
    @State private var hasDueDate: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _ownerName = State(initialValue: "")
            _priority = State(initialValue: .medium)
            _dueAt = State(initialValue: nil)
            _hasDueDate = State(initialValue: false)
        case .edit(let task):
            _title = State(initialValue: task.title)
            _ownerName = State(initialValue: task.ownerName ?? "")
            _priority = State(initialValue: task.priority)
            _dueAt = State(initialValue: task.dueAt)
            _hasDueDate = State(initialValue: task.dueAt != nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("What needs to be done?", text: $title, axis: .vertical)
                }

                Section("Details") {
                    TextField("Owner name", text: $ownerName)

                    Picker("Priority", selection: $priority) {
                        ForEach(TaskPriority.allCases, id: \.self) { p in
                            Label(priorityLabel(p), systemImage: priorityIcon(p))
                                .tag(p)
                        }
                    }

                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: Binding(
                            get: { dueAt ?? Date() },
                            set: { dueAt = $0 }
                        ), displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: "New Task"
        case .edit: "Edit Task"
        }
    }

    private func save() {
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTitle.isEmpty else { return }

        let service = TaskService(context: modelContext)

        switch mode {
        case .create(let projectID):
            let _ = try? service.create(
                title: finalTitle,
                projectID: projectID,
                priority: priority,
                ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerName.trimmingCharacters(in: .whitespacesAndNewlines),
                dueAt: hasDueDate ? dueAt : nil
            )

        case .edit(let task):
            try? service.updateTask(
                task,
                title: finalTitle,
                ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerName,
                priority: priority,
                dueAt: hasDueDate ? dueAt : nil
            )
        }

        dismiss()
    }

    private func priorityLabel(_ p: TaskPriority) -> String {
        switch p {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }

    private func priorityIcon(_ p: TaskPriority) -> String {
        switch p {
        case .low: "arrow.down"
        case .medium: "minus"
        case .high: "arrow.up"
        case .critical: "exclamationmark.triangle"
        }
    }
}
