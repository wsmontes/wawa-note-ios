import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct HomeView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Environment(\.modelContext) private var modelContext

    @StateObject private var captureVM = CaptureViewModel()
    @State private var navigateToItem: KnowledgeItem?
    @State private var showFilePicker = false
    @State private var pendingImport: ImportPending?
    @State private var importError: String?
    @State private var showCreationSheet = false
    @State private var importProgress: String?

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()

    var body: some View {
        VStack(spacing: 0) {
            switch captureVM.recordingState {
            case .recording, .paused:
                recordingPanel
            case .stopped:
                postRecordingPanel
            default:
                defaultSurface
            }
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) {
            if let progress = importProgress {
                HStack {
                    ProgressView().tint(.white)
                    Text(progress).font(.subheadline).fontWeight(.medium).foregroundStyle(.white)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.blue, in: Capsule())
                .padding(.top, 8)
                .animation(.easeInOut, value: importProgress != nil)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: captureVM.recordingState)
        .task {
            await backfillEmbeddingsIfNeeded()
            await scanSharedDirectoryAndImport()
        }
        .navigationDestination(item: $navigateToItem) { KnowledgeDetailView(item: $0) }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: AudioImportService.supportedUTTypes, allowsMultipleSelection: true) { handleFilePick($0) }
        .sheet(item: $pendingImport) { ImportFormView(sourceURL: $0.url, metadata: $0.metadata, isFromShareExtension: $0.isFromShareExtension) { navigateToItem = $0; pendingImport = nil } }
        .onOpenURL { if $0.scheme == "wawanote" { Task { await scanSharedDirectoryAndImport() } } }
        .alert("Import Error", isPresented: .constant(importError != nil)) { Button("OK") { importError = nil } } message: { Text(importError ?? "") }
        .sheet(isPresented: $showCreationSheet) { CreationSheetView() }
        .onAppear { captureVM.bind(coordinator: coordinator) }
    }

    // MARK: - Default surface

    private var defaultSurface: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(.wawaSymbolGradient)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .shadow(color: .blue.opacity(0.15), radius: 12, y: 4)
                Text("wawa-note")
                    .font(.title2).fontWeight(.semibold)
                Text("Capture, organize, understand")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 48)
            .padding(.bottom, 24)

            if !projects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(projects.prefix(5)) { project in
                            NavigationLink(value: project) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill").font(.caption)
                                    Text(project.name).font(.subheadline).lineLimit(1)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 12)
            }

            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 16) {
                    Button(action: { captureVM.startRecording() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill")
                                .font(.title3).symbolRenderingMode(.hierarchical)
                            Text("Record").font(.headline)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(LinearGradient(colors: [.red, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button(action: { showFilePicker = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down").font(.subheadline)
                            Text("Import").font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 60, height: 52)
                        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button(action: { showCreationSheet = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.circle").font(.subheadline)
                            Text("New").font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 60, height: 52)
                        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background(.bar)
            }
        }
    }

    // MARK: - Recording panel

    private var recordingPanel: some View {
        let isPaused = captureVM.recordingState == .paused

        return VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 4) {
                Image(.wawaSymbolGradient)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                Text("wawa-note").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Recording indicator + timer
            HStack(spacing: 12) {
                Circle()
                    .fill(isPaused ? .orange : .red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(isPaused ? 1.0 : 1.3)
                    .animation(isPaused ? .default : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPaused)

                Text(isPaused ? "Paused" : "Recording")
                    .font(.headline)
                    .foregroundStyle(isPaused ? .orange : .red)

                Spacer()

                Text(captureVM.elapsedTimeFormatted)
                    .font(.system(.title2, design: .monospaced).bold())
            }
            .padding(.horizontal, 24)

            // Audio meter
            AudioLevelMeterView(level: captureVM.audioLevel)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            if let error = captureVM.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }

            Spacer()

            // Transport
            HStack(spacing: 32) {
                Button(action: { captureVM.stopRecording() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                }

                if isPaused {
                    Button(action: { captureVM.resumeRecording() }) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.green)
                    }
                } else {
                    Button(action: { captureVM.pauseRecording() }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)
                    }
                }

                Button(action: {
                    if let itemId = captureVM.savedItemId,
                       let svc = try? KnowledgeItemService(context: modelContext),
                       let item = try? svc.fetchItem(id: itemId) {
                        item.isFlagged.toggle()
                        try? modelContext.save()
                    }
                }) {
                    Image(systemName: "star")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Post-recording

    private var postRecordingPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            if let stage = captureVM.pipelineStage {
                HStack(spacing: 10) {
                    if stage != .ready {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(stage.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(stage == .ready ? .green : .secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(stage == .ready ? Color.green.opacity(0.08) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)

                if stage == .ready {
                    if let itemId = captureVM.savedItemId {
                        Button {
                            if let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemId) {
                                navigateToItem = item
                            }
                        } label: {
                            Label("Open Source Item", systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }

                    Button(action: { captureVM.finishCapture() }) {
                        Label("Done", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Import (unchanged)

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { importError = "No file was selected."; return }
            if urls.count == 1, let url = urls.first { stageSingleImport(url) }
            else { Task { await importFilePickerFiles(urls) } }
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
        await importFiles(urls, deleteSource: false)
    }

    private func scanSharedDirectoryAndImport() async {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else { return }
        let sharedDir = containerURL.appendingPathComponent("Shared", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sharedDir.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: sharedDir, includingPropertiesForKeys: nil) else { return }
        let pending = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !pending.isEmpty else { return }
        await importFiles(pending, deleteSource: true)
    }

    private func importFiles(_ urls: [URL], deleteSource: Bool) async {
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
                coordinator.createItemFromImport(title: metadata.suggestedTitle, date: metadata.creationDate ?? Date(), duration: metadata.duration)?.id
            }
            guard let itemId else { continue }
            let destURL = artifactStore.audioFileURL(for: itemId)
            do {
                if importService.isNativeM4ACompatible(tempURL) {
                    try artifactStore.copyAudioToMeeting(sourceURL: tempURL, meetingId: itemId)
                } else {
                    try await importService.convertToAAC(inputURL: tempURL, outputURL: destURL)
                }
                try? FileManager.default.removeItem(at: tempURL)
                if deleteSource { try? FileManager.default.removeItem(at: url) }
                imported += 1
                await MainActor.run { importProgress = "Importing \(imported)/\(total)..." }
            } catch {
                await MainActor.run { coordinator.deleteItem(itemId) }
            }
        }
        await MainActor.run { importProgress = nil }
    }

    private func backfillEmbeddingsIfNeeded() async {
        let flag = "embeddings_backfill_done_v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else { return }
        let pipeline = EmbeddingPipelineService()
        let items = (try? KnowledgeItemService(context: modelContext).allItems()) ?? []
        await pipeline.backfillAll(items: items, using: provider) { _, _ in }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

// MARK: - Supporting types

struct ImportPending: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: ImportMetadata
    let isFromShareExtension: Bool
}

struct AudioLevelMeterView: View {
    let level: Float
    private let barCount = 20

    var body: some View {
        GeometryReader { proxy in
            let barWidth = max(2, (proxy.size.width / CGFloat(barCount)) - 2)
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    let threshold = Float(i) / Float(barCount)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level > threshold ? (level > 0.7 ? .red : .orange) : .secondary.opacity(0.15))
                        .frame(width: barWidth, height: max(4, CGFloat(level > threshold ? level * 32 : 4)))
                }
            }
        }
        .frame(height: 40)
    }
}
