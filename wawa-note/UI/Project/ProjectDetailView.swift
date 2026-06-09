import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Shared Signal Helpers

private func signalColor(_ type: String) -> Color {
    switch type {
    case "risk": .red; case "alert": .orange; case "opportunity": .green
    case "contradiction": .purple; case "pattern": .blue; case "doubt": .yellow
    case "new_project": .mint; case "emerging_problem": .pink
    default: .secondary
    }
}

private func signalIcon(_ type: String) -> String {
    switch type {
    case "risk": "exclamationmark.triangle.fill"; case "alert": "bell.fill"
    case "opportunity": "lightbulb.fill"; case "contradiction": "arrow.triangle.swap"
    case "pattern": "rectangle.3.group.fill"; case "doubt": "questionmark.circle.fill"
    case "new_project": "sparkles"; case "emerging_problem": "ant.fill"
    default: "dot.radiowaves.left.and.right"
    }
}

private func activitySignalIcon(_ type: String) -> String { signalIcon(type) }
private func activitySignalColor(_ type: String) -> Color { signalColor(type) }

// MARK: - Project Detail (Entry Point)

/// Entry point for project navigation. Kept for backward compatibility with existing callers.
/// Delegates immediately to the new ProjectHomeView.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var chatState: ChatOverlayState

    var body: some View {
        ProjectHomeView(project: project)
            .onAppear {
                chatState.context = .project(project.id)
                AppLog.debug("project", "ProjectDetailView appeared — project=\(project.name) id=\(project.id.uuidString.prefix(8)) status=\(project.status.rawValue) health=\(project.healthStatus ?? "nil")")
            }
    }
}

// MARK: - Stable Project Detail Link (Navigation-safe)

/// Resolves a project by UUID and holds it in `@State` so that SwiftData context saves
/// (which cause `@Query` to emit new managed-object instances) do NOT recreate the view.
/// Always prefer this over passing a `Project` managed object through navigation state.
struct ProjectDetailLink: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var project: Project?
    @State private var resolutionAttempted = false

    var body: some View {
        Group {
            if let project {
                ProjectDetailView(project: project)
            } else {
                Color.clear
                    .onAppear { resolveIfNeeded() }
            }
        }
    }

    private func resolveIfNeeded() {
        guard !resolutionAttempted else { return }
        resolutionAttempted = true
        let predicate = #Predicate<Project> { $0.id == projectID }
        let descriptor = FetchDescriptor<Project>(predicate: predicate)
        project = try? modelContext.fetch(descriptor).first
        if project == nil {
            AppLog.general.warning("ProjectDetailLink: project not found for id \(projectID.uuidString.prefix(8))")
        }
    }
}

// MARK: - Project Home (Glance Layer)

