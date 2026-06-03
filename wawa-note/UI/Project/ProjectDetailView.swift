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

    private(set) var modelContext: ModelContext?
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

    func reprocessProject(using pipeline: ContentPipelineService, queue: ProcessingQueueService) async {
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
            queue.enqueue(itemID: item.id, projectID: project.id, trigger: .batchReprocess)
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
    @EnvironmentObject private var processingQueue: ProcessingQueueService
    @EnvironmentObject private var chatState: ChatOverlayState
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @StateObject private var viewModel: ProjectDetailViewModel
    @State private var selectedDynamicTab = 0
    @State private var overviewExpanded = false

    private var framework: ProjectFramework {
        FrameworkService.shared.resolve(for: project)
    }

    private func tabChip(_ title: String, tag: Int) -> some View {
        Button {
            selectedDynamicTab = tag
        } label: {
            Text(title)
                .font(.caption2).fontWeight(selectedDynamicTab == tag ? .semibold : .regular)
                .foregroundStyle(selectedDynamicTab == tag ? .white : .secondary)
                .padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                .background(selectedDynamicTab == tag ? Color.accentColor : Color(.tertiarySystemFill))
                .clipShape(Capsule())
        }
    }

    private var collapsedOverview: some View {
        HStack(spacing: AppSpacing.sm) {
            Circle().fill(healthColor).frame(width: 8, height: 8)
            if let score = project.healthScore {
                Text("\(Int(score))").font(.caption).fontWeight(.semibold).foregroundStyle(healthColor)
            }
            Text("·").foregroundStyle(.tertiary)
            Text("\(viewModel.tasks.filter { $0.status == .todo || $0.status == .inProgress }.count) open").font(.caption).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text("\(viewModel.projectItems.count) items").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { overviewExpanded = true } }
    }

    private var healthColor: Color {
        switch project.healthStatus { case "healthy": .mint; case "stale": .orange; case "atRisk": .red; case "dormant": .gray; default: .blue }
    }

    init(project: Project) {
        self.project = project
        _viewModel = StateObject(wrappedValue: ProjectDetailViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            // Overview: expanded by default, collapses to strip when tab selected
            if overviewExpanded {
                ProjectOverviewCards(project: project, items: viewModel.projectItems,
                                     tasks: viewModel.tasks, viewModel: viewModel)
            } else {
                collapsedOverview
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    ForEach(Array(framework.views.enumerated()), id: \.offset) { idx, view in
                        tabChip(view.title, tag: idx)
                    }
                    tabChip("Decisions", tag: framework.views.count)
                    tabChip("Risks", tag: framework.views.count + 1)
                    tabChip("People", tag: framework.views.count + 2)
                    tabChip("Entities", tag: framework.views.count + 3)
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.vertical, AppSpacing.xs)
            .onChange(of: selectedDynamicTab) { _ in
                withAnimation(.easeInOut(duration: 0.25)) { overviewExpanded = false }
            }

            if selectedDynamicTab < framework.views.count {
                let viewDef = framework.views[selectedDynamicTab]
                switch viewDef.type {
                case .kanban:
                    ProjectTaskBoardView(tasks: viewModel.tasks, projectID: project.id)
                        .frame(maxHeight: .infinity)
                case .list:
                    projectItemsList
                        .frame(maxHeight: .infinity)
                case .graph:
                    ProjectGraphView(projectID: project.id)
                        .frame(maxHeight: .infinity)
                case .timeline:
                    ProjectTimelineView(projectID: project.id)
                        .frame(maxHeight: .infinity)
                case .cards, .table, .markdown, .chips:
                    dynamicFrameworkView(viewDef)
                }
            } else {
                let extraIdx = selectedDynamicTab - framework.views.count
                switch extraIdx {
                case 0:
                    ProjectDecisionsView(projectID: project.id).frame(maxHeight: .infinity)
                case 1:
                    ProjectRiskRegisterView(projectID: project.id).frame(maxHeight: .infinity)
                case 2:
                    ProjectPeopleView(projectID: project.id).frame(maxHeight: .infinity)
                case 3:
                    ProjectEntitiesView(projectID: project.id).frame(maxHeight: .infinity)
                default:
                    EmptyView()
                }
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
                            Task { await viewModel.reprocessProject(using: contentPipeline, queue: processingQueue) }
                        } label: {
                            Label("Re-process All", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.isReprocessing)
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
            chatState.context = .project(project.id)
            chatViewModel.pregenerateGreeting(for: .project(project.id))
            viewModel.configure(modelContext: modelContext, ingestionState: ingestionState)
        }
        .onChange(of: ingestionState.ingestionVersion) { _ in
            chatViewModel.invalidateGreeting(for: .project(project.id))
            chatViewModel.pregenerateGreeting(for: .project(project.id))
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

    @ViewBuilder
    private func dynamicFrameworkView(_ viewDef: ViewDefinition) -> some View {
        switch viewDef.type {
        case .cards:
            let items = viewModel.projectItems
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: item.type.icon).font(.title2).foregroundStyle(item.type.color)
                            Text(item.title).font(.subheadline).fontWeight(.medium).lineLimit(2)
                            if let body = item.bodyText {
                                Text(body.prefix(100)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(16)
            }
        case .table:
            let items = viewModel.projectItems
            List(items) { item in
                HStack {
                    Image(systemName: item.type.icon).foregroundStyle(item.type.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline)
                        if let date = item.scheduledDate { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }.listStyle(.plain)
        case .markdown:
            ScrollView {
                if let summary = project.summary, !summary.isEmpty {
                    Text(summary).font(.body).padding(16)
                } else {
                    Text("No content yet").font(.subheadline).foregroundStyle(.secondary).padding(16)
                }
            }
        case .chips:
            let tags = Array(Set(viewModel.projectItems.flatMap(\.tags)))
            if tags.isEmpty { Text("No tags").font(.subheadline).foregroundStyle(.secondary).padding(16) }
            else {
                ScrollView {
                    ChipFlowLayout(spacing: 8) {
                        ForEach(Array(tags), id: \.self) { tag in
                            Text(tag).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary).clipShape(Capsule())
                        }
                    }.padding(16)
                }
            }
        default:
            let items = viewModel.projectItems
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if let body = item.bodyText { Text(body.prefix(200)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(16)
            }
        }
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
                    Text("Promote an item or add from the library from the library.")
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

// MARK: - Project Overview Dashboard

struct ProjectOverviewCards: View {
    let project: Project
    let items: [KnowledgeItem]
    let tasks: [TaskItem]
    @ObservedObject var viewModel: ProjectDetailViewModel

    @State private var health: ProjectHealthEngine.HealthResult?
    @State private var healthTask: Task<Void, Never>?
    @State private var cachedRisks: [(String, String, Double)] = []
    @State private var cachedSuggestions: [AgentSuggestion] = []

    private func refreshHealth() {
        guard let ctx = viewModel.modelContext else { return }
        healthTask?.cancel()
        healthTask = Task { @MainActor in
            health = ProjectHealthEngine.compute(for: project.id, context: ctx)
            cachedRisks = computeRisks()
            cachedSuggestions = fetchPendingSuggestions(ctx)
        }
    }

    private func computeRisks() -> [(String, String, Double)] {
        let store = FileArtifactStore()
        return items.compactMap { item -> [(String, String, Double)]? in
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { return nil }
            return analysis.risks.filter { ($0.confidence ?? 0) > 0.7 }.map { ($0.risk, item.title, $0.confidence ?? 0) }
        }.flatMap { $0 }
    }

    private var overdueTasks: [TaskItem] {
        tasks.filter { t in
            (t.status == .todo || t.status == .inProgress) && t.dueAt.map { $0 < Date() } ?? false
        }
    }

    private var openRisks: [(String, String, Double)] { cachedRisks }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            if let h = health {
                pulseStrip(health: h)
            }
            if !overdueTasks.isEmpty || !openRisks.isEmpty {
                attentionSection
            }
            synthesisSection
            suggestionsSection
            activityFeed
        }
        .padding(.horizontal, AppSpacing.md)
        .onAppear { refreshHealth() }
        .onDisappear { healthTask?.cancel() }
        .onChange(of: viewModel.projectItems.count) { _ in refreshHealth() }
    }

    private func pulseStrip(health: ProjectHealthEngine.HealthResult) -> some View {
        HStack(spacing: AppSpacing.sm) {
            HealthRingView(score: health.score, status: health.status)
            Spacer()
            MetricTile(icon: "checkmark.seal", value: String(format: "%.0f", health.decisionVelocity * 4),
                       label: "Decisions", subtitle: "this month")
            MetricTile(icon: "exclamationmark.shield", value: "\(Int(health.riskExposure * 100))%",
                       label: "Exposure", subtitle: health.anomalies.isEmpty ? "Clear" : "Watch")
            MetricTile(icon: "circle.dotted", value: "\(items.count)",
                       label: "Items", subtitle: health.evidenceFreshnessDays < 7 ? "Active" : "\(Int(health.evidenceFreshnessDays))d old")
        }
        .padding(AppSpacing.md)
        .projectCard()
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text("Needs attention").font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                Spacer()
                Text("\(overdueTasks.count + openRisks.count) items").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(overdueTasks.prefix(3)) { task in
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.red)
                    Text(task.title).font(.caption).lineLimit(1)
                    Spacer()
                    if let due = task.dueAt {
                        Text(due.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(AppSpacing.sm).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            ForEach(Array(openRisks.enumerated()).prefix(2), id: \.offset) { _, riskData in
                let (risk, _, conf) = riskData
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    Text(risk).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int(conf * 100))%").font(.caption2).foregroundStyle(.orange)
                }
                .padding(AppSpacing.sm).background(Color.orange.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }

    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "text.alignleft").font(.caption).foregroundStyle(.blue)
                Text("Synthesis").font(.caption).fontWeight(.semibold)
                AIGeneratedBadge(confidence: nil, source: "Agent")
                Spacer()
                if let updated = project.synthesisUpdatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .numeric)))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(project.synthesis ?? project.summary ?? "Add items to this project to generate insights.")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
            if let sourceID = project.synthesisSourceItemID {
                let snippet = project.summary.map { String($0.prefix(120)) } ?? "No summary"
                EvidenceCardView(itemTitle: "Generated from item", itemID: sourceID, snippet: snippet, segmentID: nil, confidence: nil, edgeType: nil)
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }

    private var pendingSuggestions: [AgentSuggestion] { cachedSuggestions }

    private func fetchPendingSuggestions(_ ctx: ModelContext) -> [AgentSuggestion] {
        let all = (try? ctx.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        return all.filter { $0.projectID == project.id && $0.status == "pending" }
    }

    private var suggestionsSection: some View {
        let pending = pendingSuggestions
        guard !pending.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                    Text("Suggestions to review").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(pending.count) pending").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(pending.prefix(3)) { sug in
                    suggestionCard(sug)
                }
                if pending.count > 3 {
                    Text("+\(pending.count - 3) more suggestions").font(.caption2).foregroundStyle(.blue).padding(.top, 2)
                }
            }
            .padding(AppSpacing.md)
            .projectCard()
        )
    }

    private func suggestionCard(_ sug: AgentSuggestion) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: sug.type == "task" ? "checklist" : sug.type == "edge" ? "arrow.triangle.branch" : "doc.text")
                    .font(.caption2).foregroundStyle(sug.type == "task" ? .teal : .blue)
                Text(sug.title).font(.caption).lineLimit(2)
                Spacer()
                if let conf = sug.confidence { ConfidenceBadge(value: conf) }
            }
            if let body = sug.body, !body.isEmpty {
                Text(body).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let sourceID = sug.sourceItemID {
                EvidenceCardView(itemTitle: "Source", itemID: sourceID, snippet: sug.title, segmentID: nil, confidence: sug.confidence, edgeType: nil)
            }
            HStack(spacing: AppSpacing.sm) {
                Button { approveSuggestion(sug) } label: {
                    Label("Approve", systemImage: "checkmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, AppSpacing.xs)
                        .background(Color.green.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Button { rejectSuggestion(sug) } label: {
                    Label("Reject", systemImage: "xmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, AppSpacing.xs)
                        .background(Color.red.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Spacer()
                AIGeneratedBadge(confidence: sug.confidence, source: "AI suggestion")
            }
        }
        .padding(AppSpacing.sm).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func approveSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        switch sug.type {
        case "task":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let title = dict["title"] as? String ?? sug.title
                let task = TaskItem(projectID: project.id, title: title, ownerName: dict["owner"] as? String)
                ctx.insert(task)
            }
        case "edge":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fromStr = dict["fromID"] as? String, let fromID = UUID(uuidString: fromStr),
               let toStr = dict["toID"] as? String, let toID = UUID(uuidString: toStr),
               let typeStr = dict["type"] as? String, let edgeType = EdgeType(rawValue: typeStr) {
                let edge = GraphEdge(fromID: fromID, toID: toID, edgeType: edgeType, weight: sug.confidence ?? 0.7)
                edge.provenanceItemID = sug.sourceItemID
                if let segJSON = sug.sourceSegmentIDs, let segData = segJSON.data(using: .utf8),
                   let segs = try? JSONDecoder().decode([String].self, from: segData) {
                    edge.provenanceSegmentIDs = segs.isEmpty ? nil : (try? JSONEncoder().encode(segs)).flatMap { String(data: $0, encoding: .utf8) }
                }
                ctx.insert(edge)
            }
        case "annotation":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let key = dict["key"] as? String ?? "ai_suggestion"
                let value = dict["value"] as? String ?? sug.title
                let itemID = sug.sourceItemID ?? project.id
                let annotation = Annotation(source: "agent_suggestion", key: key, value: value, itemID: itemID, confidence: sug.confidence)
                ctx.insert(annotation)
            }
        case "decision":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let title = dict["title"] as? String ?? sug.title
                let task = TaskItem(projectID: project.id, title: "Decision: \(title)", priority: .high, ownerName: dict["owner"] as? String)
                ctx.insert(task)
            }
        case "field_change":
            // Apply a field change proposed by the AI that was gated by user ownership
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let field = dict["field"] as? String,
               let proposedValue = dict["proposedValue"] as? String {
                if field.hasPrefix("task.") {
                    // Find the task by title in the project
                    let taskField = String(field.dropFirst(5))
                    if let task = (try? ctx.fetch(FetchDescriptor<TaskItem>()))?.first(where: {
                        $0.projectID == project.id && sug.title.contains($0.title)
                    }) {
                        applyFieldChange(field: taskField, value: proposedValue, to: task)
                    }
                } else if field == "summary" {
                    let datePrefix = Date().formatted(date: .abbreviated, time: .omitted)
                    project.summary = (project.summary ?? "") + "\n\n[\(datePrefix) — approved]\n\(proposedValue)"
                }
                // Mark the field as user-approved (still user-owned since user approved)
                try? ctx.save()
            }
        default: break
        }
        sug.status = "approved"; sug.resolvedAt = Date()
        try? ctx.save()
    }

    private func applyFieldChange(field: String, value: String, to task: TaskItem) {
        switch field {
        case "status":
            if let st = TaskStatus(rawValue: value) { task.status = st }
        case "priority":
            if let pr = TaskPriority(rawValue: value) { task.priority = pr }
        case "dueAt":
            task.dueAt = ISO8601DateFormatter().date(from: value)
        case "ownerName":
            task.ownerName = value.isEmpty ? nil : value
        default: break
        }
    }

    private func rejectSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        sug.status = "rejected"; sug.resolvedAt = Date()
        try? ctx.save()
        AgentMemoryStore.shared.write(pattern: "rejected_\(sug.type)", strategy: "User rejected: \(sug.title.prefix(60))",
            itemType: sug.type, contentType: nil, language: nil)
    }

    private var activityFeed: some View {
        var entries: [(icon: String, color: Color, text: String, date: Date)] = []
        for item in items.prefix(5) {
            entries.append((item.type == .audio ? "mic.fill" : item.type == .image ? "photo" : "doc.text.fill",
                item.type.color, item.title, item.createdAt))
        }
        for task in tasks.filter({ $0.status == .done }).prefix(3) {
            entries.append(("checkmark.circle.fill", .green, "Completed: \(task.title)", task.updatedAt))
        }
        entries.sort { $0.date > $1.date }
        let recent = Array(entries.prefix(5))

        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath").font(.caption).foregroundStyle(.green)
                Text("Recent activity").font(.caption).fontWeight(.semibold)
            }
            if recent.isEmpty {
                Text("No activity yet").font(.caption2).foregroundStyle(.tertiary).padding(.vertical, AppSpacing.xs)
            } else {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: entry.icon).font(.caption2).foregroundStyle(entry.color)
                        Text(entry.text).font(.caption).lineLimit(1)
                        Spacer()
                        Text(entry.date.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(AppSpacing.xs)
                }
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }
}

