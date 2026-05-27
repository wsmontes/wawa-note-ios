import SwiftUI
import AVFoundation

struct ImportFormView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss

    let sourceURL: URL
    let metadata: ImportMetadata
    let onComplete: (KnowledgeItem) -> Void
    let isFromShareExtension: Bool

    @State private var title: String
    @State private var date: Date
    @State private var isConverting = false
    @State private var conversionPhase: String?
    @State private var errorMessage: String?
    @State private var player: AVAudioPlayer?

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()

    init(sourceURL: URL, metadata: ImportMetadata, isFromShareExtension: Bool = false, onComplete: @escaping (KnowledgeItem) -> Void) {
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.isFromShareExtension = isFromShareExtension
        self.onComplete = onComplete
        _title = State(initialValue: metadata.suggestedTitle)
        _date = State(initialValue: metadata.creationDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Meeting Info") {
                    TextField("Title", text: $title)
                    DatePicker("Date", selection: $date)
                }

                Section("File Info") {
                    LabeledContent("Duration", value: formatDuration(metadata.duration))
                    LabeledContent("Format", value: metadata.format)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: metadata.fileSize, countStyle: .file))
                }

                Section("Preview") {
                    previewButton
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        performImport()
                    } label: {
                        if isConverting {
                            HStack {
                                ProgressView()
                                Text(conversionPhase ?? "Processing...")
                                    .padding(.leading, 8)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Import Meeting", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(title.isEmpty || isConverting)
                }
            }
            .navigationTitle("Import Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                player = importService.previewPlayer(for: sourceURL)
            }
            .onDisappear {
                player?.stop()
            }
        }
    }

    // MARK: - Preview

    private var previewButton: some View {
        Button {
            togglePreview()
        } label: {
            Label(player?.isPlaying == true ? "Stop" : "Play",
                  systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
        }
        .disabled(player == nil)
    }

    private func togglePreview() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    // MARK: - Import

    private func performImport() {
        isConverting = true
        errorMessage = nil
        conversionPhase = "Preparing file..."

        // Create item on main actor (SwiftData requires it)
        guard let item = coordinator.createItemFromImport(
            title: title,
            date: date,
            duration: metadata.duration
        ) else {
            errorMessage = "Could not create item."
            isConverting = false
            return
        }

        let itemId = item.id
        let destURL = artifactStore.audioFileURL(for: itemId)

        Task { @MainActor in
            do {
                if importService.isNativeM4ACompatible(sourceURL) {
                    try artifactStore.copyAudioToMeeting(sourceURL: sourceURL, meetingId: itemId)
                } else {
                    conversionPhase = "Converting to app format..."
                    try await Task.detached {
                        try await importService.convertToAAC(inputURL: sourceURL, outputURL: destURL)
                    }.value
                }

                cleanupSourceFiles(sourceURL: sourceURL, isFromShareExtension: isFromShareExtension)

                isConverting = false
                conversionPhase = nil
                onComplete(item)
                dismiss()
            } catch {
                coordinator.deleteItem(itemId)
                errorMessage = error.localizedDescription
                isConverting = false
                conversionPhase = nil
            }
        }
    }

    private func cleanupSourceFiles(sourceURL: URL, isFromShareExtension: Bool) {
        if sourceURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        if isFromShareExtension {
            try? FileManager.default.removeItem(at: sourceURL)
            let shared = UserDefaults(suiteName: "group.com.wawa-note")
            shared?.removeObject(forKey: "pendingImportFile")
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return "\(m)m \(s)s"
    }
}
