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
    @State private var importProgress: String?
    @State private var importDebug: String?

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()

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
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if let progress = importProgress {
                        HStack {
                            ProgressView()
                                .tint(.white)
                            Text(progress)
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.blue, in: Capsule())
                    }
                    if let debug = importDebug {
                        Text(debug)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.7), in: Capsule())
                    }
                }
                .padding(.top, 8)
                .animation(.easeInOut, value: importProgress != nil)
            }
            .task {
                let trash = try? TrashService(context: modelContext).trashFolder()
                trashFolderID = trash?.id
                await backfillEmbeddingsIfNeeded()
                await scanSharedDirectoryAndImport()
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
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: AudioImportService.supportedUTTypes, allowsMultipleSelection: true) { handleFilePick($0) }
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
            guard !urls.isEmpty else { importError = "No file was selected."; return }
            // If a single file, show ImportFormView for editing; multiple files auto-import
            if urls.count == 1, let url = urls.first {
                stageSingleImport(url)
            } else {
                Task { await importFilePickerFiles(urls) }
            }
        case .failure(let e): importError = e.localizedDescription
        }
    }

    private func stageSingleImport(_ url: URL) {
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
    }

    private func importFilePickerFiles(_ urls: [URL]) async {
        let total = urls.count
        var imported = 0
        await MainActor.run { importProgress = "Importing 0/\(total)..." }

        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            guard importService.canRead(url: url) else { continue }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do { try FileManager.default.copyItem(at: url, to: tempURL) } catch { continue }

            let metadata: ImportMetadata
            do { metadata = try await importService.extractMetadata(url: tempURL) } catch { continue }

            let itemId = await MainActor.run {
                coordinator.createItemFromImport(
                    title: metadata.suggestedTitle,
                    date: metadata.creationDate ?? Date(),
                    duration: metadata.duration
                )?.id
            }
            guard let itemId = itemId else { continue }

            let destURL = artifactStore.audioFileURL(for: itemId)
            do {
                if importService.isNativeM4ACompatible(tempURL) {
                    try artifactStore.copyAudioToMeeting(sourceURL: tempURL, meetingId: itemId)
                } else {
                    try await importService.convertToAAC(inputURL: tempURL, outputURL: destURL)
                }
                try? FileManager.default.removeItem(at: tempURL)
                imported += 1
                await MainActor.run { importProgress = "Importing \(imported)/\(total)..." }
            } catch {
                await MainActor.run { coordinator.deleteItem(itemId) }
            }
        }

        await MainActor.run { importProgress = nil }
    }

    // MARK: - Embedding backfill

    private func backfillEmbeddingsIfNeeded() async {
        let backfillKey = "embedding_backfill_completed"
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }

        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else { return }

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
        Task { await scanSharedDirectoryAndImport() }
    }

    // MARK: - Pending import checker (backup if onOpenURL misses)

    private func checkPendingImports() {
        Task { await scanSharedDirectoryAndImport() }
    }

    // MARK: - Scan shared directory and import all files

    private func scanSharedDirectoryAndImport() async {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else {
            await MainActor.run { importDebug = "No App Group container" }
            return
        }

        let sharedDir = containerURL.appendingPathComponent("shared", isDirectory: true)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sharedDir.path) else {
            // No shared directory = nothing to import, not an error
            return
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: sharedDir, includingPropertiesForKeys: [.fileSizeKey])
                .filter { !$0.hasDirectoryPath }
        } catch {
            await MainActor.run { importDebug = "Failed to list shared dir: \(error.localizedDescription)" }
            return
        }

        guard !files.isEmpty else { return }

        let total = files.count
        var imported = 0
        await MainActor.run { importProgress = "Importing 0/\(total)..." }

        for fileURL in files {
            guard importService.canRead(url: fileURL) else {
                try? fileManager.removeItem(at: fileURL)
                continue
            }

            let metadata: ImportMetadata
            do {
                metadata = try await importService.extractMetadata(url: fileURL)
            } catch {
                await MainActor.run { importDebug = "extractMetadata failed: \(error.localizedDescription)" }
                continue
            }

            let itemId = await MainActor.run {
                coordinator.createItemFromImport(
                    title: metadata.suggestedTitle,
                    date: metadata.creationDate ?? Date(),
                    duration: metadata.duration
                )?.id
            }
            guard let itemId = itemId else {
                await MainActor.run { importDebug = "createItemFromImport returned nil" }
                continue
            }

            let destURL = artifactStore.audioFileURL(for: itemId)
            do {
                if importService.isNativeM4ACompatible(fileURL) {
                    try artifactStore.copyAudioToMeeting(sourceURL: fileURL, meetingId: itemId)
                } else {
                    try await importService.convertToAAC(inputURL: fileURL, outputURL: destURL)
                }
                try? fileManager.removeItem(at: fileURL)
                imported += 1
                await MainActor.run { importProgress = "Importing \(imported)/\(total)..." }
            } catch {
                await MainActor.run {
                    importDebug = "Audio processing failed: \(error.localizedDescription)"
                    coordinator.deleteItem(itemId)
                }
            }
        }

        // Also clean up old UserDefaults keys if present
        let shared = UserDefaults(suiteName: "group.com.wawa-note")
        shared?.removeObject(forKey: "pendingImportFiles")
        shared?.removeObject(forKey: "pendingImportFile")

        await MainActor.run {
            importProgress = nil
            if imported > 0 { importDebug = "Imported \(imported) of \(total) files" }
        }
    }
}

struct ImportPending: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: ImportMetadata
    let isFromShareExtension: Bool
}
