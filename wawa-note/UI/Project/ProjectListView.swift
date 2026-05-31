import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @State private var showNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewProject = true } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
            .alert("New Project", isPresented: $showNewProject) {
                TextField("Project name", text: $newProjectName)
                Button("Create") { createProject() }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 80)
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.title3)
                .fontWeight(.medium)
            Text("Promote a meeting to a project to start organizing your knowledge into actionable plans.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Create Project") {
                showNewProject = true
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    private var listView: some View {
        List {
            ForEach(projects) { project in
                NavigationLink {
                    ProjectDetailView(project: project)
                } label: {
                    projectRow(project)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        // Quick capture into project
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }.tint(.red)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        project.status = project.status == .archived ? .active : .archived
                        try? modelContext.save()
                    } label: {
                        Label(project.status == .archived ? "Restore" : "Archive", systemImage: project.status == .archived ? "arrow.uturn.backward" : "archivebox")
                    }.tint(.orange)
                    Button(role: .destructive) {
                        let svc = ProjectService(context: modelContext)
                        try? svc.deleteProject(project)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func projectRow(_ project: Project) -> some View {
        let itemCount = allItems.filter { $0.projectID == project.id }.count
        let taskCount = allTasks.filter { $0.projectID == project.id }.count
        let openTasks = allTasks.filter { $0.projectID == project.id && $0.statusRaw == "todo" }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: project.iconName ?? "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Color.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.subheadline).fontWeight(.medium)
                    Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text(project.status.rawValue.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor(project.status).opacity(0.15))
                    .clipShape(Capsule())
            }

            if let summary = project.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack(spacing: 12) {
                Label("\(itemCount)", systemImage: "doc")
                    .font(.caption2).foregroundStyle(.secondary)
                Label("\(taskCount)", systemImage: "checklist")
                    .font(.caption2).foregroundStyle(.secondary)
                if openTasks > 0 {
                    Label("\(openTasks) open", systemImage: "circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .active: return .blue
        case .archived: return .gray
        case .completed: return .green
        }
    }

    private func createProject() {
        guard !newProjectName.isEmpty else { return }
        let svc = ProjectService(context: modelContext)
        _ = try? svc.create(name: newProjectName)
        newProjectName = ""
    }
}
