import SwiftUI
import SwiftData
import UIKit

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published var transcript: Transcript?
    @Published var isTranscribing = false
    @Published var transcriptionError: String?
    @Published var transcriptionProgress: String?

    @Published var analysis: MeetingAnalysis?
    @Published var isAnalyzing = false
    @Published var analysisError: String?
    @Published var analysisProgress: String?

    private let localEngine: TranscriptionEngine
    private let analysisService: AnalysisService
    private let fileStore: FileArtifactStore
    private let router: ProviderRouter
    private let markdownExporter = MarkdownExporter()
    private let jsonExporter = JSONExporter()
    private var modelContext: ModelContext?
    private var transcriptionTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(
        localEngine: TranscriptionEngine = AppleSpeechTranscriptionEngine(),
        analysisService: AnalysisService = AnalysisService(),
        fileStore: FileArtifactStore = FileArtifactStore(),
        router: ProviderRouter = ProviderRouter()
    ) {
        self.localEngine = localEngine
        self.analysisService = analysisService
        self.fileStore = fileStore
        self.router = router
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        (localEngine as? AppleSpeechTranscriptionEngine)?.cancel()
    }

    func retryTranscription(meeting: MeetingModel) {
        transcriptionError = nil
        transcriptionProgress = nil
        transcriptionTask = Task { await transcribe(meeting: meeting) }
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Transcript

    func loadTranscript(for meeting: MeetingModel) {
        guard let _ = meeting.audioFileRelativePath else { return }
        do {
            transcript = try fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: meeting.id)
        } catch {
            // Not generated yet
        }
    }

    func loadAnalysis(for meeting: MeetingModel) {
        do {
            analysis = try fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: meeting.id)
        } catch {
            // Not generated yet
        }
    }

    func transcribe(meeting: MeetingModel) async {
        let audioURL = fileStore.audioFileURL(for: meeting.id)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            transcriptionError = "Audio file not found."
            return
        }

        isTranscribing = true
        transcriptionError = nil
        transcriptionProgress = nil

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "transcription") { [weak self] in
            AppLog.general.warning("Background task expiring, cancelling transcription")
            self?.cancelTranscription()
        }

        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
            isTranscribing = false
            transcriptionProgress = nil
        }

        // Check for partial transcript (resume from checkpoint)
        let meetingId = meeting.id
        var resumeSegments: [TranscriptSegment] = []
        var resumeLanguage: String?
        var resumeChunkIndex = 0
        if let checkpoint = try? fileStore.readPartialCheckpoint(meetingId: meetingId),
           let partial = try? fileStore.readPartialTranscript(meetingId: meetingId) {
            resumeSegments = partial.segments
            resumeLanguage = partial.languageCode
            resumeChunkIndex = checkpoint.completedChunks
            AppLog.transcription.info("Resuming from checkpoint: \(resumeChunkIndex) chunks, \(resumeSegments.count) segments")
        }

        // Resolve engine
        let engine: TranscriptionEngine
        if let context = modelContext,
           let config = ActiveProviderManager.shared.getActiveProvider(context: context),
           config.supportsAudio,
           let baseURL = config.baseURL {
            var apiKey = ""
            if let keyId = config.apiKeyKeychainIdentifier {
                apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
            }
            let remote = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
            remote.onProgress = { [weak self] progress in
                Task { @MainActor in
                    switch progress {
                    case .chunking(let completed, let total):
                        self?.transcriptionProgress = "Splitting audio... (\(completed)/\(total))"
                    case .transcribing(let chunk, let totalChunks):
                        self?.transcriptionProgress = "Transcribing part \(chunk) of \(totalChunks)..."
                    }
                }
            }
            remote.onCheckpoint = { [weak self] partial, completed in
                let checkpoint = TranscriptionCheckpoint(
                    completedChunks: completed,
                    segments: partial.segments,
                    languageCode: partial.languageCode,
                    sourceEngineId: partial.sourceEngineId,
                    savedAt: Date()
                )
                try? self?.fileStore.writePartialTranscript(partial, checkpoint: checkpoint, meetingId: meetingId)
            }
            engine = remote
        } else {
            let local = localEngine as? AppleSpeechTranscriptionEngine ?? AppleSpeechTranscriptionEngine()
            local.onProgress = { [weak self] progress in
                Task { @MainActor in
                    switch progress {
                    case .chunking(let completed, let total):
                        self?.transcriptionProgress = "Splitting audio... (\(completed)/\(total))"
                    case .transcribing(let chunk, let totalChunks):
                        self?.transcriptionProgress = "Transcribing part \(chunk) of \(totalChunks)..."
                    }
                }
            }
            local.onCheckpoint = { [weak self] partial, completed in
                let checkpoint = TranscriptionCheckpoint(
                    completedChunks: completed,
                    segments: partial.segments,
                    languageCode: partial.languageCode,
                    sourceEngineId: partial.sourceEngineId,
                    savedAt: Date()
                )
                try? self?.fileStore.writePartialTranscript(partial, checkpoint: checkpoint, meetingId: meetingId)
            }
            engine = local
        }

        do {
            var result = try await engine.transcribeFile(audioURL)
            result.meetingId = meeting.id

            result.segments = result.segments.map { segment in
                var fixed = segment
                fixed.meetingId = meeting.id
                return fixed
            }

            // Merge with resumed segments if any
            if !resumeSegments.isEmpty {
                result.segments = resumeSegments + result.segments
                result.languageCode = result.languageCode ?? resumeLanguage
            }

            transcript = result

            try fileStore.createMeetingDirectory(for: meeting.id)
            try fileStore.commitPartialTranscript(meetingId: meeting.id)
            try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: meeting.id)

            meeting.status = .transcribed
            meeting.transcriptionEngineId = engine.id

        } catch let error as TranscriptionError {
            switch error {
            case .cancelled:
                transcriptionError = nil
                transcriptionProgress = "Paused. Tap Retry to continue."
            case .notAuthorized:
                transcriptionError = "Speech recognition not authorized. Enable it in Settings."
            case .noSupportedLocale:
                transcriptionError = "Your device does not support speech recognition for your language."
            case .fileTooLarge:
                transcriptionError = "Audio chunk too large for remote API. Split the file or use a smaller recording."
            case .fileTooLongForLocal(let seconds):
                let mins = Int(seconds / 60)
                transcriptionError = "This recording is \(mins) min. On-device transcription supports up to 60 min. Connect a remote transcription provider in Settings for longer files."
            default:
                transcriptionError = "Transcription failed. You can retry."
            }
        } catch {
            transcriptionError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto pipeline

    func autoStartPipeline(for meeting: MeetingModel) {
        guard meeting.audioFileRelativePath != nil else { return }

        if transcript == nil && !isTranscribing {
            transcriptionTask = Task {
                await transcribe(meeting: meeting)
                if transcript != nil, transcriptionError == nil {
                    await analyze(meeting: meeting)
                }
            }
        } else if transcript != nil && analysis == nil && !isAnalyzing {
            Task { await analyze(meeting: meeting) }
        }
    }

    // MARK: - Analysis

    func analyze(meeting: MeetingModel) async {
        guard let transcript else { return }
        guard let context = modelContext else {
            analysisError = "App is still loading. Please try again."
            return
        }

        isAnalyzing = true
        analysisError = nil
        analysisProgress = nil

        analysisService.onProgress = { [weak self] progress in
            Task { @MainActor in
                switch progress {
                case .mapping(let current, let total):
                    self?.analysisProgress = "Summarizing part \(current) of \(total)..."
                case .reducing:
                    self?.analysisProgress = "Consolidating..."
                case .done:
                    self?.analysisProgress = nil
                }
            }
        }

        guard let config = ActiveProviderManager.shared.getActiveProvider(context: context) else {
            analysisError = "No AI service connected. Go to Settings > AI Services to connect one."
            isAnalyzing = false
            return
        }

        let provider: any AIProvider
        do {
            provider = try router.provider(for: config)
        } catch let error as ProviderError {
            analysisError = error.userMessage
            isAnalyzing = false
            return
        } catch {
            analysisError = "Could not connect to provider."
            isAnalyzing = false
            return
        }

        do {
            let result = try await analysisService.analyze(
                transcript: transcript,
                using: provider,
                model: config.defaultModel
            )

            analysis = result

            try fileStore.createMeetingDirectory(for: meeting.id)
            try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: meeting.id)

            meeting.status = .analyzed
            meeting.analysisProviderId = provider.id

        } catch let error as ProviderError {
            analysisError = error.userMessage
        } catch {
            analysisError = "Analysis failed. Check your connection and try again."
        }

        isAnalyzing = false
    }

    // MARK: - Export

    func exportMarkdown(for meeting: MeetingModel) -> String {
        markdownExporter.export(meeting: meeting, transcript: transcript, analysis: analysis)
    }

    func exportJSON(for meeting: MeetingModel) -> URL? {
        guard let data = try? jsonExporter.export(meeting: meeting, transcript: transcript, analysis: analysis) else {
            return nil
        }
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("\(meeting.title).json")
        try? data.write(to: url)
        return url
    }
}

