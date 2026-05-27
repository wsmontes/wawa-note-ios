import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct HomeView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var recentItems: [KnowledgeItem]
    @Environment(\.modelContext) private var modelContext

    @State private var showRecording = false
    @State private var navigateToItem: KnowledgeItem?
    @State private var showFilePicker = false
    @State private var pendingImport: ImportPending?
    @State private var importError: String?
    @State private var showNewNote = false
    @State private var newNoteTitle = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var navigateToCalendar = false
    @State private var trashFolderID: UUID?

    private let importService = AudioImportService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    quickActionsSection
                    recordSection
                    recentSection
                }
            }
            .background(Color(.systemGroupedBackground))
            .task {
                let trash = try? TrashService(context: modelContext).trashFolder()
                trashFolderID = trash?.id
                await backfillEmbeddingsIfNeeded()
            }
            .fullScreenCover(isPresented: $showRecording) {
                RecordView(coordinator: coordinator) { item in
                    showRecording = false
                    navigateToItem = item
                }
            }
            .navigationDestination(item: $navigateToItem) { item in
                KnowledgeDetailView(item: item)
            }
            .navigationDestination(isPresented: $navigateToCalendar) {
                CalendarContainerView()
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: AudioImportService.supportedUTTypes, allowsMultipleSelection: false) { handleFilePick($0) }
            .sheet(item: $pendingImport) { item in
                ImportFormView(sourceURL: item.url, metadata: item.metadata, isFromShareExtension: item.isFromShareExtension) { knowledgeItem in
                    pendingImport = nil
                    navigateToItem = knowledgeItem
                }
            }
            .onOpenURL { handleIncomingURL($0) }
            .alert("Import Error", isPresented: .constant(importError != nil)) { Button("OK") { importError = nil } } message: { Text(importError ?? "") }
            .alert("New Note", isPresented: $showNewNote) {
                TextField("Title", text: $newNoteTitle)
                Button("Create") { createNote() }
                Button("Cancel", role: .cancel) { newNoteTitle = "" }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(.wawaSymbolGradient)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .shadow(color: .blue.opacity(0.15), radius: 12, y: 4)

            Text("Wawa Note")
                .font(.title2).fontWeight(.semibold)

            Text("Capture, organize, understand")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemGroupedBackground)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Quick Actions")

            HStack(spacing: 12) {
                quickActionCard(
                    icon: "square.and.pencil",
                    label: "New Note",
                    color: .orange
                ) { showNewNote = true }

                quickActionCard(
                    icon: "folder.badge.plus",
                    label: "New Folder",
                    color: .blue
                ) { showNewFolder = true }

                quickActionCard(
                    icon: "calendar",
                    label: "Calendar",
                    color: .red
                ) { navigateToCalendar = true }

                quickActionCard(
                    icon: "square.and.arrow.down",
                    label: "Import",
                    color: .green
                ) { showFilePicker = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func quickActionCard(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(label)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Record

    private var recordSection: some View {
        VStack(spacing: 0) {
            Button {
                showRecording = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                    Text("Record Meeting")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(
                        colors: [.red, .red.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let displayable = recentItems.filter { item in
                (!item.title.isEmpty || item.audioFileRelativePath != nil || item.bodyText != nil)
                && item.folderID != trashFolderID
            }

            if !displayable.isEmpty {
                sectionLabel("Recent")
                    .padding(.horizontal, 20)

                VStack(spacing: 0) {
                    ForEach(Array(displayable.prefix(8).enumerated()), id: \.element.id) { idx, item in
                        NavigationLink {
                            KnowledgeDetailView(item: item)
                        } label: {
                            recentRow(item)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                let trash = TrashService(context: modelContext)
                                try? trash.moveToTrash(item)
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }

                        if idx < min(displayable.count, 8) - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                NavigationLink {
                    NavigationStack { KnowledgeListView() }
                } label: {
                    HStack {
                        Text("See all in Knowledge")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 40)
    }

    private func recentRow(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.icon)
                .font(.title3)
                .foregroundStyle(item.type.color)
                .frame(width: 32, height: 32)
                .background(item.type.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if item.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Actions

    private func icon(for type: KnowledgeItemType) -> String { type.icon }
    private func color(for type: KnowledgeItemType) -> Color { type.color }

    private func createNote() {
        guard !newNoteTitle.isEmpty else { return }
        let item = KnowledgeItem(type: .note, title: newNoteTitle, status: .draft)
        modelContext.insert(item)
        try? modelContext.save()
        newNoteTitle = ""
        navigateToItem = item
    }

    private func createFolder() {
        guard !newFolderName.isEmpty else { return }
        let folder = Folder(name: newFolderName)
        modelContext.insert(folder)
        try? modelContext.save()
        newFolderName = ""
    }

    // MARK: - File picker

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { importError = "No file was selected."; return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard importService.canRead(url: url) else { importError = "Format not supported."; return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do { try FileManager.default.copyItem(at: url, to: tempURL) } catch { importError = error.localizedDescription; return }
            Task {
                do {
                    let metadata = try await importService.extractMetadata(url: tempURL)
                    await MainActor.run { pendingImport = ImportPending(url: tempURL, metadata: metadata, isFromShareExtension: false) }
                } catch { await MainActor.run { importError = error.localizedDescription } }
            }
        case .failure(let e): importError = e.localizedDescription
        }
    }

    // MARK: - Embedding backfill

    private func backfillEmbeddingsIfNeeded() async {
        let backfillKey = "embedding_backfill_completed"
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }

        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              let provider = try? ProviderRouter().provider(for: config) else { return }

        let allItems = (try? modelContext.fetch(FetchDescriptor<KnowledgeItem>())) ?? []
        let pipeline = EmbeddingPipelineService()
        let missing = pipeline.missingEmbeddingCount(items: allItems)

        guard missing > 0 else {
            UserDefaults.standard.set(true, forKey: backfillKey)
            return
        }

        await pipeline.backfillAll(items: allItems, using: provider) { done, total in
            if done == total {
                UserDefaults.standard.set(true, forKey: backfillKey)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "wawanote" else { return }
        let shared = UserDefaults(suiteName: "group.com.wawa-note")
        guard let filename = shared?.string(forKey: "pendingImportFile") else { return }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else { importError = "Could not access shared storage."; return }
        let fileURL = containerURL.appendingPathComponent("shared").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { importError = "Shared file no longer available."; shared?.removeObject(forKey: "pendingImportFile"); return }
        guard importService.canRead(url: fileURL) else { importError = "Format not supported."; try? FileManager.default.removeItem(at: fileURL); shared?.removeObject(forKey: "pendingImportFile"); return }
        Task {
            do {
                let metadata = try await importService.extractMetadata(url: fileURL)
                await MainActor.run {
                    pendingImport = ImportPending(url: fileURL, metadata: metadata, isFromShareExtension: true)
                    shared?.removeObject(forKey: "pendingImportFile")
                }
            } catch { await MainActor.run { importError = error.localizedDescription } }
        }
    }
}

struct ImportPending: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: ImportMetadata
    let isFromShareExtension: Bool
}
