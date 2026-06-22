import SwiftUI
// Related JIRA: KAN-10, KAN-137, KAN-138, KAN-139


struct CreationSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let folderID: UUID?
    let projectID: UUID?

    init(folderID: UUID? = nil, projectID: UUID? = nil) {
        self.folderID = folderID
        self.projectID = projectID
    }

    @State private var showNoteEditor = false
    @State private var showJournalEditor = false
    @State private var showTaskEditor = false
    @State private var showIdeaEditor = false
    @State private var showQuestionEditor = false
    @State private var showBookmarkSheet = false
    @State private var bookmarkURL = ""
    @State private var bookmarkTitle = ""
    @State private var showProjectAlert = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Create New")
                    .font(.headline)
                    .padding(.top, 24)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    creationButton(
                        title: "Note",
                        icon: "note.text",
                        color: .orange,
                        action: { showNoteEditor = true }
                    )
                    creationButton(
                        title: "Journal",
                        icon: "book",
                        color: .purple,
                        action: { showJournalEditor = true }
                    )
                    creationButton(
                        title: "Idea",
                        icon: "lightbulb",
                        color: .yellow,
                        action: { showIdeaEditor = true }
                    )
                    creationButton(
                        title: "Question",
                        icon: "questionmark.bubble",
                        color: .mint,
                        action: { showQuestionEditor = true }
                    )
                    creationButton(
                        title: "Task",
                        icon: "checklist",
                        color: .green,
                        action: { showTaskEditor = true }
                    )
                    creationButton(
                        title: "Project",
                        icon: "square.grid.2x2",
                        color: .indigo,
                        action: { createProject() }
                    )
                    creationButton(
                        title: "Bookmark",
                        icon: "bookmark",
                        color: .green,
                        action: { showBookmarkSheet = true }
                    )
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showNoteEditor) {
                NoteEditorView(mode: .create(type: .note, folderID: folderID, initialTag: nil))
            }
            .sheet(isPresented: $showJournalEditor) {
                JournalEditorView(mode: .create(folderID: folderID))
            }
            .sheet(isPresented: $showTaskEditor) {
                TaskEditorView(mode: .create(projectID: projectID))
            }
            .sheet(isPresented: $showIdeaEditor) {
                NoteEditorView(mode: .create(type: .note, folderID: folderID, initialTag: "idea"))
            }
            .sheet(isPresented: $showQuestionEditor) {
                NoteEditorView(mode: .create(type: .note, folderID: folderID, initialTag: "question"))
            }
            .alert("New Bookmark", isPresented: $showBookmarkSheet) {
                TextField("URL", text: $bookmarkURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Title (optional)", text: $bookmarkTitle)
                Button("Save") { createBookmark() }
                Button("Cancel", role: .cancel) { bookmarkURL = ""; bookmarkTitle = "" }
            } message: {
                Text("Enter the URL to save as a bookmark.")
            }
            .alert("New Project", isPresented: $showProjectAlert) {
                TextField("Name", text: $newProjectName)
                Button("Create") { createProjectConfirmed() }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            }
            .onChange(of: showNoteEditor) { _, _ in if !showNoteEditor { dismiss() } }
            .onChange(of: showJournalEditor) { _, _ in if !showJournalEditor { dismiss() } }
            .onChange(of: showTaskEditor) { _, _ in if !showTaskEditor { dismiss() } }
            .onChange(of: showIdeaEditor) { _, _ in if !showIdeaEditor { dismiss() } }
            .onChange(of: showQuestionEditor) { _, _ in if !showQuestionEditor { dismiss() } }
        }
    }

    private func creationButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func createProject() {
        newProjectName = ""
        showProjectAlert = true
    }

    private func createProjectConfirmed() {
        guard !newProjectName.isEmpty else { return }
        let project = Project(name: newProjectName)
        project.nameIsAutoGenerated = false
        var prov = project.provenance
        prov.mark(field: "name", origin: .user)
        project.fieldProvenanceJSON = prov.encode()
        modelContext.insert(project)
        try? modelContext.save()
        newProjectName = ""
        dismiss()
    }

    private func createBookmark() {
        let url = bookmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let title = bookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let svc = KnowledgeItemService(context: modelContext)
        let item = try? svc.createItem(
            type: .webBookmark,
            title: title.isEmpty ? url : title,
            bodyText: nil,
            tags: ["bookmark"],
            inboxDate: Date()
        )
        if let item {
            item.importSourceURL = url
            try? modelContext.save()
        }
        bookmarkURL = ""
        bookmarkTitle = ""
        dismiss()
    }
}
