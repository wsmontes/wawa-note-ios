import SwiftUI
import SwiftData
import Combine

// MARK: - ViewModel

@MainActor
final class ProjectDetailViewModel: ObservableObject {
    let project: Project

    @Published var tasks: [TaskItem] = []
    @Published var projectItems: [KnowledgeItem] = []
    @Published var selectedTab = 0
    @Published var remindersExportMessage: String?
    @Published var remindersExportNeedsSettings = false
    @Published var customInstructions: String = ""
    @Published var showInstructionsEditor = false
    @Published var isReprocessing = false

    private var modelContext: ModelContext?
    private var cancellables = Set<AnyCancellable>()

    init(project: Project) {
        self.project = project
    }

    func configure(modelContext: ModelContext, ingestionState: ProjectIngestionState) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        observeIngestionState(ingestionState)
        loadData()
    }

    // MARK: Data

    func loadData() {
        guard let ctx = modelContext else { return }
        let taskSvc = TaskService(context: ctx)
        tasks = (try? taskSvc.tasks(for: project.id)) ?? []

        let projSvc = ProjectService(context: ctx)
        projectItems = (try? projSvc.items(in: project.id)) ?? []
        customInstructions = project.customInstructions ?? ""
    }

    func saveInstructions() {
        guard let ctx = modelContext else { return }
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        project.customInstructions = trimmed.isEmpty ? nil : trimmed
        try? ctx.save()
    }

    // MARK: Actions

    func removeFromInbox(_ item: KnowledgeItem) {
        guard let ctx = modelContext else { return }
        let svc = KnowledgeItemService(context: ctx)
        try? svc.removeFromInbox(item)
        loadData()
    }

    func removeItem(_ item: KnowledgeItem) {
        guard let ctx = modelContext else { return }
        try? ProjectService(context: ctx).removeItem(item.id)
        loadData()
    }

    func moveToTrash(_ item: KnowledgeItem) {
        guard let ctx = modelContext else { return }
        let trash = TrashService(context: ctx)
        try? trash.moveToTrash(item)
        loadData()
    }

    // MARK: Export

    func exportMarkdown() {
        guard let ctx = modelContext else { return }
        let exporter = ProjectExportService()
        let svc = GraphEdgeService(context: ctx)
        let allEdges = (try? svc.neighborhood(of: project.id, radius: 2)) ?? []

        let markdown = exporter.exportMarkdown(project: project, items: projectItems, tasks: tasks, edges: allEdges)
        let activityVC = UIActivityViewController(activityItems: [markdown], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }

    func exportTasksToReminders() async {
        let service = TaskRemindersService()
        let result = await service.exportTasks(tasks)
        remindersExportMessage = result.message
        remindersExportNeedsSettings = result.needsSettingsButton
    }

    var doneTaskCount: Int {
        tasks.filter { $0.status == .done }.count
    }

    func reprocessProject(using pipeline: ContentPipelineService) async {
        guard let ctx = modelContext else { return }
        isReprocessing = true
        defer { isReprocessing = false }

        let items = projectItems
        for item in items {
            item.analysisProviderId = nil
            try? ctx.save()

            let fileStore = FileArtifactStore()
            let dir = fileStore.itemDirectoryURL(for: item.id)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.json"))
        }

        for item in items {
            await pipeline.process(item.id, using: ctx)
        }

        loadData()
    }

    // MARK: Ingestion observation

    private func observeIngestionState(_ state: ProjectIngestionState) {
        state.$activeProjectIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeIDs in
                guard let self, !activeIDs.contains(self.project.id) else { return }
                self.loadData()
            }
            .store(in: &cancellables)

        // Reload when ingestion completes or fails for this project
        state.$ingestionVersion
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.loadData() }
            .store(in: &cancellables)
    }
}

// MARK: - View

