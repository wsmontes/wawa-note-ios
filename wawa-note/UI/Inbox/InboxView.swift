import SwiftUI
import SwiftData
// Related JIRA: KAN-10, KAN-49, KAN-105


struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @EnvironmentObject private var processingQueue: ProcessingQueueService
    @EnvironmentObject private var chatState: ChatOverlayState
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var services: ServiceContainer
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var searchText = ""
    @State private var filterMode: InboxFilter = .needsReview
    @State private var refreshID = UUID()
    @State private var lastTrashedItem: KnowledgeItem?
    @State private var showUndoToast = false
    @State private var undoTimer: Timer?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: KnowledgeItem?
    @State private var searchTask: Task<Void, Never>?
    @State private var showFolderPicker: KnowledgeItem? = nil
    @State private var searchResults: [SearchResult] = []
    @State private var matchingIDs: Set<UUID> = []
    @State private var trashFolderID: UUID?
    @State private var showEmptyTrashConfirm = false
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
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if filteredItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }

            // Undo toast
            if showUndoToast {
                UndoToastView(
                    message: "Item moved to Trash",
                    onUndo: { undoTrash() },
                    onDismiss: { showUndoToast = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: showUndoToast)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Inbox")
        .navigationDestination(item: $navigateToProject) { ProjectDetailView(project: $0) }
        .searchable(text: $searchText, prompt: "Search all sources...")
        .toolbar {
            if filterMode == .trash {
                ToolbarItem(placement: .topBarTrailing) {
                    let count = TrashService(context: modelContext).emptyTrashItemCount()
                    if count > 0 {
                        Button(role: .destructive) { showEmptyTrashConfirm = true } label: {
                            Label("Empty Trash (\(count))", systemImage: "trash.slash")
                        }
                    }
                }
            }
        }
        .confirmationDialog("Move to Trash?", isPresented: $showDeleteConfirmation, presenting: itemToDelete) { item in
            Button("Move to Trash", role: .destructive) { discardItem(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\"\(item.title)\" will be moved to Trash. You can restore it later.")
        }
        .alert("Empty Trash?", isPresented: $showEmptyTrashConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Permanently", role: .destructive) {
                try? TrashService(context: modelContext).deleteAllInTrash()
                AppLog.event("trash", "User emptied trash: items permanently deleted")
            }
        } message: {
            let count = TrashService(context: modelContext).emptyTrashItemCount()
            Text("This will permanently delete \(count) item(s). This action cannot be undone.")
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { matchingIDs = []; searchResults = [] }
            else { performSearch() }
        }
        .onAppear { chatState.context = .inbox; chatViewModel.pregenerateGreeting(for: .inbox); loadTrashFolder() }
        .sheet(item: $showFolderPicker) { item in
            folderPickerSheet(for: item)
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
                        .contextMenu {
                            Button { archiveItem(item) } label: {
                                Label("Remove from Inbox", systemImage: "checkmark.circle")
                            }
                            Button { showFolderPicker = item } label: {
                                Label("Move to Project", systemImage: "folder.badge.plus")
                            }
                            Divider()
                            Button { shareItem(item) } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { itemToDelete = item; showDeleteConfirmation = true } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        } preview: {
                            inboxItemPreview(item)
                        }
                        .swipeActions(edge: .leading) {
                            if filterMode == .trash {
                                Button { try? TrashService(context: modelContext).restore(item) } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }.tint(.green)
                            } else {
                                Button { archiveItem(item) } label: {
                                    Label("Remove from Inbox", systemImage: "checkmark.circle")
                                }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button { showFolderPicker = item } label: {
                                Label("Move to Project", systemImage: "folder.badge.plus")
                            }.tint(.blue)
                            Button(role: .destructive) { itemToDelete = item; showDeleteConfirmation = true } label: {
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
        .id(refreshID)
        .refreshable { refreshID = UUID() }
    }

    private func transcriptionLabel(_ engineId: String) -> String {
        if engineId.contains("whisper") { return "Whisper" }
        if engineId.contains("apple-cloud") { return "Apple Cloud" }
        if engineId.contains("apple-speech") { return "On-Device" }
        return "Transcribed"
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
                    .foregroundStyle((item.inboxDate != nil && item.analysisProviderId == nil) ? .primary : .secondary)

                HStack(spacing: 6) {
                    Text(item.type.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = item.durationSeconds {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(formatDuration(duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if item.inboxDate != nil && item.analysisProviderId == nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text("Unprocessed")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if let engineId = item.transcriptionEngineId {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(transcriptionLabel(engineId))
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

    private var isSearchActive: Bool { !searchText.isEmpty }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: isSearchActive ? "magnifyingglass" : "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            if isSearchActive {
                Text("No results for \"\(searchText)\"")
                    .font(.title3).fontWeight(.medium)
                Text("Try different keywords or check the spelling.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            } else {
                Text(filterMode == .needsReview ? "All caught up" : "No items")
                    .font(.title3).fontWeight(.medium)
                Text(emptyDescription)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
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

        // Exclude config project items (providers, prompts, skills, etc.)
        let configProjectID = projects.first(where: { $0.slug == ConfigProjectService.configProjectSlug })?.id
        if let configID = configProjectID {
            result = result.filter { $0.projectID != configID }
        }

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
        case .needsReview: result = result.filter { $0.inboxDate != nil && $0.analysisProviderId == nil }
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
        var items = allItems
        // Exclude config project
        if let configID = projects.first(where: { $0.slug == ConfigProjectService.configProjectSlug })?.id {
            items = items.filter { $0.projectID != configID }
        }
        // Exclude trash
        if let trashID = trashFolderID {
            items = items.filter { $0.folderID != trashID }
        }
        return items.filter { $0.inboxDate != nil && $0.analysisProviderId == nil }.count
    }

    // MARK: - Actions

    private func archiveItem(_ item: KnowledgeItem) {
        let service = KnowledgeItemService(context: modelContext)
        try? service.removeFromInbox(item)
        WawaNoteApp.updateAppBadge(modelContext: modelContext)
        Haptics.light()
    }

    private func loadTrashFolder() {
        trashFolderID = (try? TrashService(context: modelContext).trashFolder())?.id
    }

    private func discardItem(_ item: KnowledgeItem) {
        let trash = TrashService(context: modelContext)
        try? trash.moveToTrash(item)
        Haptics.warning()
        lastTrashedItem = item
        showUndoToast = true
        undoTimer?.invalidate()
        // Struct capture is fine — timer fires once and releases the copied struct within 5s.
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                self.showUndoToast = false
                self.lastTrashedItem = nil
            }
        }
    }

    private func undoTrash() {
        guard let item = lastTrashedItem else { return }
        try? TrashService(context: modelContext).restore(item)
        Haptics.success()
        showUndoToast = false
        lastTrashedItem = nil
        undoTimer?.invalidate()
        undoTimer = nil
    }

    private func shareItem(_ item: KnowledgeItem) {
        let text = item.bodyText ?? item.title
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }

    @ViewBuilder
    private func inboxItemPreview(_ item: KnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.type.icon).foregroundStyle(item.type.color)
                Text(item.type.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(item.title).font(.headline).lineLimit(2)
            if let body = item.bodyText, !body.isEmpty {
                Text(body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding()
        .frame(width: 300)
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
                        VStack(spacing: 8) {
                            Text("No projects yet").font(.headline)
                            Text("Promote a knowledge item from the Explore tab to create your first project.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 24)
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
            .navigationTitle("Assign to Project")
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

        try? services.projects.addItem(itemID, to: projectID)
        processingQueue.enqueue(itemID: itemID, projectID: projectID, trigger: .projectAssignment)

        showFolderPicker = nil
        navigateToProject = project
    }

    private func removeFromProject(_ item: KnowledgeItem) {
        try? services.projects.removeItem(item.id)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Undo Toast

struct UndoToastView: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill").foregroundStyle(.red)
            Text(message).font(.subheadline)
            Spacer()
            Button("Undo") { onUndo() }
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.blue)
                .accessibilityLabel("Undo delete")
                .accessibilityHint("Restores the most recently trashed item")
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss undo")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
