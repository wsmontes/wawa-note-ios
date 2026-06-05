import SwiftUI
import SwiftData

struct KnowledgeDetailView: View {
    let item: KnowledgeItem
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @EnvironmentObject private var processingQueue: ProcessingQueueService
    @EnvironmentObject private var chatState: ChatOverlayState
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
    @State private var pipelineStage: String = ""
    @State private var isReprocessing = false
    @State private var showReprocessWarning = false

    private let fileStore = FileArtifactStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)

                if isTranscribing || isPipelineProcessing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(transcriptionProgress ?? (pipelineStage.isEmpty ? "Processing..." : pipelineStage))
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(error).font(.subheadline)
                        }
                        if error.contains("Settings") {
                            Button("Open Settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }.font(.subheadline)
                        }
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

                // Debug: show raw LLM response when analysis exists but summary is empty
                if let a = analysis, a.shortSummary.trimmingCharacters(in: .whitespaces).isEmpty {
                    rawResponseSection
                        .padding(.top, 12)
                }

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
        .alert("Re-process Item", isPresented: $showReprocessWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") { Task { await reprocessItem(confirmed: true) } }
        } message: {
            Text("You have manually edited this item's content. Re-processing will re-analyze it. Your edits will be protected and AI may suggest changes for your review instead of overwriting them.")
        }
        .onAppear {
            chatState.context = .item(item.id)
            isPipelineProcessing = contentPipeline.isProcessingItem(item.id)
            // Load scanned pages ONCE to avoid blocking main thread on re-renders
            if item.type == .image, scannedPages.isEmpty {
                scannedPages = loadScannedPages(count: item.imagePageCount ?? 1)
            }
            Task { @MainActor in
                await Task.yield()
                loadData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pipelineCompleted)) { n in
            if n.object as? String == item.id.uuidString {
                isPipelineProcessing = false
                pipelineStage = ""
                Task { @MainActor in loadData() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentPipelineStageChanged)) { n in
            guard n.object as? String == item.id.uuidString else { return }
            if let stage = n.userInfo?["stage"] as? String {
                pipelineStage = stage
                isPipelineProcessing = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptReady)) { n in
            guard n.object as? String == item.id.uuidString else { return }
            Task { @MainActor in
                transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id)
                isTranscribing = false; transcriptionProgress = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .analysisReady)) { n in
            guard n.object as? String == item.id.uuidString else { return }
            Task { @MainActor in
                analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
                if analysis == nil {
                    if let dynamic = try? fileStore.readArtifact(DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id) {
                        analysis = MeetingAnalysis(meetingId: item.id, providerId: dynamic.providerId, model: dynamic.model,
                            shortSummary: dynamic.results.stringField("short_summary") ?? "Analysis available",
                            detailedSummary: dynamic.results.stringField("detailed_summary") ?? "")
                    }
                }
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
            // Use dynamic rendering when a non-meeting framework is active
            if let fw = resolvedFramework, fw.id != "builtin/meeting" {
                dynamicAnalysisSection(framework: fw)
            } else {
                // Meeting framework: render all analysis fields using the framework's renderAs
                let meetingFW = FrameworkService.meetingFramework
                sectionHeader("Summary", icon: "sparkles").padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(meetingFW.itemAnalysis.renderAs, id: \.field) { renderer in
                        meetingAnalysisCard(for: renderer, analysis: analysis)
                    }
                }
                .padding(.horizontal, 16)
            }
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
                    Button("Analyze via Agent") {
                        Task { await reprocessItem() }
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
                Text("This recording has audio but hasn't been transcribed.")
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

    // MARK: - Framework resolution

    private var resolvedFramework: ProjectFramework? {
        guard let projectID = item.projectID else { return nil }
        let projSvc = ProjectService(context: modelContext)
        guard let project = try? projSvc.fetch(id: projectID) else { return nil }
        return FrameworkService.shared.resolve(for: project)
    }

    // MARK: - Dynamic analysis section (framework-driven)

    @ViewBuilder
    private func dynamicAnalysisSection(framework: ProjectFramework) -> some View {
        sectionHeader("Analysis", icon: "sparkles").padding(.horizontal, 16).padding(.top, 16)

        VStack(alignment: .leading, spacing: 16) {
            if let dynamicAnalysis = try? fileStore.readArtifact(DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id) {
                ForEach(framework.itemAnalysis.renderAs, id: \.field) { renderer in
                    dynamicCard(for: renderer, data: dynamicAnalysis.results)
                }
            } else if let analysis {
                // Fallback: MeetingAnalysis rendered through framework's renderAs
                ForEach(framework.itemAnalysis.renderAs, id: \.field) { renderer in
                    meetingAnalysisCard(for: renderer, analysis: analysis)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func dynamicCard(for renderer: FieldRenderer, data: AnalysisResults) -> some View {
        switch renderer.type {
        case .card:
            if let text = data.stringField(renderer.field), !text.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "doc.text") {
                    Text(text).font(.body)
                }
            }
        case .list:
            if let items = data.arrayField(renderer.field), !items.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "list.bullet") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        renderItemValue(item.value)
                    }
                }
            }
        case .chips:
            if let items = data.arrayField(renderer.field), !items.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "tag") {
                    ChipFlowLayout(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Text(formatItemLabel(item.value)).font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary).clipShape(Capsule())
                        }
                    }
                }
            }
        case .markdown:
            if let text = data.stringField(renderer.field), !text.isEmpty {
                Text(text).font(.body).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .table, .timeline:
            if let text = data.stringField(renderer.field), !text.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "tablecells") {
                    Text(text).font(.body)
                }
            }
        }
    }

    @ViewBuilder
    private func renderItemValue(_ value: Any) -> some View {
        if let str = value as? String {
            Text(str).font(.body).padding(.vertical, 2)
        } else if let dict = value as? [String: AnyCodable] {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(dict.keys.sorted()), id: \.self) { key in
                    if let v = dict[key]?.value {
                        HStack(spacing: 4) {
                            Text("\(key):").font(.caption).foregroundStyle(.secondary)
                            Text(formatItemLabel(v)).font(.body).lineLimit(2)
                        }
                    }
                }
            }.padding(.vertical, 2)
        } else {
            Text(formatItemLabel(value)).font(.body).padding(.vertical, 2)
        }
    }

    private func formatItemLabel(_ value: Any) -> String {
        if let str = value as? String { return str }
        if let dict = value as? [String: AnyCodable] {
            if let name = dict["name"]?.value as? String { return name }
            if let title = dict["title"]?.value as? String { return title }
            if let task = dict["task"]?.value as? String { return task }
            if let first = dict.values.first { return String(describing: first.value) }
            return ""
        }
        if let num = value as? Double { return String(format: "%.2f", num) }
        if let num = value as? Int { return String(num) }
        return String(describing: value)
    }

    @ViewBuilder
    private func meetingAnalysisCard(for renderer: FieldRenderer, analysis: MeetingAnalysis) -> some View {
        switch renderer.field {
        case "short_summary":
            if !analysis.shortSummary.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "doc.text") {
                    Text(analysis.shortSummary).font(.body)
                }
            }
        case "decisions":
            if !analysis.decisions.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "checkmark.seal") {
                    ForEach(analysis.decisions) { d in Text(d.title).font(.body).padding(.vertical, 2) }
                }
            }
        case "action_items":
            if !analysis.actionItems.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "checklist") {
                    ForEach(analysis.actionItems) { a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle").font(.caption).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.task).font(.body)
                                if let o = a.owner { Text(o).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
        case "risks":
            if !analysis.risks.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "exclamationmark.triangle") {
                    ForEach(analysis.risks) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.risk).font(.body)
                            if !r.details.isEmpty { Text(r.details).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 2)
                    }
                }
            }
        case "open_questions":
            if !analysis.openQuestions.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "questionmark.bubble") {
                    ForEach(analysis.openQuestions) { q in Text(q.question).font(.body).padding(.vertical, 2) }
                }
            }
        case "entities":
            if !analysis.entities.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "person.3") {
                    ForEach(analysis.entities.prefix(10)) { e in
                        HStack { Text(e.name).font(.body); Spacer(); Text(e.type.rawValue).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        case "important_dates":
            if !analysis.importantDates.isEmpty {
                card(title: renderer.title, systemImage: renderer.icon ?? "calendar") {
                    ForEach(analysis.importantDates) { d in
                        HStack { Text(d.date).font(.caption).foregroundStyle(.secondary); Text(d.meaning).font(.body) }
                    }
                }
            }
        default:
            EmptyView()
        }
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

    @State private var scannedPages: [UIImage] = []
    @State private var currentPage = 0

    @ViewBuilder
    private var imageSection: some View {
        if scannedPages.isEmpty {
            Text("No scanned image")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                // Page indicator above gallery
                if scannedPages.count > 1 {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Page \(currentPage + 1) of \(scannedPages.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }

                // Gallery
                TabView(selection: $currentPage) {
                    ForEach(Array(scannedPages.enumerated()), id: \.offset) { idx, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                            .padding(.horizontal, 16)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: scannedPages.count > 1 ? .always : .never))
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

    // MARK: - Raw Response (debug)

    @ViewBuilder
    private var rawResponseSection: some View {
        let rawURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("provider.response.raw.txt")
        let iterativeURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("analysis.iterative.txt")
        let rawText = (try? String(contentsOf: rawURL, encoding: .utf8)) ?? ""
        let iterText = (try? String(contentsOf: iterativeURL, encoding: .utf8)) ?? ""

        if !rawText.isEmpty || !iterText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Raw LLM Response").font(.footnote).fontWeight(.semibold).foregroundStyle(.orange)
                if !rawText.isEmpty {
                    Text(rawText.prefix(2000)).font(.caption).foregroundStyle(.secondary).padding(8)
                        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !iterText.isEmpty {
                    Text("Iterative: \(iterText.prefix(2000))").font(.caption).foregroundStyle(.secondary).padding(8)
                        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12).background(Color.orange.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
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

            // Auto-run pipeline (agent-based) after transcription
            if (try? ProviderRouter.resolveActive(context: modelContext)) != nil {
                isPipelineProcessing = true
                processingQueue.enqueue(itemID: item.id, trigger: .directUserAction)
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
        // Mark fields as user-edited
        var prov = item.provenance
        prov.mark(field: "title", origin: .user)
        if !editedBody.isEmpty { prov.mark(field: "bodyText", origin: .user) }
        item.fieldProvenanceJSON = prov.encode()
        try? modelContext.save()
        isEditing = false
    }

    private func cancelEditing() {
        isEditing = false
    }

    // MARK: - Reprocess

    private func reprocessItem(confirmed: Bool = false) async {
        // Check for user-owned fields before re-processing
        if !confirmed {
            let userOwned = ["title", "bodyText"].filter { item.provenance.isUserOwned(field: $0) }
            if !userOwned.isEmpty {
                showReprocessWarning = true
                return
            }
        }

        isReprocessing = true
        defer { isReprocessing = false }

        // Clear previous analysis so pipeline re-runs Phase 2
        item.analysisProviderId = nil
        try? modelContext.save()

        // Delete stale artifacts
        let dir = fileStore.itemDirectoryURL(for: item.id)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.dynamic.json"))
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
        case .mentions: .purple
        case .belongsTo: .blue
        case .produced: .green
        case .assignedTo: .orange
        case .supports: .teal
        case .precedes: .indigo
        case .blockedBy: .red
        case .relatesTo: .gray
        case .references: .cyan
        case .contradicts: .pink
        }
    }

    // MARK: - Analysis (all via agent pipeline)

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

// MARK: - Chip Flow Layout

struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let height = rows.last?.maxY ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [LayoutRow] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [LayoutRow] = []
        var currentRow: [LayoutItem] = []
        var x: CGFloat = 0
        var y: CGFloat = 0

        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !currentRow.isEmpty && x + size.width > maxWidth {
                rows.append(LayoutRow(items: currentRow, y: y))
                currentRow = []
                x = 0
                y += size.height + spacing
            }
            currentRow.append(LayoutItem(index: idx, x: x, width: size.width, height: size.height))
            x += size.width + spacing
        }
        if !currentRow.isEmpty {
            rows.append(LayoutRow(items: currentRow, y: y))
        }
        return rows
    }

    struct LayoutItem { let index: Int; let x: CGFloat; let width: CGFloat; let height: CGFloat }
    struct LayoutRow { let items: [LayoutItem]; let y: CGFloat; var maxY: CGFloat { (items.map(\.height).max() ?? 0) + y } }
}
