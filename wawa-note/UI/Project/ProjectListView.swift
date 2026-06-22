import SwiftUI
import SwiftData

enum ProjectSortOrder: CaseIterable { case recent, name, created }

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var recordingCoordinator: RecordingCoordinator
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @State private var showNewProject = false
    @State private var searchText = ""
    @State private var listRefreshID = UUID()
    @State private var sortOrder: ProjectSortOrder = .recent
    @State private var onboardingSuggestion: ProjectSuggestion?
    @State private var showPromoteSheet = false
    @State private var itemCounts: [UUID: Int] = [:]
    @State private var taskCounts: [UUID: Int] = [:]
    @State private var openTaskCounts: [UUID: Int] = [:]
    @State private var showDeleteConfirmation = false
    @State private var projectToDelete: Project?

    private var sortedProjects: [Project] {
        let nonConfig = projects.filter { !ConfigProjectService.isConfigProject($0) }
        let filtered = searchText.isEmpty ? nonConfig : nonConfig.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.summary ?? "").localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case .recent: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .name: return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        Group {
            if projects.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Projects")
        .searchable(text: $searchText, prompt: "Search projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewProject = true } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(ProjectSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            Label(order.label, systemImage: sortOrder == order ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showNewProject) {
            CreateProjectSheet()
        }
        .onAppear {
            computeCounts()
            listRefreshID = UUID()
            // Check for orphan items that could become a project
            let detector = InboxCriticalMassDetector(context: modelContext)
            if detector.checkAndSuggest() != nil {
                let pendingRaw = SuggestionStatus.pending.rawValue
                let creationRaw = SuggestionType.projectCreation.rawValue
                let descriptor = FetchDescriptor<ProjectSuggestion>(
                    predicate: #Predicate {
                        $0.suggestionTypeRaw == creationRaw && $0.statusRaw == pendingRaw
                    }
                )
                let all = (try? modelContext.fetch(descriptor)) ?? []
                onboardingSuggestion = all.first
            }
        }
        .onChange(of: allItems.count) { _ in computeCounts() }
        .onChange(of: allTasks.count) { _ in computeCounts() }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Welcome to Wawa Note")
                .font(.title2).fontWeight(.semibold)
            Text("Capture meetings, notes, or documents.\nThey become living projects with tasks, decisions, and connections.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 12) {
                Button("Create a project") { showNewProject = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: 280)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var listView: some View {
        List {
            // Onboarding suggestion card
            if let suggestion = onboardingSuggestion {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                            Text(suggestion.title).font(.subheadline).fontWeight(.semibold)
                        }
                        Text(suggestion.body).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Dismiss") {
                                try? ProjectSuggestionService(context: modelContext).dismiss(suggestion)
                                onboardingSuggestion = nil
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Button("Create Project") { showNewProject = true }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            ForEach(sortedProjects) { project in
                NavigationLink(value: project.id) {
                    projectRow(project)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        recordingCoordinator.startRecording(projectID: project.id)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }.tint(.red)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        let newStatus: ProjectStatus = project.status == .archived ? .active : .archived
                        _ = try? ProjectService(context: modelContext).update(
                            id: project.id,
                            fields: ProjectUpdateFields(status: newStatus),
                            origin: .user
                        )
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
        .id(listRefreshID)
        .refreshable { listRefreshID = UUID() }
        .alert("Delete Project", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { projectToDelete = nil }
            Button("Delete", role: .destructive) {
                if let p = projectToDelete {
                    let svc = ProjectService(context: modelContext)
                    try? svc.deleteProject(p)
                    projectToDelete = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(projectToDelete?.name ?? "")\"? This cannot be undone.")
        }
        .navigationDestination(for: UUID.self) { projectID in
            ProjectDetailLink(projectID: projectID)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let itemCount = itemCounts[project.id] ?? 0
        let taskCount = taskCounts[project.id] ?? 0
        let openTasks = openTaskCounts[project.id] ?? 0

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: project.iconName ?? "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Color(hex: project.colorHex ?? ProjectPalette.allHexes.first!))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: project.colorHex ?? ProjectPalette.allHexes.first!).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))

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

            HStack(spacing: AppSpacing.md) {
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
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: Counts

    private func computeCounts() {
        itemCounts = Dictionary(grouping: allItems, by: { $0.projectID ?? UUID() }).mapValues { $0.count }
        let taskGroups = Dictionary(grouping: allTasks, by: { $0.projectID ?? UUID() })
        taskCounts = taskGroups.mapValues { $0.count }
        openTaskCounts = taskGroups.mapValues { $0.filter { $0.statusRaw == "todo" }.count }
    }

    private func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .active: return .blue
        case .archived: return .gray
        case .completed: return .green
        }
    }

    private func dismissSheet() {
        showNewProject = false
    }
}

extension ProjectSortOrder {
    var label: String {
        switch self {
        case .recent: return "Recently Updated"
        case .name: return "Name A-Z"
        case .created: return "Created Date"
        }
    }
}
