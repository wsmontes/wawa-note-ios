import SwiftUI
import SwiftData

struct KnowledgeDetailView: View {
    let item: KnowledgeItem
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @State private var transcript: Transcript?
    @State private var analysis: MeetingAnalysis?
    @State private var annotations: [Annotation] = []
    @State private var isTranscribing = false
    @State private var transcriptionError: String?
    @State private var transcriptionProgress: String?
    @State private var showPromoteSheet = false
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var selectedModel: String = ""
    @State private var selectedLocale = "pt-BR"
    @State private var showLocalePicker = false
    @State private var isEditing = false
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var backlinks: [(edge: GraphEdge, sourceItem: KnowledgeItem)] = []
    @State private var isPipelineProcessing = false
    @State private var isReprocessing = false

    private let fileStore = FileArtifactStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)

                if isTranscribing || isPipelineProcessing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(transcriptionProgress ?? (isPipelineProcessing ? "Processing..." : "Transcribing..."))
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

                // Analysis always at the top — like every other item type
                if transcript != nil || analysis != nil { artifactSections }

                // Image gallery + OCR for scanned documents
                if item.type == .image { imageSection }

                // Body text for notes, journals, and any non-image item with bodyText
                // Images: OCR text already shown inside imageSection
                if (item.bodyText != nil && item.type != .image) || item.type == .note || item.type == .journalEntry { textContentSection }
                if item.type == .webBookmark { bookmarkSection }

                if !annotations.isEmpty {
                    annotationsSection
                        .padding(.top, 20)
                }

                if !backlinks.isEmpty {
                    backlinksSection
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if item.bodyText != nil {
                        if isEditing {
                            Button("Save") { saveEdits() }
                                .fontWeight(.semibold)
                            Button("Cancel") { cancelEditing() }
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Edit") { startEditing() }
                        }
                    }

                    Button {
                        showPromoteSheet = true
                    } label: {
                        Label("Turn into Project", systemImage: "sparkles.rectangle.stack")
                    }

                    if item.analysisProviderId != nil || isPipelineProcessing || isReprocessing {
                        Button {
                            Task { await reprocessItem() }
                        } label: {
                            Label("Re-analyze", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isReprocessing || isPipelineProcessing)
                    }

                    if transcript != nil || (item.type == .image && item.bodyText != nil) || item.type == .note || item.type == .journalEntry {
                        Menu {
                            ShareLink("Markdown", item: MarkdownExporter().export(item: item, transcript: transcript, analysis: analysis))
                            if let jsonData = try? JSONExporter().export(item: item, transcript: transcript, analysis: analysis),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                ShareLink("JSON Export", item: jsonString)
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
        .onAppear {
            isPipelineProcessing = contentPipeline.isProcessingItem(item.id)
            Task { @MainActor in
                await Task.yield()
                loadData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pipelineCompleted)) { n in
            if n.object as? String == item.id.uuidString {
                isPipelineProcessing = false
                Task { @MainActor in loadData() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptReady)) { _ in
            Task { @MainActor in
                transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id)
                isTranscribing = false; transcriptionProgress = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .analysisReady)) { _ in
            Task { @MainActor in
                analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
                isAnalyzing = false
                loadData()
            }
        }
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
                    if isEditing {
                        TextField("Title", text: $editedTitle, axis: .vertical)
                            .font(.title3).fontWeight(.bold)
                    } else {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.title3).fontWeight(.bold)
                    }
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
        else if item.audioFileRelativePath != nil { b.append(("Not transcribed", "text.alignleft", .warning)) }
        if item.analysisProviderId != nil {
            let modelName = item.analysisProviderId ?? ""
            b.append(("Analyzed · \(modelName)", "sparkles", .success))
        } else if item.bodyText != nil && !item.bodyText!.isEmpty {
            b.append(("Analysis pending", "sparkles", .neutral))
        }
        if item.projectID != nil { b.append((projectName ?? "In project", "folder", .success)) }
        else { b.append(("No project", "folder", .neutral)) }
        if let cal = item.contextCalendarEventTitle { b.append((cal, "calendar", .neutral)) }
        if let route = item.contextAudioRoute { b.append((route, "airpodspro", .neutral)) }
        return b
    }

    private var projectName: String? {
        guard let pid = item.projectID else { return nil }
        var desc = FetchDescriptor<Project>(predicate: #Predicate { $0.id == pid })
        desc.fetchLimit = 1
        return (try? modelContext.fetch(desc).first)?.name
    }

    // MARK: - Meeting sections

    @ViewBuilder
    private var artifactSections: some View {
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

            // Analyze button — show when transcript exists but no analysis yet
            if transcript != nil && analysis == nil && !isAnalyzing && !isPipelineProcessing {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Ready for analysis")
                        .font(.headline)
                    if let error = analysisError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    ActiveModelPicker(selectedModel: $selectedModel, label: "Model")
                    Button("Analyze Now") {
                        Task { await runAnalysis() }
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

            if isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Analyzing...")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
        } else if item.audioFileRelativePath != nil && !isTranscribing && !isPipelineProcessing {
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

    // MARK: - Analysis cards (for notes, journals)

    @ViewBuilder
    private var analysisCards: some View {
        if let analysis {
            sectionHeader("Analysis", icon: "sparkles").padding(.horizontal, 16).padding(.top, 16)

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
                if !analysis.decisions.isEmpty {
                    card(title: "Decisions", systemImage: "checkmark.seal") {
                        ForEach(analysis.decisions) { decision in
                            Text(decision.title).font(.body).padding(.vertical, 2)
                        }
                    }
                }
                if !analysis.risks.isEmpty {
                    card(title: "Risks", systemImage: "exclamationmark.triangle") {
                        ForEach(analysis.risks) { risk in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(risk.risk).font(.body)
                                if !risk.details.isEmpty {
                                    Text(risk.details).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if !analysis.openQuestions.isEmpty {
                    card(title: "Open Questions", systemImage: "questionmark.bubble") {
                        ForEach(analysis.openQuestions) { q in
                            Text(q.question).font(.body).padding(.vertical, 2)
                        }
                    }
                }
                if !analysis.entities.isEmpty {
                    card(title: "Entities", systemImage: "person.3") {
                        ForEach(analysis.entities.prefix(10)) { entity in
                            HStack {
                                Text(entity.name).font(.body)
                                Spacer()
                                Text(entity.type.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Text content (notes, journal)

    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEditing {
                VStack(spacing: 0) {
                    TextEditor(text: $editedBody)
                        .font(.body)
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                if let body = item.bodyText, !body.isEmpty {
                    Text(body)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 12) {
                        Text("No content yet")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Button("Write something") {
                            startEditing()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Backlinks

    private var backlinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Referenced by", icon: "link")
                .padding(.horizontal, 16)

            ForEach(backlinks, id: \.edge.id) { link in
                    NavigationLink {
                        KnowledgeDetailView(item: link.sourceItem)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: edgeIcon(for: link.edge.edgeType))
                                .font(.caption)
                                .foregroundStyle(edgeColor(for: link.edge.edgeType))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.sourceItem.title.isEmpty ? "Untitled" : link.sourceItem.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(edgeLabel(for: link.edge.edgeType))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal, 16)
                }
        }
        .padding(.top, 20)
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

    // MARK: - Image

    @State private var currentPage = 0

    @ViewBuilder
    private var imageSection: some View {
        let pageCount = item.imagePageCount ?? 1
        let pages = loadScannedPages(count: pageCount)

        if pages.isEmpty {
            Text("No scanned image")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                // Page indicator above gallery
                if pageCount > 1 {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Page \(currentPage + 1) of \(pageCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }

                // Gallery
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                            .padding(.horizontal, 16)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pageCount > 1 ? .always : .never))
                .frame(minHeight: 350)

                // OCR text
                if let text = item.bodyText, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Extracted Text", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(text)
                            .font(.body)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
    }

    private func loadScannedPages(count: Int) -> [UIImage] {
        let dir = fileStore.itemDirectoryURL(for: item.id)
        return (0..<count).compactMap { idx in
            let url = dir.appendingPathComponent("scan_\(idx).jpg")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
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

        // Resolve engine based on user preference
        let engine: TranscriptionEngine
        let settings = TranscriptionSettings.shared
        let activeConfig = ActiveProviderManager.shared.getActiveProvider(context: modelContext)

        let hasWhisperAPI: Bool = {
            guard let config = activeConfig,
                  let baseURL = config.baseURL,
                  let keyId = config.apiKeyKeychainIdentifier,
                  let apiKey = try? SecureKeyStore().loadAPIKey(for: keyId),
                  !apiKey.isEmpty else { return false }
            return config.type == .openAI || config.type == .openAICompatible
        }()

        if settings.useRemoteWhisper, hasWhisperAPI {
           let config = activeConfig!
           let baseURL = config.baseURL!
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

            item.status = .transcribed
            item.transcriptionEngineId = engine.id

            // Auto-generate embedding after transcription
            if let provider = try? ProviderRouter.resolveActive(context: modelContext) {
                let pipeline = EmbeddingPipelineService()
                await pipeline.ensureEmbedding(for: item, using: provider)
            }

            // Auto-run analysis after transcription if provider is configured
            if let provider = try? ProviderRouter.resolveActive(context: modelContext) {
                await runAnalysisWithProvider(provider)
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
        if selectedModel.isEmpty {
            selectedModel = ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
        }
        transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id)
        analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)

        let annService = AnnotationService(context: modelContext)
        annotations = (try? annService.annotations(for: item.id)) ?? []

        if let analysis {
            let extractor = EntityExtractionService(context: modelContext)
            _ = try? extractor.extractAndPersist(from: analysis, sourceItemID: item.id)
            try? extractor.buildDecisionGraph(from: analysis, sourceItemID: item.id)
        }

        loadBacklinks()
    }

    // MARK: - Editing

    private func startEditing() {
        editedTitle = item.title
        editedBody = item.bodyText ?? ""
        isEditing = true
    }

    private func saveEdits() {
        let service = KnowledgeItemService(context: modelContext)
        try? service.updateItem(
            item,
            title: editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title : editedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyText: editedBody.isEmpty ? nil : editedBody,
            tags: nil
        )
        isEditing = false
    }

    private func cancelEditing() {
        isEditing = false
    }

    // MARK: - Reprocess

    private func reprocessItem() async {
        isReprocessing = true
        defer { isReprocessing = false }

        // Clear previous analysis so pipeline re-runs Phase 2
        item.analysisProviderId = nil
        try? modelContext.save()

        // Delete stale artifacts
        let dir = fileStore.itemDirectoryURL(for: item.id)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("provider.response.raw.txt"))

        // Clear local state so UI refreshes
        analysis = nil
        isPipelineProcessing = true

        // Re-run pipeline. If item belongs to a project, Phase 3 will
        // also re-ingest and update the project context.
        await contentPipeline.process(item.id, using: modelContext)
    }

    // MARK: - Backlinks

    private func loadBacklinks() {
        let edgeService = GraphEdgeService(context: modelContext)
        let incomingEdges = (try? edgeService.edges(to: item.id)) ?? []

        var results: [(edge: GraphEdge, sourceItem: KnowledgeItem)] = []
        for edge in incomingEdges {
            let sourceID = edge.fromID
            if let sourceItem = try? modelContext.fetch(
                FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == sourceID })
            ).first {
                results.append((edge: edge, sourceItem: sourceItem))
            }
        }
        backlinks = results
    }

    private func edgeLabel(for type: EdgeType) -> String {
        switch type {
        case .relatesTo: "Related"
        case .mentions: "Mentions"
        case .supports: "Supports"
        case .assignedTo: "Assigned to"
        case .blockedBy: "Blocked by"
        case .belongsTo: "Belongs to"
        case .produced: "Produced"
        case .precedes: "Precedes"
        case .references: "References"
        case .contradicts: "Contradicts"
        }
    }

    private func edgeIcon(for type: EdgeType) -> String {
        switch type {
        case .relatesTo: "arrow.left.arrow.right"
        case .mentions: "at"
        case .supports: "checkmark.seal"
        case .assignedTo: "person"
        case .blockedBy: "hand.raised"
        case .belongsTo: "folder"
        case .produced: "hammer"
        case .precedes: "arrow.right"
        case .references: "quote.bubble"
        case .contradicts: "exclamationmark.triangle"
        }
    }

    private func edgeColor(for type: EdgeType) -> Color {
        switch type {
        case .relatesTo: .blue
        case .mentions: .purple
        case .supports: .green
        case .assignedTo: .orange
        case .blockedBy: .red
        case .belongsTo: .brown
        case .produced: .indigo
        case .precedes: .gray
        case .references: .teal
        case .contradicts: .pink
        }
    }

    // MARK: - Analysis

    private func runAnalysis() async {
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            analysisError = "No AI provider configured. Go to Settings."
            return
        }
        await runAnalysisWithProvider(provider)
    }

    private func runAnalysisWithProvider(_ provider: any AIProvider) async {
        guard transcript != nil else {
            analysisError = "No transcript available. Transcribe first."
            return
        }

        isAnalyzing = true
        analysisError = nil

        do {
            let svc = AnalysisService()
            let model = selectedModel.isEmpty
                ? ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
                : selectedModel

            guard let t = transcript else { return }
            let result = try await svc.analyze(transcript: t, using: provider, model: model)

            // Show immediately, then save
            analysis = result
            item.status = .analyzed

            try? fileStore.createMeetingDirectory(for: item.id)
            try? fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)
        } catch let error as ProviderError {
            analysisError = "[Provider] \(error.userMessage)"
        } catch {
            analysisError = "[Error] \(error.localizedDescription)"
        }

        isAnalyzing = false
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
