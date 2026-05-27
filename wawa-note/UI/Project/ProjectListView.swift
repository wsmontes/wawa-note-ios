import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(projects) { project in
                    NavigationLink {
                        ProjectDetailView(project: project)
                    } label: {
                        projectRow(project)
                    }
                    .buttonStyle(.plain)

                    if project.id != projects.last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(16)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 12) {
            Image(systemName: project.iconName ?? "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let summary = project.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(project.status.rawValue.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(project.status).opacity(0.15))
                .clipShape(Capsule())
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