struct ProjectDetailView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var ingestionState: ProjectIngestionState
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @StateObject private var viewModel: ProjectDetailViewModel

    init(project: Project) {
        self.project = project
        _viewModel = StateObject(wrappedValue: ProjectDetailViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Picker("View", selection: $viewModel.selectedTab) {
                Text("Tasks").tag(0)
                Text("Items").tag(1)
                Text("Graph").tag(2)
                Text("Timeline").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch viewModel.selectedTab {
            case 0:
                ProjectTaskBoardView(tasks: viewModel.tasks, projectID: project.id)
            case 1:
                projectItemsList
            case 2:
                ProjectGraphView(projectID: project.id)
            case 3:
                ProjectTimelineView(projectID: project.id)
            default:
                EmptyView()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if viewModel.projectItems.count > 0 {
                        Button {
                            Task { await viewModel.reprocessProject(using: contentPipeline) }
                        } label: {
                            Label("Re-process All", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.isReprocessing)
                    }

                    Menu {
                        Button { viewModel.selectedTab = 0 } label: { Label("Tasks", systemImage: "checklist") }
                        Button { viewModel.selectedTab = 1 } label: { Label("Items", systemImage: "doc.text") }
                        Button { viewModel.selectedTab = 2 } label: { Label("Graph", systemImage: "circle.hexagonpath") }
                        Button { viewModel.selectedTab = 3 } label: { Label("Timeline", systemImage: "clock") }
                    } label: {
                        Label("View", systemImage: "ellipsis.circle")
                    }

                    Menu {
                        Button {
                            viewModel.exportMarkdown()
                        } label: {
                            Label("Export Markdown", systemImage: "doc.richtext")
                        }
                        Button {
                            Task { await viewModel.exportTasksToReminders() }
                        } label: {
                            Label("Send Tasks to Reminders", systemImage: "checklist")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            viewModel.configure(modelContext: modelContext, ingestionState: ingestionState)
        }
        .alert("Reminders", isPresented: Binding(
            get: { viewModel.remindersExportMessage != nil },
            set: { if !$0 { viewModel.remindersExportMessage = nil; viewModel.remindersExportNeedsSettings = false } }
        )) {
            if viewModel.remindersExportNeedsSettings {
                Button("Open Settings") {
                    viewModel.remindersExportMessage = nil
                    viewModel.remindersExportNeedsSettings = false
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Button("OK") {
                viewModel.remindersExportMessage = nil
                viewModel.remindersExportNeedsSettings = false
            }
        } message: {
            Text(viewModel.remindersExportMessage ?? "")
        }
        .sheet(isPresented: $viewModel.showInstructionsEditor) {
            instructionsEditorSheet
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: project.iconName ?? "folder.fill")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let summary = project.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(project.status.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(project.status == .active ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 24) {
                statLabel("\(viewModel.tasks.count)", "Tasks")
                statLabel("\(viewModel.doneTaskCount)", "Done")
                statLabel("\(viewModel.projectItems.count)", "Items")
            }

            if ingestionState.activeProjectIDs.contains(project.id) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Analyzing new item...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let errorMsg = ingestionState.ingestionErrors[project.id] {
                Button {
                    ingestionState.ingestionErrors[project.id] = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Custom instructions
            Button {
                viewModel.customInstructions = project.customInstructions ?? ""
                viewModel.showInstructionsEditor = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    if let instructions = project.customInstructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Add project instructions to guide AI analysis...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Color(.systemBackground))
    }

    private var instructionsEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Tell the AI what matters in this project. It will use these instructions when analyzing new items.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                TextEditor(text: $viewModel.customInstructions)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }
            .navigationTitle("Project Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showInstructionsEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveInstructions()
                        viewModel.showInstructionsEditor = false
                        viewModel.loadData()
                    }
                }
            }
        }
    }

    private func statLabel(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Items list

    private var projectItemsList: some View {
        Group {
            if viewModel.projectItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title).foregroundStyle(.secondary)
                    Text("No items in this project")
                        .font(.headline)
                    Text("Promote a meeting or add items from the library.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            } else {
                List {
                    ForEach(viewModel.projectItems) { item in
                        NavigationLink {
                            KnowledgeDetailView(item: item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.type.icon)
                                    .font(.title3).foregroundStyle(item.type.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "Untitled" : item.title)
                                        .font(.subheadline).foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if item.inboxDate != nil {
                                            Text("·").font(.caption).foregroundStyle(.secondary)
                                            Text("Unprocessed").font(.caption2).foregroundStyle(.orange)
                                        }
                                        if item.analysisProviderId != nil {
                                            Text("·").font(.caption).foregroundStyle(.secondary)
                                            Text("Analyzed").font(.caption2).foregroundStyle(.indigo)
                                        }
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if item.inboxDate != nil {
                                Button {
                                    viewModel.removeFromInbox(item)
                                } label: {
                                    Label("Mark Reviewed", systemImage: "checkmark.circle")
                                }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                viewModel.removeItem(item)
                            } label: {
                                Label("Remove", systemImage: "folder.badge.minus")
                            }.tint(.orange)
                            Button(role: .destructive) {
                                viewModel.moveToTrash(item)
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }
}
