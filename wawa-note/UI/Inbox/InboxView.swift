import SwiftUI
import SwiftData

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var searchText = ""
    @State private var filterMode: InboxFilter = .needsReview
    @State private var showFolderPicker: KnowledgeItem? = nil
    @State private var searchResults: [SearchResult] = []
    @State private var matchingIDs: Set<UUID> = []
    @State private var trashFolderID: UUID?
    @State private var navigateToProject: Project?

    private let searchService = SearchService()

    enum InboxFilter: String, CaseIterable {
        case needsReview = "Needs Review"
        case all = "All"
        case unassigned = "Unassigned"
        case flagged = "Flagged"
        case trash = "Trash"

        var icon: String {
            switch self {
            case .needsReview: "tray"
            case .all: "tray.full"
            case .unassigned: "questionmark.folder"
            case .flagged: "flag"
            case .trash: "trash"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if filteredItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .navigationTitle("Inbox")
            .navigationDestination(item: $navigateToProject) { ProjectDetailView(project: $0) }
            .searchable(text: $searchText, prompt: "Search all sources...")
            .onChange(of: searchText) { _, newValue in
                if newValue.isEmpty { matchingIDs = []; searchResults = [] }
                else { performSearch() }
            }
            .onAppear { loadTrashFolder() }
            .sheet(item: $showFolderPicker) { item in
                folderPickerSheet(for: item)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation { filterMode = filter }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filter.icon)
                                .font(.caption)
                            Text(filter.rawValue)
                                .font(.subheadline).fontWeight(.medium)
                            if filter == .needsReview {
                                Text("\(needsReviewCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(filterMode == filter ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(filterMode == filter ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Item list

    private var itemList: some View {
        List {
            ForEach(groupedItems, id: \.0) { header, items in
                Section {
                    ForEach(items) { item in
                        NavigationLink {
                            KnowledgeDetailView(item: item)
                        } label: {
                            inboxRow(item)
                        }
                        .swipeActions(edge: .leading) {
                            if filterMode == .trash {
                                Button { try? TrashService(context: modelContext).restore(item) } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }.tint(.green)
                            } else {
                                Button { archiveItem(item) } label: {
                                    Label("Mark Reviewed", systemImage: "checkmark.circle")
                                }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button { showFolderPicker = item } label: {
                                Label("Move to Project", systemImage: "folder.badge.plus")
                            }.tint(.blue)
                            Button(role: .destructive) { discardItem(item) } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(header)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func inboxRow(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.type.icon)
                .font(.title3)
                .foregroundStyle(item.type.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.body).lineLimit(1)
                    .foregroundStyle(item.inboxDate != nil ? .primary : .secondary)

                HStack(spacing: 6) {
                    Text(item.type.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = item.durationSeconds {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(formatDuration(duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if item.inboxDate != nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text("Unprocessed")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if item.transcriptionEngineId != nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text("Transcribed")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if item.analysisProviderId != nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text("Analyzed")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if item.audioFileRelativePath == nil && item.bodyText == nil && item.transcriptionEngineId == nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text("No audio")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                }

                // Project badge
                if let projectID = item.projectID, let project = projects.first(where: { $0.id == projectID }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                            .foregroundStyle(.brown)
                        Text(project.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Calendar context
                if let cal = item.contextCalendarEventTitle {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(cal)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(filterMode == .needsReview ? "All caught up" : "No items")
                .font(.title3).fontWeight(.medium)
            Text(emptyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var emptyDescription: String {
        switch filterMode {
        case .needsReview: "Everything is reviewed. New captures and imports will appear here."
        case .all: "No source items yet. Start recording, importing, or creating a note."
        case .unassigned: "All items are assigned to a project. Nice work."
        case .flagged: "No flagged items. Flag items to mark them for follow-up."
        case .trash: "Trash is empty."
        }
    }

    // MARK: - Computed

    private var filteredItems: [KnowledgeItem] {
        var result = allItems

        // Exclude trash unless viewing trash
        if filterMode != .trash, let trashID = trashFolderID {
            result = result.filter { $0.folderID != trashID }
        }
        if filterMode == .trash, let trashID = trashFolderID {
            result = result.filter { $0.folderID == trashID }
        }

        // Full-text search via SearchService
        if !searchText.isEmpty {
            if matchingIDs.isEmpty { result = [] }
            else { result = result.filter { matchingIDs.contains($0.id) } }
        }

        switch filterMode {
        case .needsReview: result = result.filter { $0.inboxDate != nil }
        case .all, .trash: break
        case .unassigned: result = result.filter { $0.projectID == nil && $0.folderID == nil }
        case .flagged: result = result.filter { $0.isFlagged }
        }

        return result
    }

    private func performSearch() {
        guard !searchText.isEmpty else {
            matchingIDs = []
            searchResults = []
            return
        }
        searchResults = searchService.searchNow(query: searchText, in: allItems)
        matchingIDs = Set(searchResults.map(\.itemID))
    }

    private var groupedItems: [(String, [KnowledgeItem])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today

        var todayItems: [KnowledgeItem] = []
        var yesterdayItems: [KnowledgeItem] = []
        var thisWeekItems: [KnowledgeItem] = []
        var olderItems: [KnowledgeItem] = []

        for item in filteredItems {
            let itemDay = cal.startOfDay(for: item.updatedAt)
            if itemDay == today {
                todayItems.append(item)
            } else if itemDay == yesterday {
                yesterdayItems.append(item)
            } else if itemDay >= weekStart {
                thisWeekItems.append(item)
            } else {
                olderItems.append(item)
            }
        }

        var groups: [(String, [KnowledgeItem])] = []
        if !todayItems.isEmpty { groups.append(("Today", todayItems)) }
        if !yesterdayItems.isEmpty { groups.append(("Yesterday", yesterdayItems)) }
        if !thisWeekItems.isEmpty { groups.append(("This Week", thisWeekItems)) }
        if !olderItems.isEmpty { groups.append(("Older", olderItems)) }

        return groups
    }

    private var needsReviewCount: Int {
        allItems.filter { $0.inboxDate != nil }.count
    }

    // MARK: - Actions

    private func archiveItem(_ item: KnowledgeItem) {
        let service = KnowledgeItemService(context: modelContext)
        try? service.removeFromInbox(item)
    }

    private func loadTrashFolder() {
        trashFolderID = (try? TrashService(context: modelContext).trashFolder())?.id
    }

    private func discardItem(_ item: KnowledgeItem) {
        let trash = TrashService(context: modelContext)
        try? trash.moveToTrash(item)
    }

    // MARK: - Folder picker

    private func folderPickerSheet(for item: KnowledgeItem) -> some View {
        NavigationStack {
            List {
                Section("Projects") {
                    ForEach(projects) { project in
                        Button {
                            assignToProject(item, project: project)
                            showFolderPicker = nil
                        } label: {
                            Label(project.name, systemImage: "folder.fill")
                                .foregroundStyle(.brown)
                        }
                    }
                    if projects.isEmpty {
                        Text("No projects yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Actions") {
                    Button {
                        removeFromProject(item)
                        showFolderPicker = nil
                    } label: {
                        Label("Remove from project", systemImage: "folder.badge.minus")
                    }
                }
            }
            .navigationTitle("Move to...")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showFolderPicker = nil }
                }
            }
        }
    }

    private func assignToProject(_ item: KnowledgeItem, project: Project) {
        let itemID = item.id
        let projectID = project.id

        try? ProjectService(context: modelContext).addItem(itemID, to: projectID)
        contentPipeline.process(itemID, using: modelContext)

        showFolderPicker = nil
        navigateToProject = project
    }

    private func removeFromProject(_ item: KnowledgeItem) {
        try? ProjectService(context: modelContext).removeItem(item.id)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Color hex helper

private extension Color {
    init?(hex: String) {
        guard let color = Color(hexString: hex) else { return nil }
        self = color
    }

    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
