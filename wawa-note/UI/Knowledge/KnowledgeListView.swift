import SwiftUI
import SwiftData

struct KnowledgeListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var filterType: KnowledgeItemType?
    @State private var searchText = ""
    @State private var selectedFolderID: UUID?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var filterToday = false
    @State private var filterThisWeek = false
    @State private var filterFlagged = false
    @State private var filterHasAudio = false
    @State private var trashFolderID: UUID?
    @State private var showNoteEditor = false
    @State private var showJournalEditor = false
    @State private var showFolderAlert = false
    @State private var searchResults: [SearchResult] = []
    @State private var matchingItemIDs: Set<UUID> = []

    var body: some View {
        Group {
        if allItems.isEmpty && folders.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Explore is empty")
                    .font(.title3).fontWeight(.medium)
                Text("Record a meeting, create a note, or import an audio file to start building your library.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { showNoteEditor = true } label: {
                    Label("Create First Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        } else {
        List {
            // Folder tree
            Section("Folders") {
                ForEach(rootFolders) { folder in
                    FolderRow(folder: folder, allFolders: folders, selectedID: $selectedFolderID)
                }
                if rootFolders.isEmpty {
                    Text("No folders yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Quick type filters
            Section("By Type") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(KnowledgeItemType.allCases, id: \.self) { type in
                            Button {
                                filterType = (filterType == type) ? nil : type
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: type.icon)
                                        .font(.caption)
                                    Text(type.label)
                                        .font(.caption).fontWeight(.medium)
                                }
                                .foregroundStyle(filterType == type ? .white : type.color)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    filterType == type
                                    ? type.color
                                    : type.color.opacity(0.1)
                                )
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            // Smart Filters
            Section("Quick Filters") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        smartFilterChip(label: "Today", icon: "calendar", active: filterToday) {
                            filterToday.toggle()
                        }
                        smartFilterChip(label: "This Week", icon: "calendar.badge.clock", active: filterThisWeek) {
                            filterThisWeek.toggle()
                        }
                        smartFilterChip(label: "Flagged", icon: "flag", active: filterFlagged) {
                            filterFlagged.toggle()
                        }
                        smartFilterChip(label: "Has Audio", icon: "mic", active: filterHasAudio) {
                            filterHasAudio.toggle()
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            // Items
            Section {
                if isViewingTrash && !filteredItems.isEmpty {
                    Button(role: .destructive) {
                        let trash = TrashService(context: modelContext)
                        try? trash.deleteAllInTrash()
                    } label: {
                        Label("Delete All", systemImage: "trash.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.vertical, 8)
                }

                if filteredItems.isEmpty {
                    Text("No items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredItems) { item in
                    NavigationLink {
                        KnowledgeDetailView(item: item)
                    } label: {
                        KnowledgeItemRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        if isViewingTrash {
                            Button {
                                let trash = TrashService(context: modelContext)
                                try? trash.restore(item)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                let svc = KnowledgeItemService(context: modelContext)
                                try? svc.deleteItem(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) {
                                let trash = TrashService(context: modelContext)
                                try? trash.moveToTrash(item)
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(sectionHeader)
            }
        }
        } // end if-else
        } // end Group
        .navigationTitle("Explore")
        .searchable(text: $searchText)
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                matchingItemIDs = []
                searchResults = []
            } else {
                let service = SearchService()
                searchResults = service.searchNow(query: newValue, in: allItems)
                matchingItemIDs = Set(searchResults.map(\.itemID))
            }
        }
        .onAppear {
            let trash = try? TrashService(context: modelContext).trashFolder()
            trashFolderID = trash?.id
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    NavigationLink {
                        ConnectionsFeedView()
                    } label: {
                        Image(systemName: "circle.hexagonpath")
                    }

                    Menu {
                        Button { showNoteEditor = true } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                        Button { showJournalEditor = true } label: {
                            Label("New Journal", systemImage: "book")
                        }
                        Button { showFolderAlert = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            NoteEditorView(mode: .create(type: .note, folderID: selectedFolderID, initialTag: nil))
        }
        .sheet(isPresented: $showJournalEditor) {
            JournalEditorView(mode: .create(folderID: selectedFolderID))
        }
        .alert("New Folder", isPresented: $showFolderAlert) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    private var rootFolders: [Folder] {
        let roots = folders.filter { $0.parentFolderID == nil }
        // Trash always last
        let trash = roots.filter { $0.name == "Trash" && $0.iconName == "trash" }
        let others = roots.filter { !($0.name == "Trash" && $0.iconName == "trash") }
        return others + trash
    }

    private var isViewingTrash: Bool {
        guard let fid = selectedFolderID, let f = folders.first(where: { $0.id == fid }) else { return false }
        return f.name == "Trash" && f.iconName == "trash"
    }

    private var sectionHeader: String {
        if let type = filterType { return typeLabel(for: type) + "s" }
        if let fid = selectedFolderID, let f = folders.first(where: { $0.id == fid }) { return f.name }
        return "All Items"
    }

    private var filteredItems: [KnowledgeItem] {
        var result = allItems
        if let type = filterType {
            result = result.filter { $0.type == type }
        }
        if let folderID = selectedFolderID {
            result = result.filter { $0.folderID == folderID }
        } else if let trashID = trashFolderID {
            result = result.filter { $0.folderID != trashID }
        }
        if filterToday {
            let cal = Calendar.current
            result = result.filter { cal.isDateInToday($0.createdAt) }
        }
        if filterThisWeek {
            let cal = Calendar.current
            if let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) {
                result = result.filter { $0.createdAt >= weekStart }
            }
        }
        if filterFlagged {
            result = result.filter { $0.isFlagged }
        }
        if filterHasAudio {
            result = result.filter { $0.audioFileRelativePath != nil }
        }
        if !searchText.isEmpty && !matchingItemIDs.isEmpty {
            result = result.filter { matchingItemIDs.contains($0.id) }
        }
        return result
    }

    private func createFolder() {
        guard !newFolderName.isEmpty else { return }
        let folder = Folder(name: newFolderName, parentFolderID: selectedFolderID)
        modelContext.insert(folder)
        try? modelContext.save()
        newFolderName = ""
    }

    private func smartFilterChip(label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.blue : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(active ? .white : .primary)
                .clipShape(Capsule())
        }
    }

    private func typeIcon(for type: KnowledgeItemType) -> String { type.icon }
    private func typeColor(for type: KnowledgeItemType) -> Color { type.color }
    private func typeLabel(for type: KnowledgeItemType) -> String { type.label }
}

// MARK: - Folder Row

private struct FolderRow: View {
    let folder: Folder
    let allFolders: [Folder]
    @Binding var selectedID: UUID?

    private var children: [Folder] {
        allFolders.filter { $0.parentFolderID == folder.id }
    }

    private var isTrash: Bool { folder.name == "Trash" && folder.iconName == "trash" }

    var body: some View {
        if children.isEmpty {
            Button { selectedID = folder.id } label: {
                Label(folder.name, systemImage: folder.iconName ?? "folder")
            }
            .foregroundStyle(isTrash ? .red : .primary)
        } else {
            DisclosureGroup {
                ForEach(children) { child in
                    FolderRow(folder: child, allFolders: allFolders, selectedID: $selectedID)
                }
            } label: {
                Button { selectedID = folder.id } label: {
                    Label(folder.name, systemImage: folder.iconName ?? "folder")
                }
                .foregroundStyle(isTrash ? .red : .primary)
            }
        }
    }
}

// MARK: - Item Row

private struct KnowledgeItemRow: View {
    let item: KnowledgeItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if let d = item.durationSeconds {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(formatDuration(d)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if item.isFlagged {
                Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String { item.type.icon }
    private var color: Color { item.type.color }
    private var label: String { item.type.label }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
