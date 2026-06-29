import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation
import Vision
import VisionKit
import PhotosUI

// MARK: - HomeViewModel

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var importProgress: String?
    @Published var importError: String?
    @Published var showFilePicker = false
    @Published var pendingImport: ImportPending?
    @Published var targetProjectForImport: Project?
    @Published var showProjectPickerForInboxItem = false
    @Published var pendingInboxItemForProject: KnowledgeItem?

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()
    let importRouter = ImportRouter(importers: [
        AudioImportService(), PlainTextImporter(), MarkdownImporter(),
        JSONImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
        SRTImporter(), ICSImporter(), AnarlogImporter(), MeetilyImporter()
    ])

    private var modelContext: ModelContext?
    private var contentPipeline: ContentPipelineService?
    private var coordinator: RecordingCoordinator?
    private var processingQueue: ProcessingQueueService?

    func configure(modelContext: ModelContext, contentPipeline: ContentPipelineService, coordinator: RecordingCoordinator, processingQueue: ProcessingQueueService? = nil) {
        self.modelContext = modelContext
        self.contentPipeline = contentPipeline
        self.coordinator = coordinator
        self.processingQueue = processingQueue
    }

    // MARK: Import

    func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { importError = "No file was selected."; return }
            if urls.count == 1, let url = urls.first { stageSingleImport(url) }
            else { Task { await importFiles(urls, deleteSource: false) } }
        case .failure(let e): importError = e.localizedDescription
        }
    }

    private func stageSingleImport(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let importer = importRouter.importer(for: url) else {
            importError = "Format not supported."
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)
        do { try FileManager.default.copyItem(at: url, to: tempURL) } catch {
            importError = error.localizedDescription; return
        }

        if importer.formatIdentifier == "audio" {
            Task {
                do {
                    let meta = try await importService.extractMetadata(url: tempURL)
                    await MainActor.run {
                        pendingImport = ImportPending(url: tempURL, kind: .audio(meta), isFromShareExtension: false)
                    }
                } catch {
                    await MainActor.run { importError = error.localizedDescription }
                }
            }
        } else {
            let preview = extractTextPreview(url: tempURL, importer: importer)
            pendingImport = ImportPending(url: tempURL, kind: .text(preview), textImporter: importer, isFromShareExtension: false)
        }
    }

    private func extractTextPreview(url: URL, importer: any FormatImporter) -> TextImportPreview {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let filename = url.deletingPathExtension().lastPathComponent
        let fileSize = Int64(resourceValues?.fileSize ?? 0)
        let creationDate = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
        var snippet = ""
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4096),
               let text = String(data: data, encoding: .utf8) {
                snippet = String(text.prefix(500))
            }
        }
        return TextImportPreview(formatIdentifier: importer.formatIdentifier, displayName: importer.displayName,
                                  suggestedTitle: filename, fileSize: fileSize, creationDate: creationDate, textSnippet: snippet)
    }

    func scanSharedDirectoryAndImport() async {
        guard let ctx = modelContext else { return }
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else { return }
        let d = c.appendingPathComponent("shared", isDirectory: true)
        guard FileManager.default.fileExists(atPath: d.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return }
        let pending = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !pending.isEmpty else { return }
        await importFiles(pending, deleteSource: true)
    }

    private func importFiles(_ urls: [URL], deleteSource: Bool) async {
        guard let ctx = modelContext, let pipeline = contentPipeline else { return }
        let total = urls.count; var imported = 0
        await MainActor.run { importProgress = "Importing 0/\(total)..." }

        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            // Try format importer first
            if let importer = importRouter.importer(for: url) {
                if importer.formatIdentifier == "audio" {
                    await importAudioFile(url, importer: importer, deleteSource: deleteSource, modelContext: ctx, pipeline: pipeline)
                } else {
                    await importTextFile(url, importer: importer, deleteSource: deleteSource, modelContext: ctx, pipeline: pipeline)
                }
            } else if let imgType = detectImageType(url: url) {
                // Import image files directly
                await importImageFile(url, deleteSource: deleteSource, modelContext: ctx, pipeline: pipeline)
            } else {
                // Unrecognized file — remove from shared directory so it isn't
                // rediscovered on every scan. Log for diagnostics.
                AppLog.general.warning("HomeView: unrecognized file in shared directory — removing: \(url.lastPathComponent)")
                if deleteSource { try? FileManager.default.removeItem(at: url) }
                continue
            }

            imported += 1
            await MainActor.run { importProgress = "Importing \(imported)/\(total)..." }
        }

        await MainActor.run { importProgress = nil; targetProjectForImport = nil }
    }

    private func importAudioFile(_ url: URL, importer: any FormatImporter, deleteSource: Bool, modelContext: ModelContext, pipeline: ContentPipelineService) async {
        guard let coord = coordinator else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString)_\(url.lastPathComponent)")
        // Ensure temp file is always cleaned up, regardless of exit path
        defer { try? FileManager.default.removeItem(at: tempURL) }
        // Clean up stale temp file from a previous run (different UUID, so no collision)
        try? FileManager.default.removeItem(at: tempURL)
        do { try FileManager.default.copyItem(at: url, to: tempURL) } catch {
            AppLog.general.error("HomeView: importAudioFile copy failed — \(error.localizedDescription)")
            return
        }

        let meta: ImportMetadata
        do { meta = try await importService.extractMetadata(url: tempURL) } catch {
            AppLog.general.error("HomeView: importAudioFile metadata extraction failed — \(error.localizedDescription)")
            return
        }

        let itemId = await MainActor.run {
            let item = coord.createItemFromImport(title: meta.suggestedTitle, date: meta.creationDate ?? Date(), duration: meta.duration)
            if let target = targetProjectForImport, let item {
                try? ProjectService(context: modelContext).addItem(item.id, to: target.id)
            }
            return item?.id
        }
        guard let itemId else { return }

        do {
            try await importService.storeAudio(sourceURL: tempURL, itemID: itemId, using: artifactStore)
            if deleteSource { try? FileManager.default.removeItem(at: url) }
            processingQueue?.enqueue(itemID: itemId, trigger: .newCapture)
        } catch {
            AppLog.general.error("HomeView: importAudioFile storeAudio failed — \(error.localizedDescription)")
            await MainActor.run { coord.deleteItem(itemId) }
        }
    }

    private func importTextFile(_ url: URL, importer: any FormatImporter, deleteSource: Bool, modelContext: ModelContext, pipeline: ContentPipelineService) async {
        do {
            let result = try await importer.importFromURL(url)
            let item = result.knowledgeItem
            await MainActor.run {
                modelContext.insert(item)
                try? modelContext.save()
                if let t = targetProjectForImport {
                    try? ProjectService(context: modelContext).addItem(item.id, to: t.id)
                }
                processingQueue?.enqueue(itemID: item.id, projectID: targetProjectForImport?.id, trigger: .newCapture)
            }
            if deleteSource { try? FileManager.default.removeItem(at: url) }
        } catch {
            await MainActor.run { importError = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    // MARK: Backfill

    func backfillEmbeddingsIfNeeded(items: [KnowledgeItem]) async {
        guard let ctx = modelContext else { return }
        let flag = "embeddings_backfill_done_v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        guard let provider = try? ProviderRouter.resolveActive(context: ctx) else { return }
        await EmbeddingPipelineService().backfillAll(items: items, using: provider) { _, _ in }
        UserDefaults.standard.set(true, forKey: flag)
    }

    private func detectImageType(url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "bmp"].contains(ext) { return ext }
        // Try UTI
        if let resourceValues = try? url.resourceValues(forKeys: [.typeIdentifierKey]),
           let uti = resourceValues.typeIdentifier {
            if uti.hasPrefix("public.image") || uti.hasPrefix("public.jpeg") || uti.hasPrefix("public.png") { return "jpg" }
        }
        return nil
    }

    private func importImageFile(_ url: URL, deleteSource: Bool, modelContext: ModelContext, pipeline: ContentPipelineService) async {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        let itemService = KnowledgeItemService(context: modelContext)
        let title = url.lastPathComponent
        guard let item = try? itemService.createItem(type: .image, title: title, bodyText: nil, inboxDate: Date()) else { return }
        // Save image
        let dir = FileArtifactStore().itemDirectoryURL(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destURL = dir.appendingPathComponent("scan_0.jpg")
        try? data.write(to: destURL)
        item.imageFileRelativePath = "scan_0.jpg"
        item.imagePageCount = 1
        try? modelContext.save()
        // Run OCR + vision
        let extractionSvc = ContentExtractionService(modelContext: modelContext, fileStore: FileArtifactStore())
        if let text = await extractionSvc.extractTextFromImage(item) {
            item.bodyText = text
            try? modelContext.save()
        }
        // Clean up source
        if deleteSource { try? FileManager.default.removeItem(at: url) }
        await MainActor.run { importProgress = nil }
    }
}

/// Color the quality badge: green for HQ (44.1-48kHz), yellow for MQ (16-22kHz),
/// orange for LQ (8kHz Bluetooth HFP).
private func qualityBadgeColor(_ badge: String) -> Color {
    if badge.contains("HQ") { return .green }
    if badge.contains("MQ") { return .yellow }
    return .orange
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @EnvironmentObject private var processingQueue: ProcessingQueueService
    @EnvironmentObject private var chatState: ChatOverlayState
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(filter: #Predicate<KnowledgeItem> { $0.inboxDate != nil }, sort: \KnowledgeItem.updatedAt, order: .reverse) private var inboxItems: [KnowledgeItem]
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @Environment(\.modelContext) private var modelContext

    @StateObject private var captureVM = CaptureViewModel()
    @StateObject private var importVM = HomeViewModel()
    @StateObject private var scannerVM = ScannerViewModel()
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48
    @ScaledMetric(relativeTo: .title) private var buttonIconSize: CGFloat = 28
    @State private var navigateToItem: KnowledgeItem?
    @State private var navigateToProject: Project?
    @State private var showCreationSheet = false
    @State private var showScanner = false
    @State private var showScanMenu = false
    @State private var showBarcodeScanner = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showPhotoSourceMenu = false
    @State private var capturedPhoto: UIImage?
    @State private var expandedProjectIDs: Set<UUID> = []

    var body: some View {
        ZStack {
            switch captureVM.recordingState {
            case .preparing, .recording, .paused:
                recordingPanel
            case .stopped:
                defaultSurface
                    .onAppear {
                        if let itemId = captureVM.savedItemId,
                           let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemId) {
                            navigateToItem = item
                        }
                        captureVM.finishCapture()
                    }
            default:
                defaultSurface
            }
        }
        .background(Color(.systemGroupedBackground))
        .animation(.easeInOut(duration: 0.2), value: captureVM.recordingState)
        .overlay(alignment: .top) {
            if let progress = importVM.importProgress {
                HStack {
                    ProgressView().tint(.white)
                    Text(progress).font(.subheadline).fontWeight(.medium).foregroundStyle(.white)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.blue, in: Capsule())
                .padding(.top, 8)
            }
        }
        .task {
            await importVM.backfillEmbeddingsIfNeeded(items: allItems)
            await importVM.scanSharedDirectoryAndImport()
        }
        .navigationDestination(item: $navigateToItem) { KnowledgeDetailView(item: $0) }
        .navigationDestination(item: $navigateToProject) { ProjectDetailView(project: $0) }
        .fileImporter(isPresented: $importVM.showFilePicker, allowedContentTypes: importVM.importRouter.allUTTypes(), allowsMultipleSelection: true) { importVM.handleFilePick($0) }
        .sheet(item: $importVM.pendingImport) { imp in
            ImportFormView(sourceURL: imp.url, kind: imp.kind, textImporter: imp.textImporter, isFromShareExtension: imp.isFromShareExtension) { item in
                if let t = importVM.targetProjectForImport {
                    try? ProjectService(context: modelContext).addItem(item.id, to: t.id)
                }
                processingQueue.enqueue(itemID: item.id, projectID: importVM.targetProjectForImport?.id, trigger: .newCapture)
                navigateToItem = item
                importVM.pendingImport = nil
            }
            .environmentObject(coordinator)
        }
        .onOpenURL { if $0.scheme == "wawanote" { Task { await importVM.scanSharedDirectoryAndImport() } } }
        .alert("Import Error", isPresented: Binding(get: { importVM.importError != nil }, set: { if !$0 { importVM.importError = nil } })) { Button("OK") { importVM.importError = nil } } message: { Text(importVM.importError ?? "") }
        .alert("Recording Error", isPresented: Binding(
            get: { captureVM.errorMessage != nil && captureVM.recordingState == .idle },
            set: { if !$0 { captureVM.errorMessage = nil } }
        )) {
            Button("OK") { captureVM.errorMessage = nil }
        } message: {
            Text(captureVM.errorMessage ?? "Could not start recording.")
        }
        .sheet(isPresented: $showCreationSheet) { CreationSheetView().presentationDragIndicator(.visible) }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerView(scannedImages: $scannerVM.scannedImages)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(capturedImage: $capturedPhoto)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(selectedImage: $capturedPhoto)
        }
        .confirmationDialog("Scan", isPresented: $showScanMenu) {
            Button("Scan Document") { showScanner = true }
            Button("Scan QR / Barcode") { showBarcodeScanner = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showBarcodeScanner) {
            BarcodeScannerView()
        }
        .confirmationDialog("Photo Source", isPresented: $showPhotoSourceMenu) {
            Button("Take Photo") { showCamera = true }
            Button("Choose from Gallery") { showPhotoPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: capturedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                let items = await processPhotoItem(photo)
                for item in items {
                    processingQueue.enqueue(itemID: item.id, trigger: .newCapture)
                }
                capturedPhoto = nil
                navigateToItem = items.first
            }
        }
        .onChange(of: scannerVM.scannedImages) { _, images in
            guard !images.isEmpty else { return }
            Task {
                let items = await scannerVM.createItems(from: images, context: modelContext)
                for item in items {
                    processingQueue.enqueue(itemID: item.id, trigger: .newCapture)
                }
                scannerVM.scannedImages = []
                navigateToItem = items.first
            }
        }
        .onAppear {
            chatState.context = .global
            chatViewModel.pregenerateGreeting(for: .global)
            captureVM.bind(coordinator: coordinator)
            captureVM.modelContext = modelContext
            captureVM.contentPipeline = contentPipeline
            captureVM.processingQueue = processingQueue
            importVM.configure(modelContext: modelContext, contentPipeline: contentPipeline, coordinator: coordinator, processingQueue: processingQueue)
        }
    }

    // MARK: Default surface

    private var defaultSurface: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(.wawaSymbolGradient)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: .blue.opacity(0.15), radius: 16, y: 4)
                Text("wawa-note").font(.title2).fontWeight(.semibold)
                Text("Your Knowledge, Your Process.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 0).padding(.bottom, 20)

            if !projects.isEmpty {
                let recentProjects = Array(projects.prefix(5))
                Text("Projects").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                List {
                    ForEach(recentProjects) { project in projectRow(project) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color(.systemBackground))
                        .listRowSeparator(.hidden)
                    if projects.count > 5 {
                        NavigationLink(value: "explore:projects") {
                            Text("See all \(projects.count) projects →").font(.caption).foregroundStyle(.blue)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color(.systemBackground))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: min(CGFloat(recentProjects.count) * 52, 260))
            }

            if !inboxItems.isEmpty {
                let recentInbox = Array(inboxItems.prefix(5))
                Text("Inbox").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 6).padding(.top, 16)
                List {
                    ForEach(recentInbox) { item in inboxRow(item) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color(.systemBackground))
                        .listRowSeparator(.hidden)
                    if inboxItems.count > 5 {
                        NavigationLink(value: "explore:inbox") {
                            Text("See all \(inboxItems.count) inbox items →").font(.caption).foregroundStyle(.blue)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color(.systemBackground))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: min(CGFloat(recentInbox.count) * 52, 260))
            }

            if projects.isEmpty && inboxItems.isEmpty { Spacer() }
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expandedProjectIDs = [] } }
        .safeAreaInset(edge: .bottom) {
            if !chatState.isActive {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 10) {
                        Button(action: { captureVM.startRecording() }) {
                            VStack(spacing: 2) {
                                Image(systemName: "record.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                                Text("Record").font(.caption2)
                            }
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                            .background(LinearGradient(colors: [.red, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Start Recording")
                            .accessibilityHint("Double-tap to begin recording")
                        }
                        Button(action: { showScanMenu = true }) {
                            VStack(spacing: 4) {
                                Image(systemName: "doc.text.viewfinder").font(.subheadline)
                                Text("Scan").font(.caption2)
                            }.foregroundStyle(.primary).frame(width: 60, height: 52)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        Button(action: { showPhotoSourceMenu = true }) {
                            VStack(spacing: 4) {
                                Image(systemName: "photo").font(.subheadline)
                                Text("Photo").font(.caption2)
                            }.foregroundStyle(.primary).frame(width: 60, height: 52)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        Button(action: { importVM.showFilePicker = true }) {
                            VStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down").font(.subheadline)
                                Text("Import").font(.caption2)
                            }.foregroundStyle(.primary).frame(width: 60, height: 52)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        Button(action: { showCreationSheet = true }) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus.circle").font(.subheadline)
                                Text("New").font(.caption2)
                            }.foregroundStyle(.primary).frame(width: 60, height: 52)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6).background(.bar)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: -2)
                }
            }
        }
    }

    // MARK: Project row

    private var itemsByProject: [UUID: [KnowledgeItem]] {
        Dictionary(grouping: allItems, by: { $0.projectID ?? UUID() })
    }

    private func projectRow(_ project: Project) -> some View {
        let projectItems = itemsByProject[project.id] ?? []
        let isExpanded = expandedProjectIDs.contains(project.id)

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: project.iconName ?? "folder.fill")
                    .font(.title3).foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.subheadline).fontWeight(.medium)
                    Text("\(projectItems.count) items · Updated \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isExpanded { Image(systemName: "chevron.up").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { navigateToProject = project }
            .onLongPressGesture(minimumDuration: 0.4) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedProjectIDs.remove(project.id) }
                    else { expandedProjectIDs.insert(project.id) }
                }
            }
            .background(Color(.systemBackground))
            .swipeActions(edge: .leading) {
                Button { navigateToProject = project } label: {
                    Label("Tasks", systemImage: "checklist")
                }.tint(.green)
                Button { navigateToProject = project } label: {
                    Label("Timeline", systemImage: "calendar.day.timeline.leading")
                }.tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                Button { startRecordingFor(project) } label: {
                    Label("Record", systemImage: "record.circle")
                }.tint(.red)
                Button { importVM.targetProjectForImport = project; importVM.showFilePicker = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }.tint(.blue)
            }

            if isExpanded {
                Divider().padding(.leading, 56)
                VStack(spacing: 0) {
                    ForEach(projectItems.prefix(5)) { item in
                        Button { navigateToItem = item } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.type.icon).font(.caption).foregroundStyle(item.type.color)
                                Text(item.title.isEmpty ? "Untitled" : item.title)
                                    .font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 20).padding(.vertical, 8)
                        }
                    }
                    if projectItems.count > 5 {
                        Button { navigateToProject = project } label: {
                            Text("+\(projectItems.count - 5) more items").font(.caption).foregroundStyle(.blue)
                                .padding(.horizontal, 20).padding(.vertical, 6)
                        }
                    }
                    if projectItems.isEmpty {
                        Text("No items yet").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                .background(Color(.secondarySystemBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Inbox row (home screen)

    private func inboxRow(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.icon)
                .font(.title3).foregroundStyle(item.type.color)
                .frame(width: 32, height: 32)
                .background(item.type.color.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                Text("\(item.type.label) · \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { navigateToItem = item }
        .swipeActions(edge: .leading) {
            Button {
                try? KnowledgeItemService(context: modelContext).removeFromInbox(item)
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                importVM.targetProjectForImport = nil
                importVM.pendingInboxItemForProject = item
                importVM.showProjectPickerForInboxItem = true
            } label: {
                Label("Move to Project", systemImage: "folder.badge.plus")
            }.tint(.blue)
        }
        .sheet(isPresented: $importVM.showProjectPickerForInboxItem) {
            if let item = importVM.pendingInboxItemForProject {
                ProjectPickerForItemView(item: item)
            }
        }
    }

    private func startRecordingFor(_ project: Project) {
        captureVM.startRecording(projectID: project.id)
    }

    // MARK: Recording panel

    private var recordingPanel: some View {
        let isActive = captureVM.recordingState == .recording
        let isPaused = captureVM.recordingState == .paused
        let isPreparing = captureVM.recordingState == .preparing
        let isSwitching = false
        let isSystemInterrupted = false
        let isTroubled = isPreparing || isSwitching || isSystemInterrupted
        return VStack(spacing: 0) {
            Spacer()
            ScrollingWaveformView(level: captureVM.audioLevel, isRunning: isActive)
                .frame(height: 64).padding(.horizontal, 16)
            Spacer().frame(height: 16)
            // Audio source indicator with quality badge
            HStack(spacing: 6) {
                Image(systemName: captureVM.currentInputIcon)
                    .font(.caption2)
                Text(captureVM.currentInputPortName)
                    .font(.caption2)
                if !captureVM.sampleRateBadge.isEmpty {
                    Text(captureVM.sampleRateBadge)
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(qualityBadgeColor(captureVM.sampleRateBadge))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            // Silence detection warning
            if captureVM.silenceDetected {
                HStack(spacing: 4) {
                    Image(systemName: "mic.slash").font(.caption2)
                    Text("Silence detected — mic muted?").font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
            Spacer().frame(height: 16)
            Text(captureVM.elapsedTimeFormatted)
                .font(.system(.largeTitle, design: .monospaced).weight(.thin))
                .foregroundStyle(isTroubled ? .orange : (isPaused ? .orange : .primary))
            if isSwitching {
                VStack(spacing: 4) {
                    ProgressView().tint(.orange)
                    Text("Switching microphone…")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text("Your recording is safe — this may take a moment")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if isPreparing {
                VStack(spacing: 4) {
                    ProgressView()
                    Text("Preparing microphone…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if isSystemInterrupted {
                Text("Recording interrupted")
                    .font(.subheadline).foregroundStyle(.red)
            } else if isActive {
                HStack(spacing: 6) {
                    PulsingRecordingDot()
                    Text("Recording")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if captureVM.isAutoPaused {
                Text("Auto-Paused (silence)")
                    .font(.subheadline).foregroundStyle(.orange)
            } else {
                Text(isPaused ? "Paused" : "Recording")
                    .font(.subheadline).foregroundStyle(isPaused ? .orange : .secondary)
            }
            if let error = captureVM.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 32).multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 16) {
                if isActive {
                    HStack(spacing: 40) {
                        Button(action: { captureVM.pauseRecording() }) {
                            ZStack {
                                Circle().fill(.white).frame(width: 64, height: 64)
                                Image(systemName: "pause.fill").font(.system(size: 24)).foregroundStyle(.orange)
                                    .accessibilityLabel("Pause Recording")
                            }
                        }
                        Button(action: { UINotificationFeedbackGenerator().notificationOccurred(.success); captureVM.stopRecording() }) {
                            Text("Finish").font(.headline).foregroundStyle(.primary)
                                .frame(width: 80, height: 44)
                                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 22))
                        }
                    }
                } else if isPaused || isSystemInterrupted {
                    HStack(spacing: 40) {
                        Button(action: { captureVM.resumeRecording() }) {
                            ZStack {
                                Circle().fill(isSystemInterrupted ? .orange : .red).frame(width: 64, height: 64)
                                Image(systemName: isSystemInterrupted ? "arrow.clockwise.circle.fill" : "record.circle.fill")
                                    .font(.system(size: buttonIconSize)).foregroundStyle(.white)
                            }
                        }
                        Button(action: { UINotificationFeedbackGenerator().notificationOccurred(.success); captureVM.stopRecording() }) {
                            Text("Finish").font(.headline).foregroundStyle(.primary)
                                .frame(width: 80, height: 44)
                                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 22))
                        }
                    }
                } else if isPreparing {
                    VStack(spacing: 12) {
                        Button(action: { captureVM.resumeRecording() }) {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .font(.headline).frame(maxWidth: 200, minHeight: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: { captureVM.forceBuiltInMic() }) {
                            Label("Use iPhone Microphone", systemImage: "iphone")
                                .font(.subheadline).frame(maxWidth: 200, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        Button(action: { UINotificationFeedbackGenerator().notificationOccurred(.success); captureVM.stopRecording() }) {
                            Text("Finish").font(.headline).foregroundStyle(.secondary)
                                .frame(width: 80, height: 44)
                        }
                    }
                } else if isSwitching {
                    Button(action: { UINotificationFeedbackGenerator().notificationOccurred(.success); captureVM.stopRecording() }) {
                        Text("Finish").font(.headline).foregroundStyle(.primary)
                            .frame(width: 80, height: 44)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                }
            }.padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemGroupedBackground))
    }

    private func processPhotoItem(_ image: UIImage) async -> [KnowledgeItem] {
        let itemService = KnowledgeItemService(context: modelContext)
        guard let item = try? itemService.createItem(type: .image, title: "Photo", bodyText: nil) else { return [] }
        let store = FileArtifactStore()
        let dir = store.itemDirectoryURL(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: dir.appendingPathComponent("scan_0.jpg"))
        }
        item.imageFileRelativePath = "scan_0.jpg"
        item.imagePageCount = 1

        // ImageAnalysisService handles both OCR and LLM vision in one call.
        if let provider = try? ProviderRouter.resolveActive(context: modelContext) {
            let model = AIConfigService.shared.featureConfig(for: "analysis")?.model ?? ""
            let auth = FieldAuthorityService.shared
            if auth.canModify(field: "bodyText", of: item, by: .system) {
                item.bodyText = try? await ImageAnalysisService().analyzeImage(
                    dir.appendingPathComponent("scan_0.jpg"),
                    llmProvider: provider, model: model
                )
                if item.bodyText != nil {
                    var prov = item.provenance
                    prov.mark(field: "bodyText", origin: .system)
                    item.fieldProvenanceJSON = prov.encode()
                }
            }
        }
        // Fallback: local OCR only if no provider configured
        if item.bodyText == nil {
            let auth = FieldAuthorityService.shared
            if auth.canModify(field: "bodyText", of: item, by: .system) {
                item.bodyText = await recognizeText(from: image)
                if item.bodyText != nil {
                    var prov = item.provenance
                    prov.mark(field: "bodyText", origin: .system)
                    item.fieldProvenanceJSON = prov.encode()
                }
            }
        }
        try? modelContext.save()
        return [item]
    }

    private func recognizeText(from image: UIImage) async -> String? {
        await ContentExtractionService.recognizeText(from: image)
    }
}

// MARK: - Waveform

struct ScrollingWaveformView: View {
    let level: Float; let isRunning: Bool
    @State private var offset: CGFloat = 0; @State private var timer: Timer?

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let midY = size.height / 2; let amp = size.height / 2 - 4
                var path = Path(); path.move(to: CGPoint(x: 0, y: midY))
                for i in 0...60 {
                    let x = size.width * CGFloat(i) / 60
                    let v = isRunning ? CGFloat(level) : 0.08
                    let y = midY + CGFloat(sin(Double(i) * 0.5 + offset) * Double(amp) * Double(v) * 1.5)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                context.stroke(path, with: .color(isRunning ? .red : .orange.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .onChange(of: isRunning) { _, r in r ? start() : stop() }
        .onAppear { if isRunning { start() } }
        .onDisappear { stop() }
    }
    private func start() { stop(); timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in Task { @MainActor in offset += 0.15 } } }
    private func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - ImportPending

struct ImportPending: Identifiable {
    let id = UUID()
    let url: URL
    let kind: ImportKind
    var textImporter: (any FormatImporter)?
    let isFromShareExtension: Bool
}

// MARK: - ScannerView (VisionKit wrapper)

struct ScannerView: UIViewControllerRepresentable {
    @Binding var scannedImages: [UIImage]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ScannerView

        init(_ parent: ScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for i in 0 ..< scan.pageCount { images.append(scan.imageOfPage(at: i)) }
            parent.scannedImages = images
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}

// MARK: - ScannerViewModel

@MainActor
final class ScannerViewModel: ObservableObject {
    @Published var scannedImages: [UIImage] = []
    @Published var isProcessing = false

    private let fileStore = FileArtifactStore()

    func createItems(from images: [UIImage], context: ModelContext) async -> [KnowledgeItem] {
        guard !images.isEmpty else { return [] }
        isProcessing = true
        defer { isProcessing = false }

        let itemService = KnowledgeItemService(context: context)
        let title = images.count > 1 ? "Scanned Document (\(images.count) pages)" : "Scanned Document"

        guard let item = try? itemService.createItem(
            type: .image,
            title: title,
            bodyText: nil
        ) else { return [] }

        let dir = fileStore.itemDirectoryURL(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Save all pages
        for (idx, image) in images.enumerated() {
            let filename = "scan_\(idx).jpg"
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: dir.appendingPathComponent(filename))
            }
        }

        var contentParts: [String] = []

        // Page 1: ImageAnalysisService handles OCR + LLM vision together (no duplication)
        if let provider = try? ProviderRouter.resolveActive(context: context) {
            let model = AIConfigService.shared.featureConfig(for: "analysis")?.model ?? ""
            let firstPageURL = dir.appendingPathComponent("scan_0.jpg")
            if let analysis = try? await ImageAnalysisService().analyzeImage(firstPageURL, llmProvider: provider, model: model),
               !analysis.isEmpty {
                contentParts.append(analysis)
            }
        } else {
            // Fallback: local OCR only
            if !images.isEmpty, let ocr = await recognizeText(from: images[0]), !ocr.isEmpty {
                contentParts.append("OCR TEXT:\n\(ocr)")
            }
        }

        // Pages 2+: local OCR only (LLM vision on every page would be too expensive)
        if images.count > 1 {
            for idx in 1..<images.count {
                if let ocr = await recognizeText(from: images[idx]), !ocr.isEmpty {
                    contentParts.append("PAGE \(idx + 1):\n\(ocr)")
                }
            }
        }

        item.imageFileRelativePath = "scan_0.jpg"
        item.imagePageCount = images.count
        let auth = FieldAuthorityService.shared
        if auth.canModify(field: "bodyText", of: item, by: .system) {
            item.bodyText = contentParts.joined(separator: "\n\n---\n\n")
            var prov = item.provenance
            prov.mark(field: "bodyText", origin: .system)
            item.fieldProvenanceJSON = prov.encode()
        }

        do {
            try context.save()
            return [item]
        } catch {
            AppLog.general.error("Failed to save scanned item: \(error)")
            return []
        }
    }

    private func recognizeText(from image: UIImage) async -> String? {
        await ContentExtractionService.recognizeText(from: image)
    }
}

// MARK: - Camera Capture

struct CameraCaptureView: UIViewControllerRepresentable {
    @Binding var capturedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, @unchecked Sendable {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                Task { @MainActor [weak self] in self?.parent.capturedImage = image }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Project Picker for Inbox Item

struct ProjectPickerForItemView: View {
    let item: KnowledgeItem
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var processingQueue: ProcessingQueueService

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { project in
                    Button {
                        assignToProject(item, project: project)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: project.iconName ?? "folder.fill")
                                .foregroundStyle(project.colorHex.flatMap { Color(hex: $0) } ?? .blue)
                            Text(project.name).font(.subheadline)
                            Spacer()
                        }
                    }
                }
                if projects.isEmpty {
                    Text("No projects yet").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Move to Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func assignToProject(_ item: KnowledgeItem, project: Project) {
        let svc = ProjectService(context: modelContext)
        if item.projectID == nil {
            // Item has no project — move/assign
            try? svc.addItem(item.id, to: project.id)
        } else if item.projectID != project.id {
            // Item already belongs to another project — create a copy
            let newItem = KnowledgeItem(
                type: item.type,
                title: item.title + " (copy)",
                bodyText: item.bodyText
            )
            newItem.projectID = project.id
            modelContext.insert(newItem)
            try? modelContext.save()
        }
        processingQueue.enqueue(itemID: item.id, projectID: project.id, trigger: .projectAssignment)
    }
}

// MARK: - Photo Gallery Picker

struct PhotoPickerView: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate, @unchecked Sendable {
        let parent: PhotoPickerView
        init(_ parent: PhotoPickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else { parent.dismiss(); return }
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = UIImage(data: data) else { return }
                Task { @MainActor [weak self] in
                    self?.parent.selectedImage = image
                    self?.parent.dismiss()
                }
            }
        }
    }
}

// MARK: - Empty State View

/// Reusable empty state with context-appropriate icons and messages per tab.
struct EmptyStateView: View {
    enum Tab { case capture, inbox, explore, chat, projects }

    let tab: Tab
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3).fontWeight(.medium)
            Text(subtitle)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var icon: String {
        switch tab {
        case .capture: "mic.badge.plus"
        case .inbox: "tray"
        case .explore: "rectangle.grid.1x2"
        case .chat: "bubble.left.and.bubble.right"
        case .projects: "folder.badge.questionmark"
        }
    }

    private var title: String {
        switch tab {
        case .capture: "Ready to Capture"
        case .inbox: "Inbox Empty"
        case .explore: "Explore Your Workspace"
        case .chat: "Start a Conversation"
        case .projects: "No Projects Yet"
        }
    }

    private var subtitle: String {
        switch tab {
        case .capture: "Tap the mic to record audio, scan documents, or import files."
        case .inbox: "New captures and imports appear here for triage."
        case .explore: "Create a project to organize items, tasks, and insights."
        case .chat: "Ask questions about your knowledge workspace or run analysis."
        case .projects: "Capture audio or create a project to get started."
        }
    }
}

// MARK: - Skeleton Loader

struct SkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.systemGray5))
            .opacity(shimmer ? 0.3 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: shimmer)
            .onAppear { shimmer = true }
    }
}

// MARK: - Pulsing Recording Dot

struct PulsingRecordingDot: View {
    @State private var pulse = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(colorScheme == .dark ? Color(red: 1.0, green: 0.3, blue: 0.3) : .red)
            .frame(width: 10, height: 10)
            .scaleEffect(pulse ? 1.3 : 0.9)
            .opacity(pulse ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