// MARK: - Health Ring

struct HealthRingView: View {
    let score: Int
    let status: String

    private var ringColor: Color {
        switch status {
        case "healthy": return .mint
        case "stale": return .orange
        case "atRisk": return .red
        default: return .gray
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.15), lineWidth: 6).frame(width: 52, height: 52)
            Circle().trim(from: 0, to: CGFloat(score) / 100).stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 52, height: 52).rotationEffect(.degrees(-90)).animation(.spring(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 16, weight: .bold, design: .rounded))
            }
        }
    }
}

// MARK: - Metric Tile

struct MetricTile: View {
    let icon: String; let value: String; let label: String; let subtitle: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .rounded)).fontWeight(.bold)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Decision Registry

struct DecisionItem: Identifiable {
    let id = UUID()
    let title: String
    let details: String?
    let sourceItemID: UUID
    let sourceItemTitle: String
    let sourceItemDate: Date
    let confidence: Double
}

struct ProjectDecisionsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var decisions: [DecisionItem] = []
    @State private var isLoading = true
    @State private var minConfidence: Double = 0

    var body: some View {
        Group {
            if isLoading {
                Spacer(); ProgressView("Loading decisions..."); Spacer()
            } else if decisions.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "lightbulb").font(.title).foregroundStyle(.secondary)
                    Text("No decisions yet").font(.headline)
                }
                Spacer()
            } else {
                List {
                    ForEach(decisions.filter { $0.confidence >= minConfidence }) { d in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            HStack(spacing: AppSpacing.sm) {
                                Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.indigo)
                                Text(d.title).font(.subheadline).fontWeight(.medium)
                                Spacer()
                                ConfidenceBadge(value: d.confidence)
                            }
                            if let det = d.details { Text(det).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            Label(d.sourceItemTitle, systemImage: "doc.text").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, AppSpacing.xs)
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([0.0, 0.5, 0.7, 0.9], id: \.self) { threshold in
                        Button { minConfidence = threshold } label: {
                            Label(threshold == 0 ? "All" : "≥ \(Int(threshold*100))%", systemImage: minConfidence == threshold ? "checkmark" : "")
                        }
                    }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
        .task { await loadDecisions() }
    }

    private func loadDecisions() async {
        let store = FileArtifactStore()
        let items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
        var result: [DecisionItem] = []
        for item in items {
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for d in analysis.decisions {
                result.append(DecisionItem(title: d.title, details: d.details, sourceItemID: item.id, sourceItemTitle: item.title, sourceItemDate: item.createdAt, confidence: d.confidence ?? 0.5))
            }
        }
        decisions = result.sorted { $0.confidence > $1.confidence }
        isLoading = false
    }
}