// MARK: - View

struct MeetingDetailView: View {
    let meeting: MeetingModel
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = MeetingDetailViewModel()

    @State private var selectedSection = 0

    private let sections = ["Summary", "Transcript"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Divider()

                Picker("Section", selection: $selectedSection) {
                    ForEach(0..<sections.count, id: \.self) { i in
                        Text(sections[i]).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                // Processing pipeline — always visible
                processingPipeline

                if selectedSection == 0 {
                    analysisSection
                } else {
                    transcriptSection
                }
            }
            .padding(.vertical, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.transcript != nil || viewModel.analysis != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: viewModel.exportMarkdown(for: meeting))
                        if let jsonURL = viewModel.exportJSON(for: meeting) {
                            ShareLink(item: jsonURL)
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadTranscript(for: meeting)
            viewModel.loadAnalysis(for: meeting)
            viewModel.autoStartPipeline(for: meeting)
        }
    }

    // MARK: - Processing pipeline

    private var processingPipeline: some View {
        VStack(spacing: 8) {
            pipelineStep(
                icon: "mic.circle.fill",
                label: "Audio recorded",
                isComplete: true
            )
            Divider()
            pipelineStep(
                icon: "text.alignleft",
                label: viewModel.isTranscribing ? "Transcribing..." : "Transcript",
                isComplete: viewModel.transcript != nil,
                isActive: viewModel.isTranscribing
            )
            Divider()
            pipelineStep(
                icon: "sparkles",
                label: viewModel.isAnalyzing ? "Creating summary..." : "Summary",
                isComplete: viewModel.analysis != nil,
                isActive: viewModel.isAnalyzing
            )
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func pipelineStep(icon: String, label: String, isComplete: Bool, isActive: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(isComplete ? .green : isActive ? .blue : .secondary)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isComplete || isActive ? .primary : .secondary)
            Spacer()
            if isActive {
                ProgressView()
                    .controlSize(.small)
            } else if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 12) {
                Text(meeting.createdAt, style: .date)
                Text(meeting.createdAt, style: .time)
                if let duration = meeting.durationSeconds {
                    Text("·")
                    Text(formatDuration(duration))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                AppStatusBadge(title: meeting.status.rawValue.capitalized, tone: statusTone)
                if meeting.transcriptionEngineId != nil {
                    AppStatusBadge(title: "Transcribed", systemImage: "text.alignleft", tone: .success)
                }
                if meeting.analysisProviderId != nil {
                    AppStatusBadge(title: "Analyzed", systemImage: "sparkles", tone: .success)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Analysis

    @ViewBuilder
    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = viewModel.analysisError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await viewModel.analyze(meeting: meeting) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
            }

            if viewModel.isAnalyzing {
                VStack(spacing: 6) {
                    ProgressView()
                    Text(viewModel.analysisProgress ?? "Analyzing meeting...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }

            if let analysis = viewModel.analysis {
                analysisContent(analysis)
            } else if viewModel.analysisError == nil && !viewModel.isAnalyzing && viewModel.transcript != nil {
                VStack(spacing: 12) {
                    Text("Summary not yet generated.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await viewModel.analyze(meeting: meeting) }
                    } label: {
                        Label("Generate Summary", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else if viewModel.transcript == nil {
                Text("Transcribe the meeting first, then generate a summary.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func analysisContent(_ analysis: MeetingAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Short summary
            if !analysis.shortSummary.isEmpty {
                card(title: "Summary", systemImage: "doc.text") {
                    Text(analysis.shortSummary).font(.body)
                }
            }

            // Action items
            if !analysis.actionItems.isEmpty {
                card(title: "Action Items", systemImage: "checklist") {
                    ForEach(analysis.actionItems) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle")
                                .font(.caption)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task).font(.body)
                                if let owner = item.owner {
                                    Text(owner)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Decisions
            if !analysis.decisions.isEmpty {
                card(title: "Decisions", systemImage: "checkmark.seal") {
                    ForEach(analysis.decisions) { decision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(decision.title).font(.body).fontWeight(.medium)
                            if !decision.details.isEmpty {
                                Text(decision.details)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Risks
            if !analysis.risks.isEmpty {
                card(title: "Risks", systemImage: "exclamationmark.triangle") {
                    ForEach(analysis.risks) { risk in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.risk).font(.body)
                            if !risk.details.isEmpty {
                                Text(risk.details)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Open questions
            if !analysis.openQuestions.isEmpty {
                card(title: "Open Questions", systemImage: "questionmark.circle") {
                    ForEach(analysis.openQuestions) { q in
                        Text(q.question).font(.body).padding(.vertical, 2)
                    }
                }
            }

            // Detailed summary
            if !analysis.detailedSummary.isEmpty && analysis.detailedSummary != analysis.shortSummary {
                card(title: "Detailed Summary", systemImage: "doc.text.fill") {
                    Text(analysis.detailedSummary).font(.body)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = viewModel.transcriptionError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        viewModel.retryTranscription(meeting: meeting)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
            }

            if viewModel.isTranscribing {
                VStack(spacing: 8) {
                    if let progress = viewModel.transcriptionProgress {
                        Text(progress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView()
                        .tint(.blue)
                    Button("Cancel") {
                        viewModel.cancelTranscription()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
            }

            if let transcript = viewModel.transcript {
                ForEach(transcript.segments) { segment in
                    transcriptSegmentRow(segment)
                        .padding(.horizontal, 16)
                }
            } else if viewModel.transcriptionError == nil && !viewModel.isTranscribing {
                VStack(spacing: 12) {
                    if viewModel.transcriptionProgress != nil {
                        Text(viewModel.transcriptionProgress!)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Transcript not ready.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        viewModel.retryTranscription(meeting: meeting)
                    } label: {
                        Label("Transcribe Meeting", systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private func transcriptSegmentRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatTime(segment.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let confidence = segment.confidence {
                    Text("· \(Int(confidence * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(segment.text)
                .font(.body)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private var statusTone: BadgeTone {
        switch meeting.status {
        case .transcribed, .analyzed: .success
        case .failed: .error
        case .transcribing, .analyzing, .recording: .warning
        default: .neutral
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 {
            return "\(m / 60)h \(m % 60)m"
        }
        return "\(m)m"
    }
}
