import SwiftUI
import SwiftData

struct KnowledgeDetailView: View {
    let item: KnowledgeItem
    @Environment(\.modelContext) private var modelContext
    @State private var transcript: Transcript?
    @State private var analysis: MeetingAnalysis?
    @State private var annotations: [Annotation] = []
    @State private var isTranscribing = false
    @State private var transcriptionError: String?
    @State private var transcriptionProgress: String?
    @State private var showPromoteSheet = false
    @State private var selectedLocale = "pt-BR"
    @State private var showLocalePicker = false

    private let fileStore = FileArtifactStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)

                if isTranscribing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(transcriptionProgress ?? "Transcribing...")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                if let error = transcriptionError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).font(.subheadline)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                Divider().padding(.top, 16)

                switch item.type {
                case .meeting:
                    meetingSections
                case .note, .journalEntry:
                    textContentSection
                case .webBookmark:
                    bookmarkSection
                case .image:
                    imageSection
                }

                if !annotations.isEmpty {
                    annotationsSection
                        .padding(.top, 20)
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showPromoteSheet = true
                    } label: {
                        Label("Promote", systemImage: "sparkles.rectangle.stack")
                    }

                    if let transcript {
                        Menu {
                            ShareLink(item: MarkdownExporter().export(item: item, transcript: transcript, analysis: analysis))
                            if let jsonData = try? JSONExporter().export(item: item, transcript: transcript, analysis: analysis),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                ShareLink(item: jsonString)
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showPromoteSheet) {
            PromoteToProjectSheet(item: item) { _ in
                showPromoteSheet = false
            }
        }
        .onAppear { loadData() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: typeIcon)
                    .font(.title)
                    .foregroundStyle(typeColor)
                    .frame(width: 40, height: 40)
                    .background(typeColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.title3).fontWeight(.bold)
                    Text(item.type.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.caption)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = item.durationSeconds {
                    Circle().frame(width: 3, height: 3).foregroundStyle(.secondary)
                    Text(formatDuration(duration))
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            if !badges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.title) { badge in
                            AppStatusBadge(title: badge.title, systemImage: badge.icon, tone: badge.tone)
                        }
                    }
                }
            }
        }
    }

    private var badges: [(title: String, icon: String?, tone: BadgeTone)] {
        var b: [(String, String?, BadgeTone)] = []
        if item.audioFileRelativePath != nil { b.append(("Audio", "mic", .success)) }
        if item.transcriptionEngineId != nil { b.append(("Transcribed", "text.alignleft", .success)) }
        if item.analysisProviderId != nil { b.append(("Analyzed", "sparkles", .success)) }
        if let cal = item.contextCalendarEventTitle { b.append((cal, "calendar", .neutral)) }
        if let route = item.contextAudioRoute { b.append((route, "airpodspro", .neutral)) }
        return b
    }

    // MARK: - Meeting sections

    @ViewBuilder
    private var meetingSections: some View {
        if let analysis {
            sectionHeader("Summary", icon: "sparkles").padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 16) {
                if !analysis.shortSummary.isEmpty {
                    card(title: "Summary", systemImage: "doc.text") {
                        Text(analysis.shortSummary).font(.body)
                    }
                }
                if !analysis.actionItems.isEmpty {
                    card(title: "Action Items", systemImage: "checklist") {
                        ForEach(analysis.actionItems) { action in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle").font(.caption).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.task).font(.body)
                                    if let owner = action.owner {
                                        Text(owner).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }

        if let transcript {
            let groups = transcript.groupedSegments()

            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Transcript", icon: "text.alignleft")
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("[\(formatTime(group.startTime))]")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                if let conf = group.confidence {
                                    Text("\(Int(conf * 100))%")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Text(group.text)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)

                        if idx < groups.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(12)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        } else if item.audioFileRelativePath != nil && !isTranscribing {
            VStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No transcript yet")
                    .font(.headline)
                Text("This meeting has audio but hasn't been transcribed.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                // Locale picker
                Button {
                    showLocalePicker.toggle()
                } label: {
                    HStack {
                        Text("Language: \(localeName(selectedLocale))")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }

                if showLocalePicker {
                    localePickerView
                }

                Button("Transcribe Now") {
                    Task { await transcribe() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Text content (notes, journal)

    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let body = item.bodyText, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.title.isEmpty ? "No content yet" : item.title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Bookmark

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let urlStr = item.importSourceURL, let url = URL(string: urlStr) {
                Link(destination: url) {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Image placeholder

    private var imageSection: some View {
        Text("Image preview not yet available")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }

    // MARK: - Annotations

    private var annotationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context").font(.headline)
            ForEach(groupedAnnotationKeys.sorted(by: <), id: \.self) { key in
                if let values = groupedAnnotations[key] {
                    HStack(spacing: 4) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(values.joined(separator: ", "))
                            .font(.caption)
                    }
                    Divider()
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var groupedAnnotations: [String: [String]] {
        var result: [String: [String]] = [:]
        for ann in annotations {
            result[ann.key, default: []].append(ann.value)
        }
        return result
    }

    private var groupedAnnotationKeys: [String] {
        Array(groupedAnnotations.keys)
    }

    // MARK: - Locale picker

    private let availableLocales: [(id: String, name: String)] = [
        ("pt-BR", "Português (Brasil)"),
        ("pt-PT", "Português (Portugal)"),
        ("en-US", "English (US)"),
        ("es-ES", "Español"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"),
        ("ja-JP", "日本語"),
        ("zh-CN", "中文"),
    ]

    private var localePickerView: some View {
        VStack(spacing: 0) {
            ForEach(availableLocales, id: \.id) { locale in
                Button {
                    selectedLocale = locale.id
                    showLocalePicker = false
                } label: {
                    HStack {
                        Text(locale.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedLocale == locale.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                if locale.id != availableLocales.last?.id {
                    Divider()
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func localeName(_ id: String) -> String {
        availableLocales.first { $0.id == id }?.name ?? id
    }

    // MARK: - Transcription

    private func transcribe() async {
        let audioURL = fileStore.audioFileURL(for: item.id)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            transcriptionError = "Audio file not found."
            return
        }

        isTranscribing = true
        transcriptionError = nil
        transcriptionProgress = nil

        // Resolve engine
        let engine: TranscriptionEngine
        if let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
           config.supportsAudio,
           let baseURL = config.baseURL {
            var apiKey = ""
            if let keyId = config.apiKeyKeychainIdentifier {
                apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
            }
            let remote = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
            remote.onProgress = { progress in
                Task { @MainActor in
                    switch progress {
                    case .chunking(let c, let t): self.transcriptionProgress = "Splitting... (\(c)/\(t))"
                    case .transcribing(let c, let t): self.transcriptionProgress = "Part \(c) of \(t)..."
                    }
                }
            }
            engine = remote
        } else {
            var local = AppleSpeechTranscriptionEngine(preferredLocale: selectedLocale)
            local.onProgress = { progress in
                Task { @MainActor in
                    switch progress {
                    case .chunking(let c, let t): self.transcriptionProgress = "Splitting... (\(c)/\(t))"
                    case .transcribing(let c, let t): self.transcriptionProgress = "Part \(c) of \(t)..."
                    }
                }
            }
            engine = local
        }

        do {
            var result = try await engine.transcribeFile(audioURL)
            result.meetingId = item.id
            result.segments = result.segments.map { var f = $0; f.meetingId = item.id; return f }
            transcript = result

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: item.id)

            if item.type == .meeting { item.status = .transcribed }
            item.transcriptionEngineId = engine.id

            // Auto-generate embedding after transcription
            if let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
               let provider = try? ProviderRouter().provider(for: config) {
                let pipeline = EmbeddingPipelineService()
                await pipeline.ensureEmbedding(for: item, using: provider)
            }
        } catch let error as TranscriptionError {
            switch error {
            case .notAuthorized: transcriptionError = "Speech recognition off. Enable in Settings."
            case .cancelled: transcriptionProgress = "Paused."
            case .noSupportedLocale: transcriptionError = "Language not supported."
            case .fileTooLarge: transcriptionError = "File too large for remote API."
            case .recognitionFailed: transcriptionError = "No speech detected or recognition failed. Record at least 5s of clear speech."
            case .fileTooLongForLocal(let d): transcriptionError = "Audio too long for local (max \(Int(d))s)."
            }
        } catch {
            transcriptionError = "\(error.localizedDescription) [\(type(of: error))]"
        }

        isTranscribing = false
        transcriptionProgress = nil
    }

    // MARK: - Helpers

    private func loadData() {
        transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id)
        analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)

        let annService = AnnotationService(context: modelContext)
        annotations = (try? annService.annotations(for: item.id)) ?? []

        // Auto-extract entities and build decision graph from analysis
        if let analysis, item.type == .meeting {
            let extractor = EntityExtractionService(context: modelContext)
            _ = try? extractor.extractAndPersist(from: analysis, sourceItemID: item.id)
            try? extractor.buildDecisionGraph(from: analysis, sourceItemID: item.id)
        }
    }

    private var typeIcon: String { item.type.icon }
    private var typeColor: Color { item.type.color }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
