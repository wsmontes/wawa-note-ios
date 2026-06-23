import SwiftUI
import SwiftData
import UniformTypeIdentifiers
// Related JIRA: KAN-8, KAN-10


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

/// Entry point for project navigation. Routes config projects to ConfigProjectBrowserView.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var chatState: ChatOverlayState

    var body: some View {
        if ConfigProjectService.isConfigProject(project) {
            ConfigProjectBrowserView(project: project)
                .onAppear { chatState.context = .project(project.id) }
        } else {
            ProjectHomeView(project: project)
                .onAppear {
                    chatState.context = .project(project.id)
                    AppLog.debug("project", "ProjectDetailView appeared — project=\(project.name) id=\(project.id.uuidString.prefix(8)) status=\(project.status.rawValue) health=\(project.healthStatus ?? "nil")")
                }
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

    @EnvironmentObject private var services: ServiceContainer
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

// MARK: - Project Home (Simplified)
// NOTE: This is the simplified version with Synthesis | Files segments (2026-06-18).
// The old ProjectHomeView with multiple tabs has been consolidated into this version.

struct ProjectHomeView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var chatState: ChatOverlayState
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var services: ServiceContainer
    @State private var selectedTab: ProjectTab = .synthesis
    @State private var showCaptureSheet = false
    @State private var showNoteEditor = false
    @State private var showFileImporter = false

    enum ProjectTab: String, CaseIterable {
        case synthesis = "Synthesis"
        case items = "Items"
        case files = "Files"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segment control
            Picker("View", selection: $selectedTab) {
                ForEach(ProjectTab.allCases, id: \.rawValue) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            // Content
            switch selectedTab {
            case .synthesis:
                ProjectSynthesisView(project: project)
            case .items:
                ProjectItemsView(projectID: project.id)
            case .files:
                ItemsView(projectID: project.id)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showCaptureSheet = true } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                    Button { exportMarkdown() } label: {
                        Label("Export Markdown", systemImage: "doc.richtext")
                    }
                    Button { exportJSON() } label: {
                        Label("Export JSON", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Add to Project", isPresented: $showCaptureSheet) {
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
        .onAppear {
            chatState.context = .project(project.id)
        }
    }

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
            if !result.warnings.isEmpty { AppLog.general.warning("Import \(url.lastPathComponent): \(result.warnings)") }
            modelContext.insert(item)
            try? modelContext.save()
            try? services.projects.addItem(item.id, to: project.id)
        } catch {
            AppLog.general.error("Import failed: \(error.localizedDescription)")
        }
    }

    private func exportMarkdown() {
        let items = (try? services.projects.items(in: project.id)) ?? []
        let derivedTasks = (try? services.derived.fetch(for: project.id, type: .task)) ?? []
        let edges = (try? GraphEdgeService(context: modelContext).neighborhood(of: project.id, radius: 2)) ?? []
        let exporter = ProjectExportService()

        // Build task rows from ProjectDerivedItem, matching the TaskItem format
        let taskRows = derivedTasks.map { t -> String in
            let check = t.status == .done ? "x" : " "
            var line = "- [\(check)] **\(t.title)**"
            if let owner = t.ownerName { line += " — \(owner)" }
            if let prio = t.priorityRaw, prio != "medium" { line += " · \(prio.capitalized)" }
            if let due = t.dueAt { line += " · Due: \(due.formatted(date: .abbreviated, time: .omitted))" }
            return line
        }

        let md = exporter.exportMarkdown(project: project, items: items, tasks: taskRows, edges: edges)
        let vc = UIActivityViewController(activityItems: [md], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController { root.present(vc, animated: true) }
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
}

// MARK: - Health Ring

private struct HealthRing: View {
    let score: Double
    let status: String

    @EnvironmentObject private var services: ServiceContainer
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

// MARK: - Unified Item Row

// MARK: - Items Tab — Aggregated Cards (KAN-256)

/// Aggregated view of all ProjectDerivedItem objects for a project,
/// displayed as typed cards with source attribution.
struct ProjectItemsView: View {
    let projectID: UUID
    @EnvironmentObject private var services: ServiceContainer
    @State private var derivedItems: [ProjectDerivedItem] = []
    @State private var filter: ItemFilter = .all
    @State private var isLoading = true

    enum ItemFilter: String, CaseIterable {
        case all = "All"
        case tasks = "Tasks"
        case signals = "Signals"
        case decisions = "Decisions"
        case questions = "Questions"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ItemFilter.allCases, id: \.rawValue) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            if isLoading {
                Spacer()
                ProgressView("Loading items...")
                Spacer()
            } else if filteredItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No items yet").font(.headline)
                    Text("Tasks, signals, decisions, and questions extracted from project items will appear here.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredItems) { di in
                            DerivedItemCard(item: di)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { loadData() }
    }

    private var filteredItems: [ProjectDerivedItem] {
        let items = derivedItems.filter { $0.type != .synthesis && $0.type != .connection }
        switch filter {
        case .all: return items
        case .tasks: return items.filter { $0.type == .task }
        case .signals: return items.filter { $0.type == .signal }
        case .decisions: return items.filter { $0.type == .decision }
        case .questions: return items.filter { $0.type == .question }
        }
    }

    private func loadData() {
        derivedItems = (try? services.derived.fetch(for: projectID)) ?? []
        isLoading = false
    }
}

/// A compact card for a ProjectDerivedItem, with typed icon, color, status,
/// priority, and source item attribution.
struct DerivedItemCard: View {
    let item: ProjectDerivedItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.body).foregroundStyle(typeColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline).fontWeight(.medium).lineLimit(2)
                HStack(spacing: 8) {
                    if let priority = item.priorityRaw {
                        HStack(spacing: 2) {
                            Image(systemName: "flag.fill").font(.system(size: 7))
                            Text(priority.capitalized)
                        }
                        .font(.caption2).foregroundStyle(priorityColor(priority))
                    }
                    if let owner = item.ownerName {
                        Text(owner).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let due = item.dueAt {
                        Text(due.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(item.isCritical ? .red : .secondary).frame(width: 5, height: 5)
                    Text(item.type.rawValue.capitalized).font(.caption2).foregroundStyle(.tertiary)
                    if let source = item.sourceItemID?.uuidString.prefix(8) {
                        Text("· src:\(source)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 4, y: 1)
    }

    private var typeIcon: String {
        switch item.type {
        case .task: "checklist"
        case .signal: "exclamationmark.triangle.fill"
        case .decision: "checkmark.shield.fill"
        case .question: "questionmark.circle.fill"
        default: "doc.text"
        }
    }

    private var typeColor: Color {
        switch item.type {
        case .task: .blue
        case .signal: .orange
        case .decision: .green
        case .question: .yellow
        default: .secondary
        }
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "critical": .red
        case "high": .orange
        case "medium": .blue
        default: .secondary
        }
    }
}

// MARK: - Items View (List Layer)

struct ItemsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var unifiedItems: [UnifiedItem] = []
    @State private var searchText = ""
    @State private var selectedType: UnifiedItemFilter = .all
    @State private var sortOrder: ItemSortOrder = .recent

    enum UnifiedItemFilter: String, CaseIterable {
        case all = "All"
        case meetings = "Meetings"
        case notes = "Notes"
        case tasks = "Tasks"
        case signals = "Signals"
        case synthesis = "Synthesis"
        case connections = "Connections"
    }

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        List {
            if filteredItems.isEmpty {
                emptyState
            } else {
                ForEach(filteredItems) { item in
                    unifiedRow(item)
                        .swipeActions(edge: .trailing) {
                            if case .knowledge(let ki) = item {
                                Button(role: .destructive) {
                                    try? TrashService(context: modelContext).moveToTrash(ki)
                                    loadItems()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } else if case .derived(let di) = item {
                                Button(role: .destructive) {
                                    try? services.derived.delete(di)
                                    loadItems()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search files")
        .navigationTitle("Files")
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

    private var filteredItems: [UnifiedItem] {
        var result = unifiedItems
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if selectedType != .all {
            result = result.filter { item in
                switch item {
                case .knowledge(let ki):
                    switch selectedType {
                    case .all: return true
                    case .meetings: return ki.type == .audio
                    case .notes: return ki.type == .note
                    default: return false
                    }
                case .derived(let di):
                    switch selectedType {
                    case .tasks: return di.type == .task
                    case .signals: return di.type == .signal
                    case .synthesis: return di.type == .synthesis
                    case .connections: return di.type == .connection
                    default: return false
                    }
                }
            }
        }
        switch sortOrder {
        case .recent: result.sort { $0.createdAt > $1.createdAt }
        case .name: result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .type: result.sort { $0.subtitle.localizedCompare($1.subtitle) == .orderedAscending }
        case .created: result.sort { $0.createdAt > $1.createdAt }
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
            ForEach(UnifiedItemFilter.allCases, id: \.rawValue) { filter in
                Button(filter.rawValue) { selectedType = filter }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline)
        }
    }

    private func unifiedRow(_ item: UnifiedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.displayIcon)
                .frame(width: 32)
                .foregroundStyle(item.displayColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isSource, case .knowledge(let ki) = item, ki.inboxDate != nil {
                Text("Unprocessed").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12)).clipShape(Capsule())
            }
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)

            SendToMenu(item: item, projectID: projectID)
        }
        .padding(.vertical, 4)
    }

    private func loadItems() {
        let knowledgeItems = (try? services.projects.items(in: projectID)) ?? []
        let derivedItems = (try? services.derived.fetch(for: projectID)) ?? []
        var combined: [UnifiedItem] = []
        combined.append(contentsOf: knowledgeItems.map { .knowledge($0) })
        combined.append(contentsOf: derivedItems.map { .derived($0) })
        unifiedItems = combined
    }
}

// MARK: - Board View (Kanban — HIG-Compliant)

struct BoardView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var tasks: [ProjectDerivedItem] = []
    @State private var items: [KnowledgeItem] = []
    @State private var selectedColumn = 0
    @State private var showNewTask = false
    @State private var editingTask: ProjectDerivedItem? = nil
    @State private var dropTarget: TaskStatus? = nil

    private let columns: [TaskStatus] = [.todo, .inProgress, .done, .cancelled]

    @EnvironmentObject private var services: ServiceContainer
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
                                  task.statusRaw != status.rawValue else { return false }
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

    private func taskCard(_ task: ProjectDerivedItem) -> some View {
        let priority = TaskPriority(rawValue: task.priorityRaw ?? "medium") ?? .medium
        let barColor = priorityBarColor(priority)

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

                    // Metadata row: owner + due date
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
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(dropTarget?.rawValue == task.statusRaw ? Color.green.opacity(0.5) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .draggable(task.id.uuidString)
        .contextMenu {
            Button { editingTask = task } label: { Label("Edit", systemImage: "pencil") }
            ForEach(columns, id: \.rawValue) { col in
                if col.rawValue != task.statusRaw {
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
                if col.rawValue != task.statusRaw {
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

    private func filtered(_ status: TaskStatus) -> [ProjectDerivedItem] {
        tasks.filter { $0.statusRaw == status.rawValue }
    }

    private func moveTask(_ task: ProjectDerivedItem, to status: TaskStatus) {
        let derivedStatus: ProjectDerivedStatus = {
            switch status {
            case .todo: .todo
            case .inProgress: .inProgress
            case .done: .done
            case .cancelled: .cancelled
            }
        }()
        try? services.derived.updateStatus(task, to: derivedStatus)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        loadData()
    }

    private func deleteTask(_ task: ProjectDerivedItem) {
        try? services.derived.delete(task)
        loadData()
    }

    private func loadData() {
        tasks = (try? services.derived.fetch(for: projectID, type: .task)) ?? []
        items = (try? services.projects.items(in: projectID)) ?? []
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
// DEPRECATED: Subsumed by file browser with type filter in ItemsView (2026-06-18)

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

// MARK: - Config Project Browser

/// Dedicated browser for the wawa-note-config system project.
/// Shows Providers, Prompts, Schemas, Settings, and Memories as editable sections.
struct ConfigProjectBrowserView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var providers: [AIProviderConfigModel] = []
    @State private var promptEntries: [EditablePrompt] = []
    @State private var schemaEntries: [(key: String, fw: ProjectFramework)] = []
    @State private var memoryEntries: [AgentMemory] = []
    @State private var settingsJSON: String = ""

    var body: some View {
        List {
            // Providers
            Section {
                if providers.isEmpty {
                    Text("No providers configured. Add one in Settings → AI Services.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(providers) { config in
                        HStack {
                            Image(systemName: providerIcon(for: config.typeRaw))
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.name).font(.subheadline).fontWeight(.medium)
                                Text("\(config.typeRaw) · \(config.defaultModel)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if config.supportsStreaming {
                                Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary)
                            }
                            if config.supportsTools {
                                Image(systemName: "hammer").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Label("Providers", systemImage: "brain.head.profile")
            } footer: {
                Text("Manage AI providers in Settings → AI Services.")
            }

            // Prompts
            Section {
                if promptEntries.isEmpty {
                    Text("No prompts loaded.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(promptEntries, id: \.name) { prompt in
                        NavigationLink {
                            ConfigPromptEditorView(promptName: prompt.name, content: prompt.content, category: prompt.category)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prompt.name.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.subheadline)
                                    Text(prompt.category)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if prompt.isUserEdited {
                                    Text("edited").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if !prompt.variables.isEmpty {
                                    Text("\(prompt.variables.count) vars").font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Prompts", systemImage: "text.word.spacing")
            } footer: {
                Text("\(promptEntries.count) prompts. Edit to customize AI behavior. Changes persist to PromptStore.")
            }

            // Schemas
            Section {
                ForEach(schemaEntries, id: \.key) { entry in
                    NavigationLink {
                        ConfigSchemaViewer(framework: entry.fw)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fw.name).font(.subheadline)
                                Text(entry.fw.description)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(entry.fw.views.count) views")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("Schemas", systemImage: "square.grid.3x3")
            } footer: {
                Text("Analysis frameworks define output structure for each domain. \(schemaEntries.count) built-in.")
            }

            // Settings
            Section {
                NavigationLink {
                    ConfigSettingsJSONView(json: settingsJSON)
                } label: {
                    HStack {
                        Label("App Settings", systemImage: "gearshape.fill")
                        Spacer()
                        Text("\(settingsJSON.count) bytes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }

            // Memories
            Section {
                if memoryEntries.isEmpty {
                    Text("No agent memories yet. The agent learns from processing content.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(memoryEntries) { mem in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mem.pattern).font(.subheadline).lineLimit(1)
                                Text(mem.strategy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if mem.isStale {
                                Text("stale").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.red.opacity(0.15)).clipShape(Capsule())
                            }
                            Text("\(Int(mem.relevance * 100))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("Memories", systemImage: "memories")
            } footer: {
                Text("Agent memories are learned patterns. Stale memories (>3 failures) are excluded from search.")
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
        .refreshable { loadData() }
    }

    private func loadData() {
        let context = modelContext
        providers = (try? context.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []
        promptEntries = PromptStore.shared.prompts(in: nil)
        schemaEntries = FrameworkService.allBuiltInFrameworks.map { ($0.key, $0.value) }
            .sorted { $0.fw.name < $1.fw.name }
        memoryEntries = AgentMemoryStore.shared.listAll()
        settingsJSON = buildSettingsJSON()
    }

    private func buildSettingsJSON() -> String {
        let snapshot = ConfigProjectService.buildSettingsSnapshot()
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func providerIcon(for type: String) -> String {
        switch type {
        case "openAI": "brain.head.profile"
        case "anthropic": "sparkles"
        case "gemini": "circle.hexagongrid"
        default: "desktopcomputer"
        }
    }
}

// MARK: - Config Prompt Editor

struct ConfigPromptEditorView: View {
    let promptName: String
    @State private var content: String
    let category: String
    @State private var hasChanges = false
    @Environment(\.dismiss) private var dismiss

    init(promptName: String, content: String, category: String) {
        self.promptName = promptName
        self._content = State(initialValue: content)
        self.category = category
    }

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        VStack(spacing: 0) {
            // Header info
            VStack(alignment: .leading, spacing: 4) {
                Text(promptName.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.headline)
                Text("Category: \(category)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            // Editor
            TextEditor(text: $content)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .onChange(of: content) { _, _ in hasChanges = true }
        }
        .navigationTitle("Edit Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasChanges {
                    Button("Save") {
                        PromptStore.shared.updatePrompt(named: promptName, content: content)
                        hasChanges = false
                    }
                    .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if hasChanges {
                    Button("Reset") {
                        PromptStore.shared.resetPrompt(named: promptName)
                        content = PromptStore.shared.prompt(named: promptName)?.content ?? ""
                        hasChanges = false
                    }
                }
            }
        }
    }
}

// MARK: - JSON Tree View (Recursive, interactive)

/// Interactive JSON tree with expand/collapse for objects and arrays.
struct JSONTreeView: View {
    let json: String
    let title: String

    var body: some View {
        Group {
            if let data = json.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                List {
                    JSONNodeView(key: nil, value: parsed)
                }
            } else {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Recursive node that renders any JSON value.
struct JSONNodeView: View {
    let key: String?
    let value: Any

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        switch value {
        case let dict as [String: Any]:
            JSONObjectView(key: key, dict: dict)
        case let array as [Any]:
            JSONArrayView(key: key, array: array)
        case let str as String:
            JSONLeafView(key: key, value: str, color: .green)
        case let num as NSNumber:
            JSONLeafView(key: key, value: num.stringValue, color: .blue)
        case let bool as Bool:
            JSONLeafView(key: key, value: bool ? "true" : "false", color: .orange)
        case is NSNull:
            JSONLeafView(key: key, value: "null", color: .gray)
        default:
            JSONLeafView(key: key, value: "\(value)", color: .primary)
        }
    }
}

// MARK: - JSON Object View

struct JSONObjectView: View {
    let key: String?
    let dict: [String: Any]
    @State private var isExpanded = true

    private var sortedKeys: [String] { dict.keys.sorted() }

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        if let key {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(sortedKeys, id: \.self) { k in
                    JSONNodeView(key: k, value: dict[k] ?? NSNull())
                        .padding(.leading, 12)
                }
            } label: {
                HStack {
                    Text(key).font(.subheadline).fontWeight(.semibold).foregroundStyle(.purple)
                    Spacer()
                    Text("{ \(sortedKeys.count) }").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            // Root object — no key, always expanded
            ForEach(sortedKeys, id: \.self) { k in
                JSONNodeView(key: k, value: dict[k] ?? NSNull())
            }
        }
    }
}

// MARK: - JSON Array View

struct JSONArrayView: View {
    let key: String?
    let array: [Any]
    @State private var isExpanded = false

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(0..<array.count, id: \.self) { idx in
                JSONNodeView(key: "[\(idx)]", value: array[idx])
                    .padding(.leading, 12)
            }
        } label: {
            HStack {
                if let key {
                    Text(key).font(.subheadline).fontWeight(.semibold).foregroundStyle(.blue)
                }
                Spacer()
                Text("[ \(array.count) ]").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - JSON Leaf Value

struct JSONLeafView: View {
    let key: String?
    let value: String
    let color: Color

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        HStack(alignment: .top) {
            if let key {
                Text(key).font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
            }
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Config Settings JSON Viewer

struct ConfigSettingsJSONView: View {
    let json: String

    var body: some View {
        JSONTreeView(json: json, title: "App Settings")
    }
}

// MARK: - Config Schema Viewer

struct ConfigSchemaViewer: View {
    let framework: ProjectFramework
    @State private var schemaJSON: String = ""
    @State private var expandedSection: String? = nil

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        List {
            // Header
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(framework.name).font(.title2).fontWeight(.bold)
                    Text(framework.description).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            // Entity Kinds
            if !framework.entityKinds.isEmpty {
                Section {
                    ForEach(framework.entityKinds, id: \.self) { kind in
                        Label(kind, systemImage: "cube").font(.subheadline)
                    }
                } header: {
                    Text("Entity Kinds (\(framework.entityKinds.count))")
                }
            }

            // Edge Types
            if !framework.edgeTypes.isEmpty {
                Section {
                    ForEach(framework.edgeTypes, id: \.self) { edge in
                        Label(edge, systemImage: "arrow.triangle.branch").font(.subheadline)
                    }
                } header: {
                    Text("Edge Types (\(framework.edgeTypes.count))")
                }
            }

            // Views
            if !framework.views.isEmpty {
                Section {
                    ForEach(framework.views, id: \.id) { view in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(view.title).font(.subheadline)
                                Spacer()
                                Text(view.type.rawValue).font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(.systemGray5)).clipShape(Capsule())
                            }
                            Text("Source: \(view.source)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Views (\(framework.views.count))")
                }
            }

            // Item Analysis
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt").font(.caption).foregroundStyle(.secondary)
                    Text(framework.itemAnalysis.systemPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(5)
                }
            } header: {
                Text("Item Analysis")
            }

            // Output Schema — interactive tree
            Section {
                if !schemaJSON.isEmpty,
                   let data = schemaJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    JSONNodeView(key: nil, value: parsed)
                }
            } header: {
                Text("Output Schema")
            }

            // Field Renderers
            if !framework.itemAnalysis.renderAs.isEmpty {
                Section {
                    ForEach(framework.itemAnalysis.renderAs, id: \.field) { renderer in
                        HStack {
                            Image(systemName: renderer.icon ?? "doc")
                                .foregroundStyle(.secondary)
                            Text(renderer.title).font(.subheadline)
                            Spacer()
                            Text(renderer.type.rawValue).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(.systemGray5)).clipShape(Capsule())
                        }
                    }
                } header: {
                    Text("Field Renderers")
                }
            }
        }
        .navigationTitle("Schema")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let data = try? JSONEncoder().encode(framework.itemAnalysis.outputSchema),
               let json = String(data: data, encoding: .utf8) {
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
                    schemaJSON = String(data: pretty, encoding: .utf8) ?? json
                } else {
                    schemaJSON = json
                }
            }
        }
    }
}

// MARK: - Document Scanner (VisionKit wrapper)


// MARK: - Project Synthesis Views

/// Renders the project's synthesis document with actionable primitives.
struct ProjectSynthesisView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var synthesis: ProjectDerivedItem?
    @State private var derivedItems: [ProjectDerivedItem] = []
    @State private var isLoading = true

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading synthesis...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { loadData() }
            } else if let synthesis {
                ScrollView {
                    SynthesisContentView(synthesis: synthesis, derivedItems: derivedItems, projectID: project.id)
                }
                .refreshable { loadData() }
            } else {
                EmptySynthesisView(project: project)
            }
        }
    }

    @MainActor
    private func loadData() {
        let svc = services.derived
        synthesis = try? svc.fetchSynthesis(for: project.id).first
        derivedItems = (try? svc.fetch(for: project.id)) ?? []
        isLoading = false
    }
}

/// Renders the synthesis body content as typed cards (KAN-255).
struct SynthesisContentView: View {
    let synthesis: ProjectDerivedItem
    let derivedItems: [ProjectDerivedItem]
    let projectID: UUID

    var body: some View {
        if let bodyJSON = synthesis.bodyJSON,
           let data = bodyJSON.data(using: .utf8),
           let body = try? JSONDecoder().decode(SynthesisBody.self, from: data) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !body.metrics.isEmpty {
                        MetricsStripView(metrics: body.metrics)
                    }
                    ForEach(body.sections.sorted(by: { $0.order < $1.order }), id: \.id) { section in
                        let render = section.renderType.lowercased().trimmingCharacters(in: .whitespaces)
                        if render != "metrics" && render != "metric" {
                            SectionCardView(section: section)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("Synthesis pending...")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}

// MARK: - Synthesis Card Views (KAN-255)

struct MetricsStripView: View {
    let metrics: [SynthesisMetric]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(metrics, id: \.id) { metric in
                    MetricPill(metric: metric)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct MetricPill: View {
    let metric: SynthesisMetric

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let icon = metric.icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(formatted).font(.title3).fontWeight(.bold)
            }
            Text(metric.label).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(statusColor.opacity(0.3), lineWidth: 1))
    }

    /// LLM-variation-proof: case-insensitive, aliases for common LLM outputs.
    private var formatted: String {
        let f = metric.format.lowercased()
        switch f {
        case "percentage", "percent", "pct", "%": return String(format: "%.0f%%", metric.value * 100)
        case "days", "day", "dias", "jours": return "\(Int(metric.value))d"
        case "score", "pontuacao", "pontuação", "note": return String(format: "%.0f", metric.value)
        case "count", "number", "contagem", "nombre": return metric.value >= 100 ? "\(Int(metric.value))" : String(format: "%.1f", metric.value)
        default: return metric.value >= 100 ? "\(Int(metric.value))" : String(format: "%.1f", metric.value)
        }
    }

    /// LLM-variation-proof: case-insensitive, aliases for common LLM outputs.
    private var statusColor: Color {
        let s = metric.status.lowercased()
        switch s {
        case "healthy", "ok", "good", "green", "saudavel", "saudável", "bon", "sain":
            return .green
        case "warning", "warn", "attention", "yellow", "atencao", "atenção", "orange":
            return .orange
        case "critical", "crit", "danger", "red", "error", "critico", "crítico", "critique":
            return .red
        default:
            return .secondary
        }
    }
}

struct SectionCardView: View {
    let section: SynthesisSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: sectionIcon).font(.caption).foregroundStyle(sectionColor)
                Text(section.title).font(.headline)
            }
            /// LLM-variation-proof: case-insensitive renderType dispatch.
            let render = section.renderType.lowercased().trimmingCharacters(in: .whitespaces)
            switch render {
            case "cards", "table", "timeline", "card", "tabela", "tableau", "tabla":
                Text(section.content).font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            default:
                Text(.init(section.content)).font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    /// LLM-variation-proof: matches across English, Portuguese, Spanish, French, German, Italian.
    private var sectionIcon: String {
        let t = canonicalTopic
        if t == "summary" { return "doc.text.fill" }
        if t == "topic" || t == "theme" { return "tag.fill" }
        if t == "risk" { return "exclamationmark.triangle.fill" }
        if t == "task" || t == "action" { return "checklist" }
        if t == "decision" { return "checkmark.shield.fill" }
        if t == "insight" { return "lightbulb.fill" }
        if t == "action" || t == "next_step" { return "bolt.fill" }
        if t == "question" { return "questionmark.circle.fill" }
        if t == "entity" || t == "person" { return "person.2.fill" }
        return "doc.text"
    }

    /// LLM-variation-proof: matches across English, Portuguese, Spanish, French, German, Italian.
    private var sectionColor: Color {
        let t = canonicalTopic
        if t == "risk" { return .red }
        if t == "task" || t == "action" { return .blue }
        if t == "decision" { return .green }
        if t == "topic" || t == "theme" { return .purple }
        if t == "insight" { return .orange }
        if t == "summary" { return .primary }
        if t == "question" { return .yellow }
        return .secondary
    }

    /// Normalizes a section title to a canonical topic key, handling multilingual
    /// LLM outputs. Returns the canonical English topic name.
    private var canonicalTopic: String {
        let t = section.title.lowercased().trimmingCharacters(in: .whitespaces)
        // Summary
        if t.contains("summary") || t.contains("resumo") || t.contains("résumé") || t.contains("zusammenfassung") || t.contains("sommario") || t.contains("resumen") { return "summary" }
        // Topic / Theme
        if t.contains("topic") || t.contains("tópico") || t.contains("theme") || t.contains("thème") || t.contains("thema") || t.contains("tema") || t.contains("sujet") { return "topic" }
        // Risk
        if t.contains("risk") || t.contains("risco") || t.contains("risque") || t.contains("risiko") || t.contains("riesgo") || t.contains("rischio") { return "risk" }
        // Task / Action
        if t.contains("task") || t.contains("tarefa") || t.contains("tâche") || t.contains("aufgabe") || t.contains("tarea") || t.contains("azione") { return "task" }
        // Decision
        if t.contains("decision") || t.contains("decisão") || t.contains("décision") || t.contains("entscheidung") || t.contains("decisión") || t.contains("decisione") { return "decision" }
        // Insight
        if t.contains("insight") || t.contains("insight") || t.contains("aperçu") || t.contains("erkenntnis") || t.contains("intuizione") || t.contains("cross") || t.contains("cruzado") { return "insight" }
        // Action / Next Step
        if t.contains("action") || t.contains("ação") || t.contains("accion") || t.contains("azione") || t.contains("next step") || t.contains("próximo") || t.contains("proximo") || t.contains("suivant") || t.contains("siguiente") { return "action" }
        // Question
        if t.contains("question") || t.contains("questão") || t.contains("questao") || t.contains("pergunta") || t.contains("frage") || t.contains("pregunta") || t.contains("domanda") { return "question" }
        // Entity / Person
        if t.contains("entity") || t.contains("entidade") || t.contains("entité") || t.contains("entität") || t.contains("person") || t.contains("pessoa") || t.contains("personne") { return "entity" }
        return "unknown"
    }
}

/// Shown when no synthesis exists yet.
struct EmptySynthesisView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext

    @EnvironmentObject private var services: ServiceContainer
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No synthesis yet")
                .font(.headline)
            Text("The Project Agent generates a synthesis once items are added and analyzed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // Check if there are items to process
            let items = (try? services.projects.items(in: project.id)) ?? []
            if items.isEmpty {
                Text("Add items to this project to get started.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button("Generate Synthesis") {
                    Task {
                        let agent = ProjectAgent(projectID: project.id, context: modelContext)
                        do {
                            _ = try await agent.generateSynthesis()
                        } catch {
                            AppLog.general.error("Failed to generate synthesis: \(error)")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }
}
