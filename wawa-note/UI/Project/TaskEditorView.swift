import SwiftUI
import SwiftData

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: ServiceContainer

    enum Mode {
        case create(projectID: UUID?)
        case edit(task: ProjectDerivedItem)
    }

    let mode: Mode

    @State private var title: String
    @State private var ownerName: String
    @State private var priority: TaskPriority
    @State private var dueAt: Date?
    @State private var hasDueDate: Bool
    @State private var notes: String
    @State private var selectedSourceItemID: UUID?

    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _ownerName = State(initialValue: "")
            _priority = State(initialValue: .medium)
            _dueAt = State(initialValue: nil)
            _hasDueDate = State(initialValue: false)
            _notes = State(initialValue: "")
            _selectedSourceItemID = State(initialValue: nil)
        case .edit(let task):
            _title = State(initialValue: task.title)
            _ownerName = State(initialValue: task.ownerName ?? "")
            _priority = State(initialValue: TaskPriority(rawValue: task.priorityRaw ?? "medium") ?? .medium)
            _dueAt = State(initialValue: task.dueAt)
            _hasDueDate = State(initialValue: task.dueAt != nil)
            _notes = State(initialValue: "")
            _selectedSourceItemID = State(initialValue: task.sourceItemID)
        }
    }

    private var projectItems: [KnowledgeItem] {
        guard case .create(let projectID) = mode, let pid = projectID else { return [] }
        return allItems.filter { $0.projectID == pid }
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
                            Text(priorityShortLabel(p)).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: Binding(
                            get: { dueAt ?? Date() },
                            set: { dueAt = $0 }
                        ), displayedComponents: .date)
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                if !projectItems.isEmpty {
                    Section("Source Item") {
                        Picker("Linked from", selection: $selectedSourceItemID) {
                            Text("None").tag(UUID?.none)
                            ForEach(projectItems) { item in
                                Text(item.title).tag(item.id as UUID?)
                            }
                        }
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

        let finalNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = selectedSourceItemID

        let service = services.derived

        switch mode {
        case .create(let projectID):
            guard let pid = projectID else { return }
            try? service.createTask(
                title: finalTitle,
                projectID: pid,
                sourceItemID: sourceID,
                priority: priority,
                ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerName.trimmingCharacters(in: .whitespacesAndNewlines),
                dueAt: hasDueDate ? dueAt : nil,
                bodyJSON: finalNotes.isEmpty ? nil : finalNotes
            )

        case .edit(let task):
            try? service.updateTask(
                task,
                title: finalTitle,
                ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerName,
                priority: priority,
                dueAt: hasDueDate ? dueAt : nil
            )
            task.bodyJSON = finalNotes.isEmpty ? nil : finalNotes
            task.sourceItemID = sourceID
            try? modelContext.save()
        }

        dismiss()
    }

    private func priorityShortLabel(_ p: TaskPriority) -> String {
        switch p {
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        case .critical: "Crit"
        }
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
