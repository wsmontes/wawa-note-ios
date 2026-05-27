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
    @State private var showNewNote = false
    @State private var newNoteTitle = ""
    @State private var filterToday = false
    @State private var filterThisWeek = false
    @State private var filterFlagged = false
    @State private var filterHasAudio = false

    var body: some View {
        Group {
        if allItems.isEmpty && folders.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Knowledge is empty")
                    .font(.title3).fontWeight(.medium)
                Text("Record a meeting, create a note, or import an audio file to start building your knowledge.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { createFirstNote() } label: {
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
            Section(sectionHeader) {
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
                }
            }
        }
        } // end if-else
        } // end Group
        .navigationTitle("Knowledge")
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    NavigationLink {
                        ConnectionsFeedView()
                    } label: {
                        Image(systemName: "circle.hexagonpath")
                    }

                    Menu {
                        Button { showNewFolder = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button { showNewNote = true } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("New Note", isPresented: $showNewNote) {
            TextField("Title", text: $newNoteTitle)
            Button("Create") { createNote() }
            Button("Cancel", role: .cancel) { newNoteTitle = "" }
        }
    }

    private var rootFolders: [Folder] {
        folders.filter { $0.parentFolderID == nil }
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
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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

    private func createFirstNote() {
        showNewNote = true
    }

    private func createNote() {
        guard !newNoteTitle.isEmpty else { return }
        let item = KnowledgeItem(type: .note, title: newNoteTitle, status: .draft, folderID: selectedFolderID)
        modelContext.insert(item)
        try? modelContext.save()
        newNoteTitle = ""
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

    var body: some View {
        if children.isEmpty {
            Button { selectedID = folder.id } label: {
                Label(folder.name, systemImage: folder.iconName ?? "folder")
            }
            .foregroundStyle(.primary)
        } else {
            DisclosureGroup {
                ForEach(children) { child in
                    FolderRow(folder: child, allFolders: allFolders, selectedID: $selectedID)
                }
            } label: {
                Button { selectedID = folder.id } label: {
                    Label(folder.name, systemImage: folder.iconName ?? "folder")
                }
                .foregroundStyle(.primary)
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
