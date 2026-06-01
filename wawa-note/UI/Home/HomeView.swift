import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation
import Vision
import VisionKit

// MARK: - HomeViewModel

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var importProgress: String?
    @Published var importError: String?
    @Published var showFilePicker = false
    @Published var pendingImport: ImportPending?
    @Published var targetProjectForImport: Project?

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()
    let importRouter = ImportRouter(importers: [
        AudioImportService(), PlainTextImporter(), MarkdownImporter(),
        JSONImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
        SRTImporter(), ICSImporter(), GitHubIssuesImporter()
    ])

    private var modelContext: ModelContext?
    private var contentPipeline: ContentPipelineService?
    private var coordinator: RecordingCoordinator?

    func configure(modelContext: ModelContext, contentPipeline: ContentPipelineService, coordinator: RecordingCoordinator) {
        self.modelContext = modelContext
        self.contentPipeline = contentPipeline
        self.coordinator = coordinator
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
        let d = c.appendingPathComponent("Shared", isDirectory: true)
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

            guard let importer = importRouter.importer(for: url) else { continue }

            if importer.formatIdentifier == "audio" {
                await importAudioFile(url, importer: importer, deleteSource: deleteSource, modelContext: ctx, pipeline: pipeline)
            } else {
                await importTextFile(url, importer: importer, deleteSource: deleteSource, modelContext: ctx, pipeline: pipeline)
            }

            imported += 1
            await MainActor.run { importProgress = "Importing \(imported)/\(total)..." }
        }

        await MainActor.run { importProgress = nil; targetProjectForImport = nil }
    }

    private func importAudioFile(_ url: URL, importer: any FormatImporter, deleteSource: Bool, modelContext: ModelContext, pipeline: ContentPipelineService) async {
        guard let coord = coordinator else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)
        do { try FileManager.default.copyItem(at: url, to: tempURL) } catch { return }

        let meta: ImportMetadata
        do { meta = try await importService.extractMetadata(url: tempURL) } catch { return }

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
            try? FileManager.default.removeItem(at: tempURL)
            if deleteSource { try? FileManager.default.removeItem(at: url) }
            pipeline.process(itemId, using: modelContext)
        } catch {
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
                if let target = targetProjectForImport {
                    try? ProjectService(context: modelContext).addItem(item.id, to: target.id)
                }
                pipeline.process(item.id, using: modelContext)
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
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @Environment(\.modelContext) private var modelContext

    @StateObject private var captureVM = CaptureViewModel()
    @StateObject private var importVM = HomeViewModel()
    @StateObject private var scannerVM = ScannerViewModel()
    @State private var navigateToItem: KnowledgeItem?
    @State private var navigateToProject: Project?
    @State private var showCreationSheet = false
    @State private var showScanner = false
    @State private var expandedProjectIDs: Set<UUID> = []

    var body: some View {
        ZStack {
            switch captureVM.recordingState {
            case .recording, .paused:
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
                if let target = importVM.targetProjectForImport {
                    try? ProjectService(context: modelContext).addItem(item.id, to: target.id)
                }
                contentPipeline.process(item.id, using: modelContext)
                navigateToItem = item
                importVM.pendingImport = nil
            }
        }
        .onOpenURL { if $0.scheme == "wawanote" { Task { await importVM.scanSharedDirectoryAndImport() } } }
        .alert("Import Error", isPresented: Binding(get: { importVM.importError != nil }, set: { if !$0 { importVM.importError = nil } })) { Button("OK") { importVM.importError = nil } } message: { Text(importVM.importError ?? "") }
        .sheet(isPresented: $showCreationSheet) { CreationSheetView() }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerView(scannedImages: $scannerVM.scannedImages)
        }
        .onChange(of: scannerVM.scannedImages) { _, images in
            guard !images.isEmpty else { return }
            Task {
                let items = await scannerVM.createItems(from: images, context: modelContext)
                for item in items {
                    await contentPipeline.process(item.id, using: modelContext)
                }
                scannerVM.scannedImages = []
                navigateToItem = items.first
            }
        }
        .onAppear {
            captureVM.bind(coordinator: coordinator)
            captureVM.modelContext = modelContext
            captureVM.contentPipeline = contentPipeline
            importVM.configure(modelContext: modelContext, contentPipeline: contentPipeline, coordinator: coordinator)
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
                Text("Capture, organize, understand")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 0).padding(.bottom, 20)

            if !projects.isEmpty {
                Text("Projects").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                List {
                    ForEach(projects) { project in projectRow(project) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color(.systemBackground))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else { Spacer() }
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expandedProjectIDs = [] } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 16) {
                    Button(action: { captureVM.startRecording() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                            Text("Record").font(.headline)
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                        .background(LinearGradient(colors: [.red, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button(action: { showScanner = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "doc.text.viewfinder").font(.subheadline)
                            Text("Scan").font(.caption2)
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
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(.bar)
                .shadow(color: .black.opacity(0.08), radius: 4, y: -2)
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

    private func startRecordingFor(_ project: Project) {
        captureVM.startRecording(projectID: project.id)
    }

    // MARK: Recording panel

    private var recordingPanel: some View {
        let isPaused = captureVM.recordingState == .paused
        return VStack(spacing: 0) {
            Spacer()
            ScrollingWaveformView(level: captureVM.audioLevel, isRunning: !isPaused)
                .frame(height: 64).padding(.horizontal, 16)
            Spacer().frame(height: 24)
            Text(captureVM.elapsedTimeFormatted)
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundStyle(isPaused ? .orange : .primary)
            Text(isPaused ? "Paused" : "Recording")
                .font(.subheadline).foregroundStyle(isPaused ? .orange : .secondary)
            if let error = captureVM.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 32).multilineTextAlignment(.center)
            }
            Spacer()
            HStack(spacing: 40) {
                if isPaused {
                    Button(action: { captureVM.resumeRecording() }) {
                        ZStack {
                            Circle().fill(.red).frame(width: 64, height: 64)
                            Image(systemName: "record.circle.fill").font(.system(size: 28)).foregroundStyle(.white)
                        }
                    }
                    Button(action: { UINotificationFeedbackGenerator().notificationOccurred(.success); captureVM.stopRecording() }) {
                        Text("Finish").font(.headline).foregroundStyle(.primary)
                            .frame(width: 80, height: 44)
                            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                } else {
                    Button(action: { captureVM.pauseRecording() }) {
                        ZStack {
                            Circle().fill(.white).frame(width: 64, height: 64)
                            Image(systemName: "pause.fill").font(.system(size: 24)).foregroundStyle(.orange)
                        }
                    }
                }
            }.padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemGroupedBackground))
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

        // Save all pages and collect OCR text
        var allText: [String] = []
        for (idx, image) in images.enumerated() {
            let filename = "scan_\(idx).jpg"
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: dir.appendingPathComponent(filename))
            }
            if let text = await recognizeText(from: image), !text.isEmpty {
                allText.append(text)
            }
        }

        item.imageFileRelativePath = "scan_0.jpg"
        item.imagePageCount = images.count
        item.bodyText = allText.joined(separator: "\n\n---\n\n")

        do {
            try context.save()
            return [item]
        } catch {
            AppLog.general.error("Failed to save scanned item: \(error)")
            return []
        }
    }

    private func recognizeText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            if request.results == nil { continuation.resume(returning: nil) }
        }
    }
}
