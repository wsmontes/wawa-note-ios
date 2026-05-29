import SwiftUI

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
    @State private var showFolderAlert = false
    @State private var showIdeaEditor = false
    @State private var showQuestionEditor = false
    @State private var newFolderName = ""

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
                        title: "Folder",
                        icon: "folder.badge.plus",
                        color: .blue,
                        action: { showFolderAlert = true }
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
            .alert("New Folder", isPresented: $showFolderAlert) {
                TextField("Name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderName = "" }
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

    private func createFolder() {
        guard !newFolderName.isEmpty else { return }
        let folder = Folder(name: newFolderName, parentFolderID: folderID)
        modelContext.insert(folder)
        try? modelContext.save()
        newFolderName = ""
        dismiss()
    }
}