// MARK: - Risk Register

struct RiskItem: Identifiable {
    let id = UUID()
    let title: String; let details: String?; let sourceItemID: UUID
    let sourceItemTitle: String; let sourceItemDate: Date; let confidence: Double
}

struct ProjectRiskRegisterView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var risks: [RiskItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                Spacer(); ProgressView("Loading risks..."); Spacer()
            } else if risks.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "exclamationmark.shield").font(.title).foregroundStyle(.secondary)
                    Text("No risks identified").font(.headline)
                }
                Spacer()
            } else {
                List {
                    ForEach(risks) { r in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            HStack(spacing: AppSpacing.sm) {
                                Image(systemName: "exclamationmark.shield.fill").font(.caption).foregroundStyle(r.confidence >= 0.8 ? .red : .orange)
                                Text(r.title).font(.subheadline).fontWeight(.medium)
                                Spacer()
                                ConfidenceBadge(value: r.confidence)
                            }
                            if let det = r.details { Text(det).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Label(r.sourceItemTitle, systemImage: "doc.text").font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, AppSpacing.xs)
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            }
        }
        .task { await loadRisks() }
    }

    private func loadRisks() async {
        let store = FileArtifactStore()
        let items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
        var result: [RiskItem] = []
        for item in items {
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for r in analysis.risks {
                result.append(RiskItem(title: r.risk, details: r.details, sourceItemID: item.id, sourceItemTitle: item.title, sourceItemDate: item.createdAt, confidence: r.confidence ?? 0.5))
            }
        }
        risks = result.sorted { $0.confidence > $1.confidence }
        isLoading = false
    }
}