struct ProjectHomeView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var processingQueue: ProcessingQueueService
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var tasks: [TaskItem] = []
    @State private var items: [KnowledgeItem] = []
    @State private var signals: [AgentSuggestion] = []
    @State private var showActionSheet = false
    @State private var showNoteEditor = false
    @State private var showFileImporter = false
    @State private var createdNoteItem: KnowledgeItem? = nil
    @State private var lastLoadTime: Date = .distantPast

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                metricsRow
                if project.healthStatus != nil || (project.healthScore ?? 0) > 0 {
                    healthSection
                }
                if !signals.isEmpty {
                    alertsSection
                }
                recentActivity
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showActionSheet = true } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                    Button { exportJSON() } label: {
                        Label("Export JSON", systemImage: "doc.text")
                    }
                    Button { exportMarkdown() } label: {
                        Label("Export Markdown", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
        }
        .confirmationDialog("Add to Project", isPresented: $showActionSheet) {
            Button("Record Audio") { coordinator.startRecording(projectID: project.id) }
            Button("Add Note") { showNoteEditor = true }
            Button("Import File") { showFileImporter = true }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showNoteEditor) {
            NoteEditorView(mode: .create(type: .note, folderID: nil, initialTag: nil))
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText, .pdf, .html, .rtf, .audio, .image]) { result in
            if case .success(let url) = result {
                Task { await handleImportedFile(url) }
            }
        }
        .onAppear { loadData() }
        .onChange(of: createdNoteItem?.id) { _, _ in
            if let item = createdNoteItem {
                try? ProjectService(context: modelContext).addItem(item.id, to: project.id)
                processingQueue.enqueue(itemID: item.id, projectID: project.id, trigger: .newCapture)
                createdNoteItem = nil
            }
        }
        .refreshable { loadData(force: true) }
    }

    // MARK: Header

    @State private var editingIntention = false
    @State private var intentionDraft = ""

    private var headerSection: some View {
        VStack(spacing: 8) {
            if editingIntention {
                HStack {
                    TextField("Qual é a intenção deste projeto?", text: $intentionDraft, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(3...6)
                    Button("Save") {
                        let trimmed = intentionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        project.intention = trimmed.isEmpty ? nil : trimmed
                        project.intentionIsAutoGenerated = false
                        try? modelContext.save()
                        editingIntention = false
                    }.font(.subheadline).fontWeight(.medium)
                }
                .padding(8)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let intent = project.intention, !intent.isEmpty {
                Button { intentionDraft = intent; editingIntention = true } label: {
                    HStack(spacing: 4) {
                        Text(intent)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if project.intentionIsAutoGenerated {
                            Text("AI").font(.system(size: 9)).padding(.horizontal, 4).background(.blue.opacity(0.15)).clipShape(Capsule())
                        }
                    }
                }
            } else {
                Button { intentionDraft = ""; editingIntention = true } label: {
                    Text("Qual é a intenção deste projeto?")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            statusBadge
        }
    }

    private var statusBadge: some View {
        Text(project.status.rawValue.capitalized)
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(project.status == .active ? Color.blue.opacity(0.12) : Color.gray.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: Metrics Row

    private var metricsRow: some View {
        VStack(spacing: 10) {
            // Items card
            NavigationLink {
                ItemsView(projectID: project.id)
            } label: {
                richMetricCard(
                    icon: "doc.fill", iconColor: .blue,
                    title: "Items", count: items.count,
                    subtitle: itemBreakdown,
                    accent: unprocessedCount > 0 ? "\(unprocessedCount) unprocessed" : nil,
                    accentColor: .orange
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            // Tasks card
            NavigationLink {
                BoardView(projectID: project.id)
            } label: {
                richMetricCard(
                    icon: "checklist", iconColor: .teal,
                    title: "Tasks", count: tasks.count,
                    subtitle: taskBreakdown,
                    accent: overdueCount > 0 ? "\(overdueCount) overdue" : nil,
                    accentColor: .red
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            // Signals card
            if !signals.isEmpty {
                NavigationLink {
                    SignalsView(projectID: project.id)
                } label: {
                    richMetricCard(
                        icon: "waveform.path.ecg", iconColor: activeSignals.contains { $0.type == "risk" || $0.type == "alert" } ? .red : .purple,
                        title: "Signals", count: activeSignals.count,
                        subtitle: signalBreakdown,
                        accent: criticalDoubts > 0 ? "\(criticalDoubts) critical doubts" : nil,
                        accentColor: .orange
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
    }

    private func richMetricCard(icon: String, iconColor: Color, title: String, count: Int, subtitle: String, accent: String?, accentColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)").font(.title2).fontWeight(.bold).foregroundStyle(iconColor)
                if let accent {
                    Text(accent).font(.caption2).foregroundStyle(accentColor)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var itemBreakdown: String {
        let byType = Dictionary(grouping: items, by: \.type)
        return byType.map { "\($0.value.count) \($0.key.label.lowercased())" }.joined(separator: " · ")
    }

    private var taskBreakdown: String {
        let byStatus = Dictionary(grouping: tasks, by: \.status)
        return columnsOrder.compactMap { s in
            byStatus[s].map { "\($0.count) \(s.rawValue.lowercased())" }
        }.joined(separator: " · ")
    }

    private var signalBreakdown: String {
        let byType = Dictionary(grouping: activeSignals, by: \.type)
        return byType.prefix(3).map { "\($0.value.count) \($0.key.replacingOccurrences(of: "_", with: " "))" }.joined(separator: " · ")
    }

    private var columnsOrder: [TaskStatus] { [.todo, .inProgress, .done, .cancelled] }

    private var unprocessedCount: Int {
        items.filter { $0.inboxDate != nil && $0.analysisProviderId == nil }.count
    }

    private var overdueCount: Int {
        tasks.filter { ($0.dueAt ?? .distantFuture) < Date() && $0.status != .done }.count
    }

    private var activeSignals: [AgentSuggestion] {
        signals.filter { $0.isActive }
    }

    private var criticalDoubts: Int {
        signals.filter { $0.type == "doubt" && $0.isCritical && $0.isActive }.count
    }

    // MARK: Health + Status

    private var healthSection: some View {
        VStack(spacing: 12) {
            HStack {
                if let score = project.healthScore {
                    HealthRing(score: score, status: project.healthStatus ?? "healthy")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Health")
                        .font(.headline)
                    if let status = project.healthStatus {
                        Text(status.capitalized)
                            .font(.subheadline)
                            .foregroundStyle(healthColor)
                    }
                    if let inertia = inertiaScore {
                        Text("Ontology: \(OntologyInertiaService.shared.inertiaLabel(inertia))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            // Processing status
            let pendingCount = items.filter { $0.inboxDate != nil && $0.analysisProviderId == nil }.count
            let activeInQueue = processingQueue.entries.filter {
                $0.status == .queued || $0.status == .processing
            }.count

            if activeInQueue > 0 {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Processing \(activeInQueue) item\(activeInQueue > 1 ? "s" : "")...")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Spacer()
                }
            } else if pendingCount > 0 {
                let hasProvider = (try? ProviderRouter.resolveActive(context: modelContext)) != nil
                Button {
                    for item in items.prefix(5) where item.inboxDate != nil && item.analysisProviderId == nil {
                        processingQueue.enqueue(itemID: item.id, projectID: project.id, trigger: .backgroundBackfill)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(hasProvider
                             ? "Process \(pendingCount) pending item\(pendingCount > 1 ? "s" : "")"
                             : "\(pendingCount) item\(pendingCount > 1 ? "s" : "") waiting — configure AI provider in Settings")
                            .font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(hasProvider ? .blue : .orange)
                }
                .disabled(!hasProvider)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var healthColor: Color {
        switch project.healthStatus { case "healthy": .mint; case "stale": .orange; case "atRisk": .red; default: .secondary }
    }

    private var inertiaScore: Double? {
        OntologyInertiaService.shared.computeInertia(projectID: project.id, context: modelContext)
    }

    // MARK: Alerts

    private var alertsSection: some View {
        let active = signals.filter { $0.isActive }
        let doubts = active.filter { $0.type == "doubt" }
        guard !active.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            NavigationLink {
                SignalsView(projectID: project.id)
            } label: {
                VStack(spacing: 8) {
                    HStack {
                        Label("Signals", systemImage: "waveform.path.ecg")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        if !doubts.isEmpty {
                            Label("\(doubts.count) doubts", systemImage: "questionmark.bubble.fill")
                                .font(.subheadline)
                                .foregroundStyle(doubts.contains { $0.isCritical } ? .orange : .yellow)
                        }
                        if active.count > doubts.count {
                            Label("\(active.count - doubts.count) signals", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(active.contains { $0.type == "risk" || $0.type == "alert" } ? .red : .secondary)
                        }
                        Spacer()
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        )
    }

    // MARK: Activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            let activities = buildActivityFeed()
            if activities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Activity will appear here as items are processed and tasks are completed")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(activities.prefix(8)) { event in
                    activityRow(icon: event.icon, color: event.color, title: event.title, snippet: event.snippet, date: event.date)
                }
            }
        }
    }

    private struct ActivityEvent: Identifiable {
        let id = UUID()
        let icon: String; let color: Color; let title: String; let snippet: String; let date: Date
    }

    private func buildActivityFeed() -> [ActivityEvent] {
        var events: [ActivityEvent] = []

        // Analyzed items
        for item in items where item.analysisProviderId != nil {
            events.append(ActivityEvent(icon: "sparkles", color: .purple,
                title: "Item analyzed", snippet: item.title, date: item.updatedAt))
        }

        // Completed tasks
        for task in tasks where task.status == .done {
            events.append(ActivityEvent(icon: "checkmark.circle.fill", color: .green,
                title: "Task completed", snippet: task.title, date: task.updatedAt))
        }

        // Active signals
        for signal in signals where signal.isActive {
            events.append(ActivityEvent(icon: signalIcon(signal.type), color: signalColor(signal.type),
                title: "Signal: \(signal.type.replacingOccurrences(of: "_", with: " "))", snippet: signal.title, date: signal.createdAt))
        }

        // Recently created items
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }).prefix(3) {
            events.append(ActivityEvent(icon: "plus.circle.fill", color: .blue,
                title: "Item added", snippet: item.title, date: item.createdAt))
        }

        return events.sorted(by: { $0.date > $1.date })
    }

    private func activityRow(icon: String, color: Color, title: String, snippet: String, date: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(date.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions


    private func handleImportedFile(_ url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let router = ImportRouter(importers: [
            JSONImporter(), MarkdownImporter(), PlainTextImporter(),
            SRTImporter(), ICSImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
            AnarlogImporter()
        ])
        guard let importer = router.importer(for: url) else { return }
        do {
            let result = try await importer.importFromURL(url)
            let item = result.knowledgeItem
            modelContext.insert(item)
            try? modelContext.save()
            try? ProjectService(context: modelContext).addItem(item.id, to: project.id)
            processingQueue.enqueue(itemID: item.id, projectID: project.id, trigger: .newCapture)
            loadData()
        } catch {
            AppLog.general.error("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Data loading

    private func loadData(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastLoadTime) < 1.0 {
            return  // Skip redundant reloads within 1 second
        }
        lastLoadTime = now
        AppLog.debug("project", "loadData start — projectID=\(project.id.uuidString.prefix(8))")
        tasks = (try? TaskService(context: modelContext).tasks(for: project.id)) ?? []
        items = (try? ProjectService(context: modelContext).items(in: project.id)) ?? []
        let all = (try? modelContext.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        signals = all.filter { $0.projectID == project.id }
        AppLog.debug("project", "loadData done — tasks=\(tasks.count) items=\(items.count) signals=\(signals.count)")
    }

    private func exportJSON() {
        let svc = InstanceExportService()
        let export = svc.exportSingleProject(project, context: modelContext)
        guard let data = try? JSONEncoder().encode(export),
              let json = String(data: data, encoding: .utf8) else { return }
        let vc = UIActivityViewController(activityItems: [json], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController { root.present(vc, animated: true) }
    }

    private func exportMarkdown() {
        let exporter = ProjectExportService()
        let edges = (try? GraphEdgeService(context: modelContext).neighborhood(of: project.id, radius: 2)) ?? []
        let md = exporter.exportMarkdown(project: project, items: items, tasks: tasks, edges: edges)
        let vc = UIActivityViewController(activityItems: [md], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController { root.present(vc, animated: true) }
    }
}

// MARK: - Health Ring

private struct HealthRing: View {
    let score: Double
    let status: String

    var body: some View {
        let color: Color = status == "healthy" ? .mint : status == "stale" ? .orange : status == "atRisk" ? .red : .gray
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(score / 100.0, 0.02))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.8), value: score)
            Text("\(Int(score))")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .frame(width: 48, height: 48)
    }
}

// MARK: - Items View (List Layer)

struct ItemsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var items: [KnowledgeItem] = []
    @State private var searchText = ""
    @State private var selectedType: String? = nil
    @State private var sortOrder: ItemSortOrder = .recent

    var body: some View {
        List {
            if filteredItems.isEmpty {
                emptyState
            } else {
                ForEach(filteredItems) { item in
                    NavigationLink {
                        KnowledgeDetailView(item: item)
                    } label: {
                        itemRow(item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? TrashService(context: modelContext).moveToTrash(item)
                            loadItems()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search items")
        .navigationTitle("Items")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ItemSortOrder.allCases, id: \.self) { order in
                            Button { sortOrder = order } label: {
                                Label(order.label, systemImage: sortOrder == order ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.caption)
                    }
                    filterMenu
                }
            }
        }
        .onAppear { loadItems() }
        .refreshable { loadItems() }
    }

    private var filteredItems: [KnowledgeItem] {
        var result = items
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .recent: result.sort { $0.updatedAt > $1.updatedAt }
        case .name: result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .type: result.sort { ($0.typeRaw) < ($1.typeRaw) }
        case .created: result.sort { $0.createdAt > $1.createdAt }
        }
        if let type = selectedType {
            result = result.filter { $0.type.rawValue == type }
        }
        return result
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text("No items match").font(.headline)
            Text("Try adjusting your search or filter.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    private var filterMenu: some View {
        Menu {
            Button("All") { selectedType = nil }
            ForEach(KnowledgeItemType.allCases, id: \.rawValue) { t in
                Button(t.label) { selectedType = t.rawValue }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline)
        }
    }

    private func itemRow(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.icon)
                .frame(width: 32)
                .foregroundStyle(item.type.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.type.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.inboxDate != nil {
                Text("Unprocessed").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12)).clipShape(Capsule())
            }
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func loadItems() {
        items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
    }
}

// MARK: - Board View (Kanban — HIG-Compliant)

struct BoardView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var tasks: [TaskItem] = []
    @State private var items: [KnowledgeItem] = []
    @State private var selectedColumn = 0
    @State private var showNewTask = false
    @State private var editingTask: TaskItem? = nil
    @State private var dropTarget: TaskStatus? = nil

    private let columns: [TaskStatus] = [.todo, .inProgress, .done, .cancelled]

    var body: some View {
        VStack(spacing: 0) {
            // Column selector — Apple segmented-control style
            HStack(spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { idx, status in
                    let count = filtered(status).count
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedColumn = idx }
                    } label: {
                        HStack(spacing: 4) {
                            Text(statusLabel(status))
                                .font(.subheadline)
                                .fontWeight(selectedColumn == idx ? .semibold : .regular)
                            Text("\(count)")
                                .font(.caption).fontWeight(.medium)
                                .foregroundStyle(selectedColumn == idx ? .primary : .secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(selectedColumn == idx ? statusColor(status).opacity(0.12) : .clear)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.top, 4)

            // Snap-scroll columns — height constrained to visible area above tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { idx, status in
                        ScrollView(.vertical, showsIndicators: false) {
                            let columnTasks = filtered(status)
                            if columnTasks.isEmpty && (status != .todo || items.isEmpty) {
                                VStack(spacing: 12) {
                                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                                    Text("No tasks").font(.headline)
                                    Text("Tap + to create one").font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.top, 64)
                            } else {
                                VStack(spacing: 10) {
                                    if status == .todo {
                                        ForEach(items.prefix(5)) { item in
                                            knowledgeItemCard(item)
                                        }
                                        if !items.isEmpty && !columnTasks.isEmpty {
                                            Divider().padding(.vertical, 4)
                                        }
                                    }
                                    ForEach(columnTasks) { task in
                                        taskCard(task)
                                    }
                                }
                                .padding(.top, 10)
                                .padding(.horizontal, 12)
                            }
                        }
                        .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 16)
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let idStr = dropped.first,
                                  let uuid = UUID(uuidString: idStr),
                                  let task = tasks.first(where: { $0.id == uuid }),
                                  task.status != status else { return false }
                            moveTask(task, to: status)
                            return true
                        } isTargeted: { targeted in
                            dropTarget = targeted ? status : nil
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: .init(get: { selectedColumn }, set: { if let i = $0 { selectedColumn = i } }))
            .refreshable { loadData() }
        }
        .navigationTitle("Board")
        .overlay(alignment: .bottomTrailing) {
            Button { showNewTask = true } label: {
                Image(systemName: "plus")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.blue, in: Circle())
                    .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.trailing, 20).padding(.bottom, 20)
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $editingTask) { TaskEditorView(mode: .edit(task: $0)) }
        .sheet(isPresented: $showNewTask) { TaskEditorView(mode: .create(projectID: projectID)) }
        .onAppear { loadData() }
    }

    // MARK: Task Card — HIG spec: 16pt padding, headline 17pt, 4pt left bar, relative dates

    private func taskCard(_ task: TaskItem) -> some View {
        let barColor = priorityBarColor(task.priority)

        return Button { editingTask = task } label: {
            HStack(spacing: 0) {
                // 4pt left color bar for priority — zero text cost, instant scan
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: 4)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    // Title: headline 17pt semibold, 2 lines max
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Metadata row: owner + due date + source badge
                    HStack(spacing: 8) {
                        if let owner = task.ownerName {
                            Label(owner, systemImage: "person.fill")
                                .font(.caption)
                        }
                        if let due = task.dueAt {
                            Label(relativeDueDate(due), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(due < Date() ? .red : dueTimeColor(due))
                        }
                        if let createdBy = task.createdBy {
                            Text(createdBy == .user ? "You" : "AI")
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(createdBy == .user ? Color.blue.opacity(0.1) : Color.purple.opacity(0.1))
                                .clipShape(Capsule())
                                .foregroundStyle(createdBy == .user ? .blue : .purple)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(dropTarget == task.status ? Color.green.opacity(0.5) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .draggable(task.id.uuidString)
        .contextMenu {
            Button { editingTask = task } label: { Label("Edit", systemImage: "pencil") }
            ForEach(columns, id: \.rawValue) { col in
                if col != task.status {
                    Button { moveTask(task, to: col) } label: {
                        Label("Move to \(statusLabel(col))", systemImage: "arrow.right")
                    }
                }
            }
            Divider()
            Button(role: .destructive) { deleteTask(task) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            ForEach(columns.prefix(2), id: \.rawValue) { col in
                if col != task.status {
                    Button { moveTask(task, to: col) } label: { Text(statusLabel(col)) }.tint(statusColor(col))
                }
            }
        }
    }

    // MARK: Knowledge Item Card

    private func knowledgeItemCard(_ item: KnowledgeItem) -> some View {
        NavigationLink { KnowledgeDetailView(item: item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.type.icon).foregroundStyle(item.type.color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(item.type.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.analysisProviderId != nil {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                }
            }
            .padding(12)
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Helpers

    private func filtered(_ status: TaskStatus) -> [TaskItem] { tasks.filter { $0.status == status } }

    private func moveTask(_ task: TaskItem, to status: TaskStatus) {
        try? TaskService(context: modelContext).updateStatus(task, to: status)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        loadData()
    }

    private func deleteTask(_ task: TaskItem) {
        try? TaskService(context: modelContext).deleteTask(task)
        loadData()
    }

    private func loadData() {
        tasks = (try? TaskService(context: modelContext).tasks(for: projectID)) ?? []
        items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
    }
}

// MARK: Board Helpers (file-private)

private func statusLabel(_ s: TaskStatus) -> String { s.rawValue.capitalized }

private func statusColor(_ s: TaskStatus) -> Color {
    switch s { case .todo: .blue; case .inProgress: .orange; case .done: .green; case .cancelled: .gray }
}

private func priorityBarColor(_ p: TaskPriority) -> Color {
    switch p { case .critical: .red; case .high: .orange; case .medium: .blue; case .low: .clear }
}

private func relativeDueDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInTomorrow(date) { return "Tomorrow" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: Date(), to: date).day {
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if days < 0 && days > -7 { return "\(-days)d ago" }
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private func dueTimeColor(_ date: Date) -> Color {
    Calendar.current.isDateInToday(date) ? .orange : .secondary
}

// MARK: - Signals View (Feed Layer)

struct SignalsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var signals: [AgentSuggestion] = []
    @State private var filter: SignalFilter = .active

    enum SignalFilter: String, CaseIterable { case active, resolved, critical }

    var body: some View {
        List {
            if filteredSignals.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No signals").font(.headline)
                    Text("Signals will appear here when the system detects patterns, risks, or opportunities.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 48)
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredSignals) { signal in
                    signalCard(signal)
                        .swipeActions {
                            Button { acknowledgeSignal(signal) } label: { Label("Acknowledge", systemImage: "eye") }.tint(.blue)
                            Button { archiveSignal(signal) } label: { Label("Archive", systemImage: "archivebox") }.tint(.gray)
                            if ["risk", "alert", "opportunity", "doubt"].contains(signal.type) {
                                Button { transformToTask(signal) } label: { Label("Task", systemImage: "checklist") }.tint(.green)
                            }
                        }
                }
            }
        }
        .navigationTitle("Signals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Filter", selection: $filter) {
                    ForEach(SignalFilter.allCases, id: \.rawValue) { f in
                        Text(f.rawValue.capitalized).tag(f)
                    }
                }.pickerStyle(.segmented)
            }
        }
        .onAppear { loadSignals() }
    }

    private var filteredSignals: [AgentSuggestion] {
        switch filter {
        case .active: signals.filter { $0.isActive }
        case .resolved: signals.filter { !$0.isActive }
        case .critical: signals.filter { $0.isActive && $0.isCritical }
        }
    }

    private func signalCard(_ s: AgentSuggestion) -> some View {
        let color = signalColor(s.type)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: signalIcon(s.type)).foregroundStyle(color)
                Text(s.type.replacingOccurrences(of: "_", with: " ")).font(.caption).fontWeight(.medium).foregroundStyle(color)
                if s.isCritical {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Text(s.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
            }
            Text(s.title).font(.body).fontWeight(.medium)
            if let body = s.body, !body.isEmpty {
                Text(body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private func acknowledgeSignal(_ s: AgentSuggestion) {
        SignalResolutionService(context: modelContext).markAcknowledged(s)
        loadSignals()
    }

    private func archiveSignal(_ s: AgentSuggestion) {
        SignalResolutionService(context: modelContext).archive(s, reason: "Archived from feed")
        loadSignals()
    }

    private func transformToTask(_ s: AgentSuggestion) {
        _ = SignalResolutionService(context: modelContext).transformToTask(s, projectID: projectID)
        loadSignals()
    }

    private func loadSignals() {
        AppLog.debug("project", "SignalsView.loadSignals — projectID=\(projectID.uuidString.prefix(8))")
        let all = (try? modelContext.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        signals = all.filter { $0.projectID == projectID }
        AppLog.debug("project", "SignalsView.loadSignals done — total=\(all.count) filtered=\(signals.count)")
    }
}


// MARK: - Item Sort Order

enum ItemSortOrder: CaseIterable {
    case recent, name, type, created
    var label: String {
        switch self {
        case .recent: "Recent"
        case .name: "Name"
        case .type: "Type"
        case .created: "Created"
        }
    }
}

// MARK: - Document Scanner (VisionKit wrapper)

