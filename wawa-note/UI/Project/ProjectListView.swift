import SwiftData
import SwiftUI
import WawaNoteCore

// Related JIRA: KAN-152, KAN-533

enum ProjectSortOrder: CaseIterable { case recent, name, created }

struct ProjectListView: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject var recordingCoordinator: RecordingCoordinator
  @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
  @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
  @State private var showNewProject = false
  @State private var newProjectName = ""
  @State private var searchText = ""
  @State private var createError: String?
  @State private var listRefreshID = UUID()
  @FocusState private var isNameFieldFocused: Bool
  @State private var sortOrder: ProjectSortOrder = .recent
  @State private var itemCounts: [UUID: Int] = [:]
  @State private var showDeleteConfirmation = false
  @State private var projectToDelete: Project?

  private var userProjects: [Project] {
    ProjectService.visibleProjects(in: projects)
  }

  private var sortedProjects: [Project] {
    let filtered =
      searchText.isEmpty
      ? userProjects
      : userProjects.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
          || ($0.summary ?? "").localizedCaseInsensitiveContains(searchText)
      }
    switch sortOrder {
    case .recent: return filtered.sorted { $0.updatedAt > $1.updatedAt }
    case .name: return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
    }
  }

  var body: some View {
    Group {
      if userProjects.isEmpty {
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
        Button {
          showNewProject = true
        } label: {
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
      newProjectSheet
    }
    .onAppear {
      computeCounts()
      // Rebuild list to force @Query refresh on tab switch
      listRefreshID = UUID()
    }
    .onChange(of: allItems.count) { computeCounts() }
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
      Text("Capture audio, scan documents, or create notes — then group related items into projects.")
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
      ForEach(Array(sortedProjects.enumerated()), id: \.element.id) { index, project in
        NavigationLink(value: project.id) {
          projectRow(project)
        }
        .staggeredAppear(index: index)
        .swipeActions(edge: .leading) {
          Button {
            recordingCoordinator.startRecording(projectID: project.id)
          } label: {
            Label("Record", systemImage: "record.circle")
          }.tint(.red)
        }
        .swipeActions(edge: .trailing) {
          Button {
            project.status = project.status == .archived ? .active : .archived
            modelContext.safeSave(context: "toggle-project-archive", itemId: project.id)
          } label: {
            Label(
              project.status == .archived ? "Restore" : "Archive",
              systemImage: project.status == .archived ? "arrow.uturn.backward" : "archivebox")
          }.tint(.orange)
          Button(role: .destructive) {
            projectToDelete = project
            showDeleteConfirmation = true
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
      Text(
        "Are you sure you want to delete \"\(projectToDelete?.name ?? "")\"? This cannot be undone."
      )
    }
    .navigationDestination(for: UUID.self) { projectID in
      ProjectDetailLink(projectID: projectID)
    }
  }

  private func projectRow(_ project: Project) -> some View {
    let itemCount = itemCounts[project.id] ?? 0

    return HStack(spacing: AppSpacing.md) {
      Image(systemName: project.iconName ?? "folder.fill")
        .font(.title3)
        .foregroundStyle(Color(hex: project.colorHex ?? ProjectPalette.allHexes.first!))
        .frame(width: 38, height: 38)
        .background(Color(hex: project.colorHex ?? ProjectPalette.allHexes.first!).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))

      VStack(alignment: .leading, spacing: 3) {
        Text(project.name)
          .font(.subheadline).fontWeight(.medium)
        Text(
          "\(itemCount) \(itemCount == 1 ? "item" : "items") · Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      if project.status == .archived {
        Text("Archived")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.md)
  }

  // MARK: Counts

  private func computeCounts() {
    var counts: [UUID: Int] = [:]
    for item in allItems {
      if let projectID = item.projectID {
        counts[projectID, default: 0] += 1
      }
    }
    itemCounts = counts
  }

  private var newProjectSheet: some View {
    NavigationStack {
      Form {
        Section("Project Name") {
          TextField("e.g., Q3 Product Launch", text: $newProjectName)
            .focused($isNameFieldFocused)
        }

        if let error = createError {
          Section {
            HStack {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
              Text(error).font(.caption).foregroundStyle(.red)
            }
          }
        }
      }
      .navigationTitle("New Project")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismissSheet() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Create") { createProject() }
            .fontWeight(.semibold)
            .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .onAppear {
        isNameFieldFocused = true
      }
    }
  }

  private func dismissSheet() {
    newProjectName = ""
    createError = nil
    showNewProject = false
  }

  private func createProject() {
    let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    createError = nil
    let svc = ProjectService(context: modelContext)
    do {
      let project = try svc.create(name: trimmed)
      project.nameIsAutoGenerated = false
      var prov = project.provenance
      prov.mark(field: "name", origin: .user)
      project.fieldProvenanceJSON = prov.encode()
      try modelContext.save()
      newProjectName = ""
      createError = nil
      showNewProject = false
    } catch {
      createError = error.localizedDescription
      AppLog.general.error("ProjectListView: create project failed: \(error)")
    }
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