// MARK: - People Directory

struct PersonSummary: Identifiable {
    let id: UUID; let name: String; let role: String?
    let taskCount: Int; let openTaskCount: Int; let mentionCount: Int
}

struct ProjectPeopleView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var people: [PersonSummary] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                Spacer(); ProgressView("Loading people..."); Spacer()
            } else if people.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "person.2").font(.title).foregroundStyle(.secondary)
                    Text("No people identified").font(.headline)
                }
                Spacer()
            } else {
                List {
                    ForEach(people) { p in
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: "person.circle.fill").font(.title2).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline).fontWeight(.medium)
                                if let role = p.role { Text(role).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if p.openTaskCount > 0 { Text("\(p.openTaskCount) open").font(.caption2).foregroundStyle(.orange) }
                                Text("\(p.taskCount) tasks").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, AppSpacing.xs)
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            }
        }
        .task { await loadPeople() }
    }

    private func loadPeople() async {
        let projSvc = ProjectService(context: modelContext)
        let taskSvc = TaskService(context: modelContext)
        let store = FileArtifactStore()
        guard let tasks = try? taskSvc.tasks(for: projectID), let items = try? projSvc.items(in: projectID) else { isLoading = false; return }
        var map: [String: (UUID, String?, Int, Int, Int)] = [:]
        for t in tasks {
            guard let o = t.ownerName, !o.isEmpty else { continue }
            var s = map[o] ?? (UUID(), nil, 0, 0, 0)
            s.2 += 1; if t.status == .todo || t.status == .inProgress { s.3 += 1 }
            map[o] = s
        }
        for item in items {
            guard let a = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for act in a.actionItems {
                guard let o = act.owner, !o.isEmpty else { continue }
                var s = map[o] ?? (UUID(), nil, 0, 0, 0); s.4 += 1; map[o] = s
            }
        }
        for person in (try? modelContext.fetch(FetchDescriptor<Person>())) ?? [] {
            var s = map[person.displayName] ?? (person.id, person.role, 0, 0, 0)
            s.0 = person.id; s.1 = person.role; map[person.displayName] = s
        }
        people = map.map { PersonSummary(id: $1.0, name: $0, role: $1.1, taskCount: $1.2, openTaskCount: $1.3, mentionCount: $1.4) }.sorted { $0.taskCount > $1.taskCount }
        isLoading = false
    }
}

