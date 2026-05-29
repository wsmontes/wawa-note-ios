import SwiftUI
import SwiftData

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var inboxItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var showFolderPicker: KnowledgeItem? = nil
    @State private var selectedFolderID: UUID?

    init() {
        _inboxItems = Query(
            filter: #Predicate { $0.inboxDate != nil },
            sort: \KnowledgeItem.inboxDate, order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if inboxItems.isEmpty {
                    emptyInbox
                } else {
                    List {
                        todaySection
                        suggestionsSection
                        reviewSection
                    }
                }
            }
            .navigationTitle("Inbox")
            .sheet(item: $showFolderPicker) { item in
                folderPickerSheet(for: item)
            }
        }
    }

    // MARK: - Empty

    private var emptyInbox: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Inbox is empty")
                .font(.title3).fontWeight(.medium)
            Text("New notes, ideas, and captures will appear here for you to review and organize.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var todaySection: some View {
        let today = todayItems
        if !today.isEmpty {
            Section("New today") {
                ForEach(today) { item in
                    inboxRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggested = suggestedItems
        if !suggested.isEmpty {
            Section("AI Suggestions") {
                ForEach(suggested) { item in
                    inboxRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        let older = reviewItems
        if !older.isEmpty {
            Section("Under review") {
                ForEach(older) { item in
                    inboxRow(item)
                }
            }
        }
    }

    private func inboxRow(_ item: KnowledgeItem) -> some View {
        NavigationLink {
            KnowledgeDetailView(item: item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.type.icon)
                    .font(.title3)
                    .foregroundStyle(item.type.color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.body).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.type.label).font(.caption).foregroundStyle(.secondary)
                        if let inboxDate = item.inboxDate {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(inboxDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .leading) {
            Button {
                archiveItem(item)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                showFolderPicker = item
            } label: {
                Label("Move", systemImage: "folder")
            }
            .tint(.blue)

            Button(role: .destructive) {
                discardItem(item)
            } label: {
                Label("Discard", systemImage: "trash")
            }
        }
    }

    // MARK: - Computed filters

    private var todayItems: [KnowledgeItem] {
        inboxItems.filter {
            guard let d = $0.inboxDate else { return false }
            return Calendar.current.isDateInToday(d)
        }
    }

    private var suggestedItems: [KnowledgeItem] {
        inboxItems.filter { item in
            // Items with AI-detected tags or flagged for attention, excluding today's items
            guard let d = item.inboxDate, !Calendar.current.isDateInToday(d) else { return false }
            return !item.tags.isEmpty || item.isFlagged
        }
    }

    private var reviewItems: [KnowledgeItem] {
        inboxItems.filter { item in
            // Items in inbox more than 1 day without AI suggestions
            guard let d = item.inboxDate, !Calendar.current.isDateInToday(d) else { return false }
            return item.tags.isEmpty && !item.isFlagged
        }
    }

    // MARK: - Actions

    private func archiveItem(_ item: KnowledgeItem) {
        let service = KnowledgeItemService(context: modelContext)
        try? service.removeFromInbox(item)
    }

    private func discardItem(_ item: KnowledgeItem) {
        let trash = TrashService(context: modelContext)
        try? trash.moveToTrash(item)
    }

    private func moveItem(_ item: KnowledgeItem, to folderID: UUID?) {
        let service = KnowledgeItemService(context: modelContext)
        try? service.moveToFolder(item, folderID: folderID)
    }

    // MARK: - Folder picker sheet

    private func folderPickerSheet(for item: KnowledgeItem) -> some View {
        NavigationStack {
            List {
                Button {
                    moveItem(item, to: nil)
                    showFolderPicker = nil
                } label: {
                    Label("No folder (remove from inbox)", systemImage: "tray")
                }

                ForEach(folders.filter { !$0.isTrash }) { folder in
                    Button {
                        moveItem(item, to: folder.id)
                        showFolderPicker = nil
                    } label: {
                        Label(folder.name, systemImage: folder.iconName ?? "folder")
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
}

private extension Folder {
    var isTrash: Bool { name == "Trash" && iconName == "trash" }
}
