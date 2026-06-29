import AVFoundation
import PDFKit
import Speech
import SwiftData
import SwiftUI

// MARK: - Import kind

enum ImportKind {
    case audio(ImportMetadata)
    case text(TextImportPreview)
}

struct TextImportPreview {
    let formatIdentifier: String
    let displayName: String
    let suggestedTitle: String
    let fileSize: Int64
    let creationDate: Date?
    let textSnippet: String
}

extension ImportKind: Equatable {
    static func == (lhs: ImportKind, rhs: ImportKind) -> Bool {
        switch (lhs, rhs) {
        case (.audio, .audio): return true
        case (.text, .text): return true
        default: return false
        }
    }
}

// MARK: - Import form

struct ImportFormView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let sourceURL: URL
    let kind: ImportKind
    let textImporter: (any FormatImporter)?
    let onComplete: (KnowledgeItem) -> Void
    let isFromShareExtension: Bool

    @State private var title: String
    @State private var date: Date
    @State private var isConverting = false
    @State private var conversionPhase: String?
    @State private var errorMessage: String?
    @State private var player: AVAudioPlayer?
    @State private var selectedLocale: String = ""

    /// Locales whose on-device speech recognition model is actually downloaded
    /// and ready. Detected by probing each locale with a silent audio snippet.
    @State private var onDeviceLocales: [(code: String, label: String)] = []
    @State private var localesLoading = false
    @State private var localesLoaded = false

    /// Holder for the probe task so it can be cancelled on disappear.
    private let localeProbe = LocaleProbe()

    private func loadOnDeviceLocales() {
        guard !localesLoaded, !localesLoading else { return }
        localesLoading = true
        localeProbe.task?.cancel()
        localeProbe.task = Task.detached { [weak localeProbe] in
            let probe = await ImportFormView.probeLocales(candidateTranscriptionLocales)
            let formatter = Locale.current
            let result = probe.compactMap { id -> (String, String)? in
                guard let display = formatter.localizedString(forIdentifier: id) else { return nil }
                return (id, display)
            }
            await MainActor.run {
                onDeviceLocales = result
                localesLoading = false
                localesLoaded = true
                if !result.isEmpty {
                    selectedLocale = result.first!.0
                }
            }
        }
    }

    /// Probes each locale with a silent audio buffer. Returns only locales
    /// whose on-device model is actually downloaded.
    ///
    /// Uses `requiresOnDeviceRecognition = true` (public API) to force a model
    /// availability check. A recognition error in this mode means the model is
    /// not downloaded. A success or "no speech" result means the model is ready.
    /// Each locale gets up to 5 seconds via `withTaskGroup`; cancellation is
    /// handled cleanly without DispatchQueue.main.asyncAfter.
    private static func probeLocales(_ locales: [String]) async -> [String] {
        let sampleRate = 16000
        let sampleCount = sampleRate / 2
        var silence = Data(count: sampleCount * 2)
        silence.resetBytes(in: 0..<silence.count)
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("probe-\\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        guard writeWAV(url: url, pcmData: silence, sampleRate: sampleRate) else { return [] }

        var ready: [String] = []
        for localeId in locales {
            guard SFSpeechRecognizer(locale: Locale(identifier: localeId)) != nil else { continue }

            let modelReady = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return false
                }
                group.addTask {
                    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)),
                        recognizer.isAvailable
                    else { return false }
                    let request = SFSpeechURLRecognitionRequest(url: url)
                    request.shouldReportPartialResults = false
                    request.requiresOnDeviceRecognition = true
                    return await withCheckedContinuation { c in
                        recognizer.recognitionTask(with: request) { _, error in
                            // requiresOnDeviceRecognition means any error = model not ready.
                            // Success or "no speech" (nil error) = model is downloaded.
                            c.resume(returning: error == nil)
                        }
                    }
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if modelReady { ready.append(localeId) }
        }
        return ready
    }
    private static func writeWAV(url: URL, pcmData: Data, sampleRate: Int) -> Bool {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(channels * (bitsPerSample / 8))
        let dataSize = UInt32(pcmData.count)

        var file = Data()
        // RIFF header
        file.append(contentsOf: "RIFF".utf8)
        var riffSize = UInt32(36 + dataSize).littleEndian
        file.append(Data(bytes: &riffSize, count: 4))
        file.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        file.append(contentsOf: "fmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        file.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian  // PCM
        file.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels.littleEndian
        file.append(Data(bytes: &ch, count: 2))
        var sr = UInt32(sampleRate).littleEndian
        file.append(Data(bytes: &sr, count: 4))
        var br = byteRate.littleEndian
        file.append(Data(bytes: &br, count: 4))
        var ba = blockAlign.littleEndian
        file.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample.littleEndian
        file.append(Data(bytes: &bps, count: 2))
        // data chunk
        file.append(contentsOf: "data".utf8)
        var ds = dataSize.littleEndian
        file.append(Data(bytes: &ds, count: 4))
        file.append(pcmData)

        return (try? file.write(to: url)) != nil
    }

    /// Candidate transcription locales: device language + en-US + preferred languages.
    private var candidateTranscriptionLocales: [String] {
        var ids = [String]()
        let deviceId = Locale.current.identifier  // e.g. pt-BR
        ids.append(deviceId)
        if !ids.contains("en-US") { ids.append("en-US") }
        for lang in Locale.preferredLanguages {
            let localeId = Locale(identifier: lang).identifier
            if !ids.contains(localeId) { ids.append(localeId) }
        }
        return ids
    }

    private let importService = AudioImportService()
    private let artifactStore = FileArtifactStore()

    init(
        sourceURL: URL,
        kind: ImportKind,
        textImporter: (any FormatImporter)? = nil,
        isFromShareExtension: Bool = false,
        onComplete: @escaping (KnowledgeItem) -> Void
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.textImporter = textImporter
        self.isFromShareExtension = isFromShareExtension
        self.onComplete = onComplete

        let defaultTitle: String
        let defaultDate: Date?

        switch kind {
        case .audio(let meta):
            defaultTitle = meta.suggestedTitle
            defaultDate = meta.creationDate
        case .text(let preview):
            defaultTitle = preview.suggestedTitle
            defaultDate = preview.creationDate
        }

        _title = State(initialValue: defaultTitle)
        _date = State(initialValue: defaultDate ?? Date())
        _selectedLocale = State(initialValue: Locale.current.identifier)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker("Date", selection: $date)
                    if isAudio {
                        if localesLoading {
                            HStack {
                                ProgressView()
                                Text("Detecting available languages…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                            }
                        } else if !onDeviceLocales.isEmpty {
                            Picker("Language", selection: $selectedLocale) {
                                ForEach(onDeviceLocales, id: \.0) { locale in
                                    Text(locale.1).tag(locale.0)
                                }
                            }
                        }
                    }
                } header: {
                    Text(isAudio ? "Audio Info" : "Note Info")
                }

                Section("File Info") {
                    fileInfoContent
                }

                Section("Preview") {
                    previewContent
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
                            Label(confirmLabel, systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(title.isEmpty || isConverting)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if isAudio {
                    player = importService.previewPlayer(for: sourceURL)
                    loadOnDeviceLocales()
                }
            }
            .onDisappear {
                player?.stop()
                localeProbe.task?.cancel()
            }
        }
    }

    // MARK: - Labels

    private var isAudio: Bool {
        if case .audio = kind { return true }
        return false
    }

    private var navTitle: String {
        isAudio ? "Import Audio" : "Import Note"
    }

    private var confirmLabel: String {
        isAudio ? "Import Audio" : "Import Note"
    }

    // MARK: - File info

    @ViewBuilder
    private var fileInfoContent: some View {
        switch kind {
        case .audio(let meta):
            LabeledContent("Duration", value: formatDuration(meta.duration))
            LabeledContent("Format", value: meta.format)
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: meta.fileSize, countStyle: .file))

        case .text(let preview):
            LabeledContent("Type", value: preview.displayName)
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewContent: some View {
        switch kind {
        case .audio:
            Button {
                togglePreview()
            } label: {
                Label(
                    player?.isPlaying == true ? "Stop" : "Play",
                    systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
            }
            .disabled(player == nil)

        case .text(let preview):
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.textSnippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                if !preview.textSnippet.isEmpty {
                    Text("First \(preview.textSnippet.count) characters")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func togglePreview() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    // MARK: - Import

    private func performImport() {
        switch kind {
        case .audio:
            performAudioImport()
        case .text:
            performTextImport()
        }
    }

    private func performAudioImport() {
        isConverting = true
        errorMessage = nil
        conversionPhase = "Preparing file..."

        guard case .audio(let meta) = kind else { return }

        guard
            let item = coordinator.createItemFromImport(
                title: title,
                date: date,
                duration: meta.duration,
                languageCode: selectedLocale.isEmpty ? nil : selectedLocale
            )
        else {
            errorMessage = "Could not create item."
            isConverting = false
            return
        }

        let itemId = item.id

        Task { @MainActor in
            do {
                if !importService.isNativeM4ACompatible(sourceURL) {
                    conversionPhase = "Converting to app format..."
                }
                try await importService.storeAudio(sourceURL: sourceURL, itemID: itemId, using: artifactStore)

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

    private func performTextImport() {
        guard let importer = textImporter else {
            errorMessage = "No importer available for this file type."
            return
        }

        isConverting = true
        conversionPhase = "Reading file..."
        errorMessage = nil

        Task {
            do {
                // Use the FormatImporter to properly transform content
                let result = try await importer.importFromURL(sourceURL)
                let item = result.knowledgeItem

                // Apply user's edits on top of importer result
                item.title = title
                item.createdAt = date

                await MainActor.run {
                    modelContext.insert(item)
                    try? modelContext.save()

                    isConverting = false
                    conversionPhase = nil
                    onComplete(item)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Import failed: \(error.localizedDescription)"
                    isConverting = false
                    conversionPhase = nil
                }
            }
        }
    }

    // MARK: - Helpers

    private func cleanupSourceFiles(sourceURL: URL, isFromShareExtension: Bool) {
        if sourceURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        if isFromShareExtension {
            try? FileManager.default.removeItem(at: sourceURL)
            let shared = UserDefaults(suiteName: "group.com.wawa-note")
            shared?.removeObject(forKey: "pendingImportFiles")
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return "\(m)m \(s)s"
    }
}

// MARK: - Locale Probe State

/// Holds a reference to the locale probe task so it can be cancelled
/// when the view disappears. SwiftUI @State cannot store Task directly.
private final class LocaleProbe {
    var task: Task<Void, Never>?
}