// MARK: - Entity Browser

struct EntitySummary: Identifiable {
    let id = UUID(); let name: String; let kind: String; let mentionCount: Int
}

struct ProjectEntitiesView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var entities: [EntitySummary] = []
    @State private var selectedKind: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                Spacer(); ProgressView("Loading entities..."); Spacer()
            } else if entities.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "cube").font(.title).foregroundStyle(.secondary)
                    Text("No entities identified").font(.headline)
                }
                Spacer()
            } else {
                let kinds = Array(Set(entities.map(\.kind))).sorted()
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.xs) {
                            Button { selectedKind = nil } label: {
                                Text("All").font(.caption2).padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                                    .background(selectedKind == nil ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill)).clipShape(Capsule())
                            }
                            ForEach(kinds, id: \.self) { kind in
                                Button { selectedKind = kind } label: {
                                    Text(kind.capitalized).font(.caption2).padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                                        .background(selectedKind == kind ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill)).clipShape(Capsule())
                                }
                            }
                        }.padding(.horizontal, AppSpacing.md).padding(.vertical, AppSpacing.xs)
                    }
                    let filtered = selectedKind == nil ? entities : entities.filter { $0.kind == selectedKind }
                    List(filtered) { e in
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: kindIcon(e.kind)).font(.caption).foregroundStyle(kindColor(e.kind)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).font(.subheadline).fontWeight(.medium)
                                Text(e.kind.capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(e.mentionCount)").font(.caption).fontWeight(.semibold)
                        }.padding(.vertical, AppSpacing.xs)
                    }
                    .listStyle(.insetGrouped).scrollContentBackground(.hidden)
                }
            }
        }
        .task { await loadEntities() }
    }

    private func loadEntities() async {
        let store = FileArtifactStore()
        let items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
        var map: [String: (String, Int)] = [:]
        for item in items {
            guard let a = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for e in a.entities {
                let key = "\(e.name)|\(e.type.rawValue)"; var v = map[key] ?? (e.type.rawValue, 0); v.1 += 1; map[key] = v
            }
        }
        entities = map.map { entry in EntitySummary(name: String(entry.key.split(separator: "|")[0]), kind: entry.value.0, mentionCount: entry.value.1) }.sorted { $0.mentionCount > $1.mentionCount }
        isLoading = false
    }

    private func kindIcon(_ k: String) -> String {
        switch k { case "organization": "building.2"; case "system": "server.rack"; case "repository": "chevron.left.forwardslash.chevron.right"; case "ticket": "tag"; case "location": "location"; default: "cube" }
    }
    private func kindColor(_ k: String) -> Color {
        switch k { case "organization": .blue; case "system": .purple; case "repository": .green; case "ticket": .orange; case "location": .teal; default: .gray }
    }
}