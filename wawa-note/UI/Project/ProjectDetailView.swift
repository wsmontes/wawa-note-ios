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
            pipeline.process(item.id, using: ctx)
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
    @EnvironmentObject private var chatState: ChatOverlayState
    @StateObject private var viewModel: ProjectDetailViewModel
    @State private var selectedDynamicTab = 0
    @State private var overviewExpanded = true

    private var framework: ProjectFramework {
        FrameworkService.shared.resolve(for: project)
    }

    private var collapsedOverview: some View {
        HStack(spacing: 8) {
            Circle().fill(healthColor).frame(width: 8, height: 8)
            Text(project.name).font(.caption).fontWeight(.medium).lineLimit(1)
            if let score = project.healthScore { Text("· \(Int(score))").font(.caption2).foregroundStyle(healthColor) }
            Spacer()
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(Color(.systemBackground))
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

            Picker("View", selection: $selectedDynamicTab) {
                ForEach(Array(framework.views.enumerated()), id: \.offset) { idx, view in
                    Text(view.title).tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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
            chatState.context = .project(project.id)
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

// MARK: - Project Overview Dashboard (Phase A)

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
            cachedRisks = computeRisks() // Cache disk reads
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
        VStack(spacing: 12) {
            // Pulse strip
            if let h = health {
                pulseStrip(health: h)
            }

            // Attention required
            if !overdueTasks.isEmpty || !openRisks.isEmpty {
                attentionSection
            }

            // Project synthesis
            synthesisSection

            // Suggestions to review (Phase G)
            suggestionsSection

            // Activity feed (last 7 days)
            activityFeed
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { refreshHealth() }
        .onDisappear { healthTask?.cancel() }
        .onChange(of: viewModel.projectItems.count) { _ in refreshHealth() }
        .padding(.bottom, 8)
    }

    // MARK: Pulse Strip

    private func pulseStrip(health: ProjectHealthEngine.HealthResult) -> some View {
        HStack(spacing: 8) {
            // Health ring
            HealthRingView(score: health.score, status: health.status)
            Spacer()
            MetricTile(icon: "checkmark.seal", value: String(format: "%.0f", health.decisionVelocity * 4),
                       label: "Decisions", subtitle: "this month")
            MetricTile(icon: "exclamationmark.shield", value: "\(Int(health.riskExposure * 100))%",
                       label: "Exposure", subtitle: health.anomalies.isEmpty ? "Clear" : "Watch")
            MetricTile(icon: "circle.dotted", value: "\(items.count)",
                       label: "Items", subtitle: health.evidenceFreshnessDays < 7 ? "Active" : "\(Int(health.evidenceFreshnessDays))d old")
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: Attention Section

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text("Needs attention").font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                Spacer()
                Text("\(overdueTasks.count + openRisks.count) items").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(overdueTasks.prefix(3)) { task in
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.red)
                    Text(task.title).font(.caption).lineLimit(1)
                    Spacer()
                    if let due = task.dueAt {
                        Text(due.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(8).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach(Array(openRisks.enumerated()).prefix(2), id: \.offset) { _, riskData in
                let (risk, _, conf) = riskData
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    Text(risk).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int(conf * 100))%").font(.caption2).foregroundStyle(.orange)
                }
                .padding(8).background(Color.orange.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: Synthesis

    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: Suggestions (Phase G)

    private var pendingSuggestions: [AgentSuggestion] { cachedSuggestions }

    private func fetchPendingSuggestions(_ ctx: ModelContext) -> [AgentSuggestion] {
        let all = (try? ctx.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        return all.filter { $0.projectID == project.id && $0.status == "pending" }
    }

    private var suggestionsSection: some View {
        let pending = pendingSuggestions
        guard !pending.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        )
    }

    private func suggestionCard(_ sug: AgentSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
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
            HStack(spacing: 8) {
                Button { approveSuggestion(sug) } label: {
                    Label("Approve", systemImage: "checkmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.green.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Button { rejectSuggestion(sug) } label: {
                    Label("Reject", systemImage: "xmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.red.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Spacer()
                AIGeneratedBadge(confidence: sug.confidence, source: "AI suggestion")
            }
        }
        .padding(8).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func approveSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        // Execute the suggestion based on type
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
        default: break
        }
        sug.status = "approved"; sug.resolvedAt = Date()
        try? ctx.save()
    }

    private func rejectSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        sug.status = "rejected"; sug.resolvedAt = Date()
        try? ctx.save()
        // Record negative feedback for future learning
        AgentMemoryStore.shared.write(pattern: "rejected_\(sug.type)", strategy: "User rejected: \(sug.title.prefix(60))",
            itemType: sug.type, contentType: nil, language: nil)
    }

    // MARK: Activity Feed

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

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath").font(.caption).foregroundStyle(.green)
                Text("Recent activity").font(.caption).fontWeight(.semibold)
            }
            if recent.isEmpty {
                Text("No activity yet").font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.icon).font(.caption2).foregroundStyle(entry.color)
                        Text(entry.text).font(.caption).lineLimit(1)
                        Spacer()
                        Text(entry.date.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(6)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

// MARK: - Sub-components

private struct HealthRingView: View {
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

private struct MetricTile: View {
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
