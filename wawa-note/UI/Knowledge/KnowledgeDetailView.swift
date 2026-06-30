import SwiftData
import SwiftUI

private enum ReprocessMode: CustomStringConvertible {
  case transcribeOnly
  case analyzeOnly
  case full

  var description: String {
    switch self {
    case .transcribeOnly: "transcribeOnly"
    case .analyzeOnly: "analyzeOnly"
    case .full: "full"
    }
  }
}

/// User-selected transcription engine override for reprocess actions.
enum TranscriptionOverride: String {
  case appleOnDevice = "Apple On-Device"
  case appleCloud = "Apple + Cloud"
  case whisper = "Whisper"

  var icon: String {
    switch self {
    case .appleOnDevice: "iphone.and.arrow.forward"
    case .appleCloud: "icloud.and.arrow.up"
    case .whisper: "network"
    }
  }
}

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
  @State private var showConnectSheet = false
  @State private var connectSearchText = ""
  @State private var connectableItems: [KnowledgeItem] = []
  @State private var isAnalyzing = false
  @State private var analysisError: String?
  @State private var selectedModel: String = ""
  @State private var selectedLocale = TranscriptionLocaleProvider.bestGuessLocale
  @State private var showLocalePicker = false
  @State private var isEditing = false
  @State private var editedTitle = ""
  @State private var editedBody = ""
  @State private var backlinks: [(edge: GraphEdge, sourceItem: KnowledgeItem)] = []
  @State private var pipelineStage: String = ""
  @State private var analysisAvailable = false

  /// True while the item is in any post-recording processing state.
  /// Derived from `item.status` (authoritative) and the queue entries
  /// (@Published) so the view updates reactively without manual @State flips.
  private var isPipelineProcessing: Bool {
    processingQueue.entries.contains(where: {
      $0.itemID == item.id && ($0.status == .queued || $0.status == .processing)
    }) || item.status == .preparingAudio || item.status == .queuedForTranscription
      || item.status == .transcribing || item.status == .analyzing
  }
  @State private var audioPlaybackURL: URL?
  @State private var isPreparingAudio = false
  @State private var audioAssetState: AudioAssetState = .unavailable

  private let assetResolver = AudioAssetResolver()
  @State private var isReprocessing = false
  @State private var showReprocessWarning = false
  @State private var showWhisperKeyAlert = false
  @State private var refreshID = UUID()  // bumped on pipeline complete to force re-render
  @State private var pendingReprocessMode: ReprocessMode = .analyzeOnly
  @State private var pendingReprocessEngine: TranscriptionOverride?
  @State private var agentEvents: [PipelineAgentEvent] = []
  @State private var isAgentThinking = false
  @State private var rawAnalysisJSON: [String: Any] = [:]

  private let fileStore = FileArtifactStore()

  private var statusLabel: String {
    if let p = transcriptionProgress { return p }
    if !pipelineStage.isEmpty { return pipelineStage }
    return item.status.label
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
          .padding(.horizontal, 16)

        if isTranscribing || isPipelineProcessing {
          VStack(spacing: 0) {
            // Current status bar
            HStack(spacing: 10) {
              ProgressView()
              VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                  .font(.subheadline).foregroundStyle(.primary)
                if isAgentThinking {
                  Text("Agent is thinking…").font(.caption2).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if !agentEvents.isEmpty {
                Text("\(agentEvents.count) steps").font(.caption2).foregroundStyle(.secondary)
              }
            }
            .padding(12)

            // Agent trace — collapsible log of tool calls & results
            if !agentEvents.isEmpty {
              Divider().padding(.horizontal, 12)
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                  ForEach(agentEvents) { evt in
                    agentEventBadge(evt)
                  }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
              }
            }
          }
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

        if let error = analysisError {
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

        // Audio player — shown when item has playable audio (single file or segments)
        if hasPlayableAudio {
          if isPreparingAudio {
            HStack {
              ProgressView()
              Text("Preparing audio…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 12)
          } else if let url = audioPlaybackURL {
            AudioPlayerView(audioURL: url, title: item.title)
              .padding(.horizontal, 16).padding(.top, 12)
          } else if case .segmentsAvailable(let count) = audioAssetState {
            Button {
              Task { await prepareAudioForPlayback() }
            } label: {
              Label("Prepare Audio (\(count) segments)", systemImage: "waveform.circle")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16).padding(.top, 12)
          }
        } else if case .failed(let reason) = audioAssetState {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(reason).font(.caption).foregroundStyle(.secondary)
          }
          .padding(.horizontal, 16).padding(.top, 8)
        }

        // Analysis always at the top — like every other item type
        if transcript != nil || analysis != nil { artifactSections }

        // Image gallery + OCR for scanned documents
        if item.type == .image { imageSection }

        // Body text for notes, journals, and any non-image item with bodyText
        // Images: OCR text already shown inside imageSection
        if (item.bodyText != nil && item.type != .image) || item.type == .note
          || item.type == .journalEntry
        {
          textContentSection
        }
        if item.type == .webBookmark { bookmarkSection }

        // Context metadata (read-only display)
        if hasContextFields { contextSection }

        // Debug: show raw LLM response (Developer Mode only).
        // Gated behind #if DEBUG so it's NEVER compiled into App Store builds,
        // even if the UserDefaults key is accidentally set.
        #if DEBUG
          if UserDefaults.standard.bool(forKey: "developer_mode_enabled"),
            let a = analysis, a.shortSummary.trimmingCharacters(in: .whitespaces).isEmpty
          {
            rawResponseSection
              .padding(.top, 12)
          }
        #endif

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
    .id(refreshID)  // force re-render on pipeline complete
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

          Button {
            showConnectSheet = true
          } label: {
            Label("Connect to Item", systemImage: "arrow.triangle.pull")
          }

          // Reprocess menu — available for any processable item.
          let canReprocess =
            item.type == .audio || item.type == .image
            || item.bodyText != nil || item.analysisProviderId != nil
            || item.transcriptionEngineId != nil
          if canReprocess {
            Menu {
              if item.type == .audio {
                let already = item.transcriptionEngineId != nil
                let prefix = already ? "Re-transcribe" : "Transcribe"
                Section("Transcription Engine") {
                  Button {
                    Task { await reprocessItem(mode: .transcribeOnly, engine: .appleOnDevice) }
                  } label: {
                    Label(
                      "\(prefix) (On-Device)",
                      systemImage: TranscriptionOverride.appleOnDevice.icon)
                  }
                  Button {
                    Task { await reprocessItem(mode: .transcribeOnly, engine: .appleCloud) }
                  } label: {
                    Label(
                      "\(prefix) (Cloud Fallback)",
                      systemImage: TranscriptionOverride.appleCloud.icon)
                  }
                  Button {
                    Task { await reprocessItem(mode: .transcribeOnly, engine: .whisper) }
                  } label: {
                    Label(
                      "\(prefix) (Whisper API)",
                      systemImage: TranscriptionOverride.whisper.icon)
                  }
                }
              }
              if item.type == .image {
                Button {
                  Task { await reprocessItem(mode: .transcribeOnly) }
                } label: {
                  Label(
                    item.bodyText?.isEmpty != false ? "Extract Text" : "Re-extract Text",
                    systemImage: "text.viewfinder")
                }
              }
              // Re-analyze: only when there's content to analyze
              let canAnalyze =
                (item.type == .audio && item.transcriptionEngineId != nil)
                || (item.type == .image && item.bodyText?.isEmpty == false)
                || item.bodyText?.isEmpty == false
                || item.analysisProviderId != nil
              if canAnalyze {
                Button {
                  Task { await reprocessItem(mode: .analyzeOnly) }
                } label: {
                  Label("Re-analyze", systemImage: "brain.head.profile")
                }
              }
              let canFullReprocess =
                (item.type == .audio && item.transcriptionEngineId != nil
                  && item.analysisProviderId != nil)
                || (item.type == .image && item.bodyText?.isEmpty == false
                  && item.analysisProviderId != nil)
              if canFullReprocess {
                Divider()
                Button {
                  Task { await reprocessItem(mode: .full) }
                } label: {
                  Label("Full Reprocess", systemImage: "arrow.triangle.2.circlepath")
                }
              }
            } label: {
              Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isReprocessing || isPipelineProcessing)
          }

          if hasExportableContent {
            Menu {
              // Textual exports (when transcript/analysis available)
              if transcript != nil || analysis != nil {
                ShareLink(
                  "Markdown",
                  item: MarkdownExporter().export(
                    item: item, transcript: transcript, analysis: analysis))
                if let jsonData = try? JSONExporter().export(
                  item: item, transcript: transcript, analysis: analysis),
                  let jsonString = String(data: jsonData, encoding: .utf8)
                {
                  ShareLink("JSON Export", item: jsonString)
                }
              }
              if let anarlogMD = try? AnarlogExporter().exportMarkdown(item: item) {
                ShareLink("Anarlog .md", item: anarlogMD)
              }
              if let meetilyData = try? MeetilyExporter().exportJSON(item: item),
                let meetilyString = String(data: meetilyData, encoding: .utf8)
              {
                ShareLink("Meetily .json", item: meetilyString)
              }
              // Audio export — available even without transcript
              if hasPlayableAudio, let url = audioPlaybackURL {
                ShareLink("Audio", item: url)
              } else if case .segmentsAvailable = audioAssetState {
                Button("Export Audio") {
                  Task { await prepareAudioForExport() }
                }
                .disabled(isPreparingAudio)
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
    .sheet(isPresented: $showConnectSheet) {
      connectToItemSheet
    }
    .alert("Re-process Item", isPresented: $showReprocessWarning) {
      Button("Cancel", role: .cancel) {}
      Button("Continue") {
        Task {
          await reprocessItem(
            mode: pendingReprocessMode, confirmed: true, engine: pendingReprocessEngine)
        }
      }
    } message: {
      Text(
        "You have manually edited this item's content. Re-processing will re-analyze it. Your edits will be protected and AI may suggest changes for your review instead of overwriting them."
      )
    }
    .alert("Whisper Requires Configuration", isPresented: $showWhisperKeyAlert) {
      Button("Open Settings") {
        // Navigate to settings tab
      }
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        "Whisper transcription needs an OpenAI-compatible provider configured with a Base URL and API key. Go to Settings → AI Services to add one."
      )
    }
    .onAppear {
      chatState.context = .item(item.id)
      analysisAvailable = AIConfigService.shared.isProviderConfigured(context: modelContext)
      // Load scanned pages ONCE to avoid blocking main thread on re-renders
      if item.type == .image, scannedPages.isEmpty {
        scannedPages = loadScannedPages(count: item.imagePageCount ?? 1)
      }
      Task { @MainActor in
        await Task.yield()
        await resolveAudioAsset()
        loadRawAnalysisJSON()
        loadData()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .activeProviderChanged)) { _ in
      analysisAvailable = AIConfigService.shared.isProviderConfigured(context: modelContext)
      loadData()
    }
    .onReceive(NotificationCenter.default.publisher(for: .pipelineCompleted)) { n in
      if n.object as? String == item.id.uuidString {
        pipelineStage = ""
        // Force SwiftUI to re-render with fresh data — the managed object
        // may have been updated in another context.
        refreshID = UUID()
        Task { @MainActor in
          loadRawAnalysisJSON()
          loadData()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentPipelineStageChanged)) { n in
      guard n.object as? String == item.id.uuidString else { return }
      if let stage = n.userInfo?["stage"] as? String {
        pipelineStage = stage.capitalized
      }
      if let tool = n.userInfo?["tool"] as? String {
        pipelineStage = "Agent: \(tool)"
      }
      if let summary = n.userInfo?["summary"] as? String {
        pipelineStage = summary
      }
      if let phase = n.userInfo?["phase"] as? String {
        pipelineStage = phase == "completed" ? "Analysis complete" : pipelineStage
      }
      if let events = n.userInfo?["events"] as? [PipelineAgentEvent] {
        agentEvents = events
      }
      if let thinking = n.userInfo?["thinking"] as? Bool {
        isAgentThinking = thinking
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .transcriptReady)) { n in
      guard n.object as? String == item.id.uuidString else { return }
      Task { @MainActor in
        transcript = try? fileStore.readArtifact(
          Transcript.self, fileName: "transcript.json", meetingId: item.id)
        isTranscribing = false
        transcriptionProgress = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .analysisReady)) { n in
      guard n.object as? String == item.id.uuidString else { return }
      Task { @MainActor in
        analysis = try? fileStore.readArtifact(
          MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
        loadRawAnalysisJSON()
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

          // Original title — shown discreetly when AI has renamed the item
          if let orig = item.originalTitle, orig != item.title {
            Text(orig)
              .font(.caption2).foregroundStyle(.tertiary)
              .lineLimit(1)
          }

          // Mood badge for journal entries
          if item.type == .journalEntry,
            let moodTag = item.tags.first(where: { $0.hasPrefix("mood/") })
          {
            let mood = String(moodTag.dropFirst(5))
            HStack(spacing: 4) {
              Text(moodEmoji(mood))
              Text(mood.capitalized)
            }
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(moodColor(mood).opacity(0.12), in: Capsule())
            .foregroundStyle(moodColor(mood))
          }
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

  @StateObject private var audioPlayback = AudioPlaybackService()

  private var connectToItemSheet: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack {
          TextField("Search items...", text: $connectSearchText)
            .textFieldStyle(.roundedBorder)
            .padding()
            .onChange(of: connectSearchText) { _, _ in
              let all = (try? KnowledgeItemService(context: modelContext).allItems()) ?? []
              connectableItems =
                all
                .filter {
                  $0.id != item.id
                    && (connectSearchText.isEmpty
                      || $0.title.localizedCaseInsensitiveContains(connectSearchText))
                }
                .prefix(20).map { $0 }
            }
        }
        List {
          ForEach(connectableItems.prefix(20)) { other in
            Button {
              let gsvc = GraphEdgeService(context: modelContext)
              try? gsvc.create(
                fromID: item.id, toID: other.id,
                edgeType: .relatesTo, weight: 1.0,
                provenanceItemID: item.id, provenanceSegmentIDs: []
              )
              try? gsvc.create(
                fromID: other.id, toID: item.id,
                edgeType: .relatesTo, weight: 1.0,
                provenanceItemID: item.id, provenanceSegmentIDs: []
              )
              showConnectSheet = false
              connectSearchText = ""
            } label: {
              HStack(spacing: 8) {
                Image(
                  systemName: other.type == .audio
                    ? "mic" : other.type == .note ? "doc.text" : "doc"
                )
                .font(.caption).foregroundStyle(
                  other.type == .audio ? .blue : other.type == .note ? .orange : .secondary)
                VStack(alignment: .leading) {
                  Text(other.title).font(.subheadline).lineLimit(1)
                  Text(other.type.label).font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        .onAppear {
          let all = (try? KnowledgeItemService(context: modelContext).allItems()) ?? []
          connectableItems = all.filter { $0.id != item.id }
        }
      }
      .navigationTitle("Connect to Item")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Cancel") {
            showConnectSheet = false
            connectSearchText = ""
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var hasContextFields: Bool {
    item.contextPlaceName != nil || item.contextAudioRoute != nil || item.contextLatitude != nil
      || item.contextFocusActive != nil || item.contextMotionActivity != nil
      || item.contextBatteryLevel != nil || item.contextCalendarEventTitle != nil
  }

  private var contextSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader("Context", icon: "location.fill.viewfinder")
      HStack(spacing: 12) {
        if let place = item.contextPlaceName { contextBadge(icon: "mappin", text: place) }
        if let route = item.contextAudioRoute { contextBadge(icon: "airpodspro", text: route) }
        if let cal = item.contextCalendarEventTitle { contextBadge(icon: "calendar", text: cal) }
        if let motion = item.contextMotionActivity {
          contextBadge(icon: "figure.walk", text: motion)
        }
        if let focus = item.contextFocusActive {
          contextBadge(icon: focus ? "moon.fill" : "sun.max", text: focus ? "Focus" : "Active")
        }
        if let battery = item.contextBatteryLevel {
          contextBadge(icon: "battery.75", text: "\(Int(battery*100))%")
        }
      }
    }
    .padding(.horizontal, 16)
  }

  private func contextBadge(icon: String, text: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon).font(.system(size: 9))
      Text(text).font(.caption2).lineLimit(1)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(Color(.tertiarySystemBackground), in: Capsule())
  }

  private var audioPlayerSection: some View {
    AudioPlayerView(
      audioURL: FileArtifactStore().audioFileURL(for: item.id),
      title: item.title
    )
  }

  // MARK: - Audio asset resolution

  /// Whether any playable audio exists (single file or segments ready to render).
  private var hasPlayableAudio: Bool {
    switch audioAssetState {
    case .singleFileReady, .segmentsAvailable:
      return true
    case .unavailable, .rendering, .failed:
      return false
    }
  }

  /// Whether the export menu has anything to offer.
  private var hasExportableContent: Bool {
    transcript != nil || analysis != nil
      || item.type == .image || item.type == .note
      || item.type == .journalEntry || item.type == .webBookmark
      || hasPlayableAudio
  }

  private func resolveAudioAsset() async {
    audioAssetState = assetResolver.state(for: item.id)
    switch audioAssetState {
    case .singleFileReady(let url):
      audioPlaybackURL = url
    case .segmentsAvailable:
      // Don't auto-render — wait for user to tap Play or Export.
      audioPlaybackURL = nil
    case .unavailable, .failed, .rendering:
      audioPlaybackURL = nil
    }
  }

  private func prepareAudioForPlayback() async {
    isPreparingAudio = true
    audioAssetState = .rendering
    audioPlaybackURL = await assetResolver.resolvePlayableURL(for: item.id)
    if audioPlaybackURL != nil {
      audioAssetState = .singleFileReady(audioPlaybackURL!)
    } else {
      audioAssetState = .failed("Could not prepare audio for playback.")
    }
    isPreparingAudio = false
  }

  private func prepareAudioForExport() async {
    isPreparingAudio = true
    audioAssetState = .rendering
    if let url = await assetResolver.resolvePlayableURL(for: item.id) {
      audioPlaybackURL = url
      audioAssetState = .singleFileReady(url)
    } else {
      audioAssetState = .failed("Could not prepare audio for export.")
    }
    isPreparingAudio = false
  }

  private var badges: [(title: String, icon: String?, tone: BadgeTone)] {
    var b: [(String, String?, BadgeTone)] = []
    if hasPlayableAudio { b.append(("Audio", "mic", .success)) }
    if let engineId = item.transcriptionEngineId {
      let label = transcriptionServiceLabel(engineId)
      b.append((label, "text.alignleft", .success))
    } else if hasPlayableAudio {
      b.append(("Not transcribed", "text.alignleft", .warning))
    }
    if item.analysisProviderId != nil {
      b.append(("Analyzed", "sparkles", .success))
    } else if item.bodyText != nil && !item.bodyText!.isEmpty {
      b.append(("Analysis pending", "sparkles", .neutral))
    }
    if item.projectID != nil {
      b.append((projectName ?? "In project", "folder", .success))
    } else {
      b.append(("No project", "folder", .neutral))
    }
    if let cal = item.contextCalendarEventTitle { b.append((cal, "calendar", .neutral)) }
    if let route = item.contextAudioRoute { b.append((route, "airpodspro", .neutral)) }
    return b
  }

  private func transcriptionServiceLabel(_ engineId: String) -> String {
    if engineId.contains("whisper") { return "Transcribed · Whisper" }
    if engineId.contains("apple-cloud") { return "Transcribed · Apple Cloud" }
    if engineId.contains("apple-speech") { return "Transcribed · On-Device" }
    return "Transcribed"
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
    // Dynamic JSON rendering — shows whatever the agent wrote to disk
    if !rawAnalysisJSON.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        sectionHeader("Analysis", icon: "sparkles").padding(.horizontal, 16)
        VStack(spacing: 12) {
          // Sort: short_summary first, then alphabetically
          let keys = rawAnalysisJSON.keys.sorted { a, b in
            if a == "short_summary" || a == "shortSummary" { return true }
            if b == "short_summary" || b == "shortSummary" { return false }
            return a < b
          }
          ForEach(keys, id: \.self) { key in
            if let value = rawAnalysisJSON[key] {
              dynamicFieldCard(key: key, value: value)
            }
          }
        }
        .padding(.horizontal, 16)
      }
    } else if let analysis {
      // Legacy MeetingAnalysis fallback
      let meetingFW = FrameworkService.meetingFramework
      sectionHeader("Summary", icon: "sparkles").padding(.horizontal, 16)
      VStack(alignment: .leading, spacing: 16) {
        ForEach(meetingFW.itemAnalysis.renderAs, id: \.field) { renderer in
          meetingAnalysisCard(for: renderer, analysis: analysis)
        }
      }
      .padding(.horizontal, 16)
    }

    // MARK: Extraction Review Card
    if item.status == .pendingReview, let extracted = extractionPreview() {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Review Extraction", systemImage: "eye")
            .font(.headline).foregroundStyle(.orange)
          Spacer()
          Button {
            isEditing = true
            editedBody = extracted
          } label: {
            Label("Edit", systemImage: "pencil").font(.caption)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        Text(extracted)
          .font(.subheadline)
          .lineLimit(8)
          .padding(10)
          .background(Color(.systemGray6))
          .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack(spacing: 8) {
          Button {
            item.status = .analyzing
            try? modelContext.save()
            // Re-queue for analysis now that user approved
            processingQueue.enqueue(
              itemID: item.id, projectID: item.projectID, trigger: .directUserAction)
          } label: {
            Label("Approve & Analyze", systemImage: "checkmark.circle.fill")
              .font(.subheadline).fontWeight(.medium)
          }
          .buttonStyle(.borderedProminent).tint(.green)

          Button(role: .destructive) {
            // Re-extract: delete transcript, retry
            let dir = fileStore.itemDirectoryURL(for: item.id)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
            item.status = .recorded
            try? modelContext.save()
            processingQueue.enqueue(
              itemID: item.id, projectID: item.projectID, trigger: .newCapture)
          } label: {
            Label("Re-extract", systemImage: "arrow.counterclockwise")
              .font(.subheadline)
          }
          .buttonStyle(.bordered).tint(.orange)
        }
      }
      .padding(16)
      .background(Color(.secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 16)
      .padding(.top, 8)
    }

    // MARK: Speaker Confirmations
    if let pending = pendingConfirmations(), !pending.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("Speaker Confirmations", systemImage: "person.fill.questionmark")
          .font(.headline).foregroundStyle(.orange)
        Text("The agent needs your help to identify these speakers.")
          .font(.caption).foregroundStyle(.secondary)

        ForEach(Array(pending.enumerated()), id: \.offset) { idx, pc in
          VStack(alignment: .leading, spacing: 6) {
            Text(pc["question"] as? String ?? "Who is this?")
              .font(.subheadline).fontWeight(.medium)
            if let guess = pc["best_guess"] as? String {
              Text("Best guess: \(guess)")
                .font(.caption).foregroundStyle(.secondary)
            }
            if let candidates = pc["candidates"] as? [[String: Any]] {
              ForEach(Array(candidates.enumerated()), id: \.offset) { ci, c in
                HStack(spacing: 4) {
                  Text(c["name"] as? String ?? "")
                    .font(.caption).fontWeight(.medium)
                  if let ev = c["evidence"] as? String {
                    Text("— \(ev)")
                      .font(.caption2).foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
            }

            HStack(spacing: 16) {
              Button {
                confirmSpeaker(idx, answer: "yes")
              } label: {
                Label("Yes", systemImage: "checkmark.circle.fill")
                  .font(.subheadline).fontWeight(.medium)
              }
              .buttonStyle(.borderedProminent).tint(.green)

              Button {
                confirmSpeaker(idx, answer: "no")
              } label: {
                Label("No", systemImage: "xmark.circle.fill")
                  .font(.subheadline)
              }
              .buttonStyle(.bordered).tint(.red)

              Button {
                confirmSpeaker(idx, answer: "rephrase")
              } label: {
                Label("Rephrase", systemImage: "questionmark.circle.fill")
                  .font(.subheadline)
              }
              .buttonStyle(.bordered).tint(.orange)
            }
          }
          .padding(12)
          .background(Color(.systemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
      .padding(16)
      .background(Color(.secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 16)
      .padding(.top, 8)
    }

    if let transcript {
      if isAnalyzing {
        HStack(spacing: 10) {
          ProgressView()
          Text("Analyzing...")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
      }

      // Group word-level segments into readable subtitle-like phrases
      let groups = transcript.groupedSegments(pauseThreshold: 0.5, maxChars: 120)
      let transcriptText = groups.map { g in
        "[\(formatTime(g.startTime))] \(g.text)"
      }.joined(separator: "\n\n")

      VStack(alignment: .leading, spacing: 0) {
        HStack {
          sectionHeader("Transcript", icon: "text.alignleft")
          Spacer()
          Button {
            UIPasteboard.general.string = transcriptText
          } label: {
            Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
          }
          ShareLink(item: transcriptText) {
            Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 16)

        VStack(spacing: 0) {
          ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("[\(formatTime(group.startTime))]")
                  .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let conf = group.confidence {
                  HStack(spacing: 4) {
                    ConfidenceBar(confidence: conf)
                      .frame(width: 40, height: 4)
                    Text("\(Int(conf * 100))%")
                      .font(.caption2).foregroundStyle(confidenceColor(conf))
                  }
                }
              }
              Text(group.text)
                .font(.body).textSelection(.enabled)
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
    } else if hasPlayableAudio && !isTranscribing && !isPipelineProcessing {
      VStack(spacing: 12) {
        Image(systemName: "text.alignleft")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("No transcript yet")
          .font(.headline)
        Text("This recording has audio but hasn't been transcribed.")
          .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

        // Locale picker — only for on-device transcription.
        // Whisper auto-detects language, so the picker is irrelevant.
        if !TranscriptionSettings.shared.useRemoteWhisper {
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
      if let dynamicAnalysis = try? fileStore.readArtifact(
        DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id)
      {
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

  // MARK: - Dynamic field card (renders any JSON value)

  @ViewBuilder
  private func dynamicFieldCard(key: String, value: Any) -> some View {
    let title = key.replacingOccurrences(of: "_", with: " ").capitalized
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: iconForKey(key))
          .font(.caption).foregroundStyle(.secondary)
        Text(title)
          .font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
      }

      if let s = value as? String {
        Text(s).font(.body).textSelection(.enabled)
      } else if let arr = value as? [Any] {
        ForEach(Array(arr.enumerated()), id: \.offset) { _, item in
          dynamicListItem(item)
        }
      } else if let dict = value as? [String: Any] {
        dynamicDictView(dict)
      } else if let n = value as? NSNumber {
        Text(n.stringValue).font(.body).textSelection(.enabled)
      } else if let b = value as? Bool {
        Text(b ? "Yes" : "No").font(.body)
      } else if value is NSNull {
        Text("—").font(.caption).foregroundStyle(.tertiary)
      } else {
        Text(String(describing: value)).font(.body).textSelection(.enabled)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func dynamicListItem(_ item: Any) -> AnyView {
    if let str = item as? String {
      return AnyView(
        HStack(spacing: 6) {
          Image(systemName: "circle.fill").font(.system(size: 5))
          Text(str).font(.body).textSelection(.enabled)
        })
    }
    if let dict = item as? [String: Any] {
      return AnyView(dynamicDictView(dict))
    }
    if let n = item as? NSNumber {
      return AnyView(Text(n.stringValue).font(.body).textSelection(.enabled))
    }
    return AnyView(Text(String(describing: item)).font(.body).textSelection(.enabled))
  }

  private func dynamicDictView(_ dict: [String: Any]) -> AnyView {
    AnyView(
      VStack(alignment: .leading, spacing: 4) {
        ForEach(dict.keys.sorted(), id: \.self) { k in
          if let v = dict[k] {
            if let str = v as? String, !str.isEmpty {
              HStack(spacing: 6) {
                Text(k.replacingOccurrences(of: "_", with: " ").capitalized + ":")
                  .font(.caption).foregroundStyle(.secondary)
                Text(str).font(.body).textSelection(.enabled)
              }
            } else if let nestedArr = v as? [Any] {
              VStack(alignment: .leading, spacing: 2) {
                Text(k.replacingOccurrences(of: "_", with: " ").capitalized)
                  .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(nestedArr.enumerated()), id: \.offset) { _, nestedItem in
                  dynamicListItem(nestedItem)
                    .padding(.leading, 8)
                }
              }
            } else if let nestedDict = v as? [String: Any] {
              VStack(alignment: .leading, spacing: 2) {
                Text(k.replacingOccurrences(of: "_", with: " ").capitalized)
                  .font(.caption).foregroundStyle(.secondary)
                dynamicDictView(nestedDict)
                  .padding(.leading, 8)
              }
            } else {
              Text("\(k): \(String(describing: v))").font(.body).textSelection(.enabled)
            }
          }
        }
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .background(Color(.tertiarySystemFill))
      .clipShape(RoundedRectangle(cornerRadius: 8)))
  }

  private func iconForKey(_ key: String) -> String {
    let k = key.lowercased()
    if k.contains("summary") { return "text.alignleft" }
    if k.contains("decision") { return "checkmark.shield" }
    if k.contains("action") { return "checklist" }
    if k.contains("risk") { return "exclamationmark.triangle" }
    if k.contains("question") { return "questionmark.circle" }
    if k.contains("date") || k.contains("timeline") { return "calendar" }
    if k.contains("people") || k.contains("person") { return "person" }
    if k.contains("system") { return "desktopcomputer" }
    if k.contains("organi") { return "building.2" }
    if k.contains("location") || k.contains("place") { return "mappin" }
    if k.contains("email") || k.contains("draft") { return "envelope" }
    if k.contains("entity") || k.contains("mention") { return "tag" }
    return "doc.text"
  }

  @ViewBuilder
  private func meetingAnalysisCard(for renderer: FieldRenderer, analysis: MeetingAnalysis)
    -> some View
  {
    switch renderer.field {
    case "short_summary":
      if !analysis.shortSummary.isEmpty {
        card(
          title: renderer.title, systemImage: renderer.icon ?? "doc.text",
          copyText: analysis.shortSummary
        ) {
          Text(analysis.shortSummary).font(.body).textSelection(.enabled)
        }
      }
    case "decisions":
      if !analysis.decisions.isEmpty {
        card(title: renderer.title, systemImage: renderer.icon ?? "checkmark.seal") {
          ForEach(analysis.decisions) { d in
            Text(d.title).font(.body).textSelection(.enabled).padding(.vertical, 2)
          }
        }
      }
    case "action_items":
      if !analysis.actionItems.isEmpty {
        card(title: renderer.title, systemImage: renderer.icon ?? "checklist") {
          ForEach(analysis.actionItems) { a in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "circle").font(.caption).padding(.top, 3)
              VStack(alignment: .leading, spacing: 2) {
                Text(a.task).font(.body).textSelection(.enabled)
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
              Text(r.risk).font(.body).textSelection(.enabled)
              if !r.details.isEmpty { Text(r.details).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 2)
          }
        }
      }
    case "open_questions":
      if !analysis.openQuestions.isEmpty {
        card(title: renderer.title, systemImage: renderer.icon ?? "questionmark.bubble") {
          ForEach(analysis.openQuestions) { q in
            Text(q.question).font(.body).textSelection(.enabled).padding(.vertical, 2)
          }
        }
      }
    case "entities":
      if !analysis.entities.isEmpty {
        card(title: renderer.title, systemImage: renderer.icon ?? "person.3") {
          ForEach(analysis.entities.prefix(10)) { e in
            HStack {
              Text(e.name).font(.body)
              Spacer()
              Text(e.type.rawValue).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    case "important_dates":
      if !analysis.importantDates.isEmpty {
        card(title: renderer.title, systemImage: renderer.icon ?? "calendar") {
          ForEach(analysis.importantDates) { d in
            HStack {
              Text(d.date).font(.caption).foregroundStyle(.secondary)
              Text(d.meaning).font(.body)
            }
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
            Text(analysis.shortSummary).font(.body).textSelection(.enabled)
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
              Text(q.question).font(.body).textSelection(.enabled).padding(.vertical, 2)
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
          RichBodyView(text: body)
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

  @State private var bookmarkFavicon: UIImage?

  private var bookmarkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let urlStr = item.importSourceURL, let url = URL(string: urlStr) {
        VStack(spacing: 12) {
          // Preview card
          HStack(spacing: 12) {
            // Favicon
            if let favicon = bookmarkFavicon {
              Image(uiImage: favicon)
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color(.systemBackground))
            } else {
              Image(systemName: "bookmark.fill")
                .font(.title).foregroundStyle(.green)
                .frame(width: 48, height: 48)
                .background(.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 4) {
              Text(item.title).font(.subheadline).fontWeight(.medium)
              Text(urlStr)
                .font(.caption).foregroundStyle(.blue).lineLimit(1)
              if let host = url.host {
                Text(host).font(.caption2).foregroundStyle(.secondary)
              }
            }
            Spacer()
          }

          // Actions
          HStack(spacing: 16) {
            Link(destination: url) {
              HStack(spacing: 4) {
                Image(systemName: "safari")
                Text("Open")
              }
              .font(.subheadline).fontWeight(.medium)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(.blue, in: RoundedRectangle(cornerRadius: 10))
              .foregroundStyle(.white)
            }

            Button {
              UIPasteboard.general.string = urlStr
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                Text("Copy URL")
              }
              .font(.subheadline)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { loadFavicon(url: url) }
      }
    }
    .padding(.horizontal, 16)
  }

  private func loadFavicon(url: URL) {
    guard let host = url.host else { return }
    guard let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    else { return }
    let task = URLSession.shared.dataTask(with: faviconURL) { data, _, _ in
      if let data, let img = UIImage(data: data) {
        Task { @MainActor in bookmarkFavicon = img }
      }
    }
    task.resume()
  }

  // MARK: - Image

  @State private var scannedPages: [UIImage] = []
  @State private var currentPage = 0

  @ViewBuilder
  private var imageSection: some View {
    // Show extracted text even if images failed to load
    if let text = item.bodyText, !text.isEmpty {
      let hasVision = text.contains("VISUAL ANALYSIS")
      VStack(alignment: .leading, spacing: 6) {
        Label(
          hasVision ? "OCR + Vision" : "OCR Text",
          systemImage: hasVision ? "eye.fill" : "doc.text.magnifyingglass"
        )
        .font(.subheadline).fontWeight(.medium)
        .foregroundStyle(hasVision ? .purple : .secondary)
        Text(text).font(.body)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 16)
    }

    if scannedPages.isEmpty {
      if item.bodyText?.isEmpty != false {
        Text("No scanned image")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
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
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  deletePage(idx)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
          }
        }
        .tabViewStyle(.page(indexDisplayMode: scannedPages.count > 1 ? .always : .never))
        .frame(minHeight: 350)
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

  private func deletePage(_ index: Int) {
    let dir = fileStore.itemDirectoryURL(for: item.id)
    let count = scannedPages.count
    guard count > 1 else { return }  // Don't delete the only page

    // Delete the page file
    let pageURL = dir.appendingPathComponent("scan_\(index).jpg")
    try? FileManager.default.removeItem(at: pageURL)

    // Re-index remaining pages (shift down)
    for i in (index + 1)..<count {
      let oldURL = dir.appendingPathComponent("scan_\(i).jpg")
      let newURL = dir.appendingPathComponent("scan_\(i - 1).jpg")
      try? FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    // Update metadata
    item.imagePageCount = count - 1
    if index == 0 { item.imageFileRelativePath = count > 1 ? "scan_0.jpg" : nil }
    try? modelContext.save()

    // Reload
    if currentPage >= count - 1 { currentPage = max(0, count - 2) }
    scannedPages = loadScannedPages(count: count - 1)
  }

  // MARK: - Raw Response (debug)

  @ViewBuilder
  private var rawResponseSection: some View {
    let rawURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(
      "provider.response.raw.txt")
    let iterativeURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(
      "analysis.iterative.txt")
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
          Text("Iterative: \(iterText.prefix(2000))").font(.caption).foregroundStyle(.secondary)
            .padding(8)
            .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(12).background(Color.orange.opacity(0.06)).clipShape(
        RoundedRectangle(cornerRadius: 12)
      )
      .padding(.horizontal, 16)
    }
  }

  // MARK: - Annotations

  private var annotationsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Context").font(.headline)
      ForEach(filteredAnnotationKeys.sorted(by: <), id: \.self) { key in
        if let rawValue = groupedAnnotations[key]?.first {
          HStack(spacing: 4) {
            Text(contextLabel(for: key))
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(contextValue(for: key, raw: rawValue))
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

  // MARK: - Context label/value formatting

  private func contextLabel(for key: String) -> String {
    switch key {
    case "route_name": "Microphone"
    case "route_type": "Audio Type"
    case "level": "Battery"
    case "state": "Charging"
    case "event_title": "Calendar"
    case "event_proximity": "When"
    case "event_location": "Event Location"
    case "place_name", "city", "country": "Location"
    case "lat", "lon", "accuracy": "GPS"
    case "activity": "Activity"
    case "confidence": "Confidence"
    default: key.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  private func contextValue(for key: String, raw: String) -> String {
    switch key {
    case "level": "\(raw)%"
    case "lat", "lon": String(raw.prefix(8))
    case "accuracy": "±\(raw)m"
    case "activity": raw.capitalized
    case "focus_active": raw == "true" ? "On" : "Off"
    case "event_proximity":
      switch raw {
      case "during": "During meeting"
      case "before": "Upcoming"
      case "after": "Just ended"
      default: raw
      }
    default: raw
    }
  }

  private var groupedAnnotations: [String: [String]] {
    var result: [String: [String]] = [:]
    for ann in annotations {
      if ann.key == "focus_active" { continue }
      result[ann.key, default: []].append(ann.value)
    }
    return result
  }

  private var filteredAnnotationKeys: [String] {
    // Show most important keys first
    let priority = [
      "event_title", "event_proximity", "place_name", "city",
      "route_name", "activity", "level", "state",
    ]
    let all = Array(groupedAnnotations.keys)
    let ordered = priority.filter { all.contains($0) }
    let rest = all.filter { !priority.contains($0) }.sorted()
    return ordered + rest
  }

  // MARK: - Locale picker

  private var availableLocales: [(id: String, name: String)] {
    TranscriptionLocaleProvider.availableLocales
  }

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
    // Check for audio via manifest (segmented) or legacy audio.m4a
    let hasAudio =
      fileStore.recordingManifestExists(for: item.id)
      || fileStore.audioFileExists(for: item.id)
    guard hasAudio else {
      transcriptionError = "Audio file not found."
      return
    }

    isTranscribing = true
    transcriptionProgress = "Transcribing..."
    transcriptionError = nil

    // Delegate to canonical transcription service (handles manifest + legacy).
    // Pass selectedLocale so the user's language choice is honoured.
    let extractionSvc = ContentExtractionService(
      modelContext: modelContext, fileStore: fileStore, preferredLocale: selectedLocale)
    if let text = await extractionSvc.extractTextFromAudio(item) {
      transcript = try? fileStore.readArtifact(
        Transcript.self, fileName: "transcript.json", meetingId: item.id)
      isTranscribing = false
      transcriptionProgress = nil
      item.status = .transcribed
      try? modelContext.save()

      // Auto-run pipeline (agent-based) after transcription
      if (try? ProviderRouter.resolveActive(context: modelContext)) != nil {
        processingQueue.enqueue(itemID: item.id, trigger: .directUserAction)
      }
      return
    }

    // extractionSvc.extractTextFromAudio returned nil — transcription failed
    transcriptionError = "No speech detected or recognition failed."
    isTranscribing = false
    transcriptionProgress = nil
  }

  // MARK: - Helpers

  /// Load raw JSON from analysis files — no key expectations, renders anything.
  private func loadRawAnalysisJSON() {
    let dir = fileStore.itemDirectoryURL(for: item.id)

    // Try analysis.json first (agent WriteAnalysisTool output)
    if let data = try? Data(contentsOf: dir.appendingPathComponent("analysis.json")),
      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      // Strip metadata wrapper added by WriteAnalysisTool
      json.removeValue(forKey: "_metadata")
      if !json.isEmpty {
        rawAnalysisJSON = json
        return
      }
    }

    // Try analysis.dynamic.json (pipeline DynamicAnalysis output)
    if let data = try? Data(contentsOf: dir.appendingPathComponent("analysis.dynamic.json")),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = dict["results"] as? [String: Any],
      let storage = results["storage"] as? [String: Any]
    {
      rawAnalysisJSON = storage
    }
  }

  private func loadData() {
    if selectedModel.isEmpty {
      selectedModel = ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
    }
    // Sync locale picker with the item's persisted language hint.
    // This ensures the two language elements stay aligned: the view-state
    // selectedLocale (used by manual "Transcribe Now") and the model's
    // languageCode (used by the automatic pipeline).
    if let lang = item.languageCode, !lang.isEmpty {
      selectedLocale = lang
    }
    transcript = try? fileStore.readArtifact(
      Transcript.self, fileName: "transcript.json", meetingId: item.id)
    analysis = try? fileStore.readArtifact(
      MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
    if analysis == nil { loadRawAnalysisJSON() }

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
      title: editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? item.title : editedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
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

  private func reprocessItem(
    mode: ReprocessMode = .analyzeOnly,
    confirmed: Bool = false,
    engine: TranscriptionOverride? = nil
  ) async {
    // Whisper requires an OpenAI-compatible provider. Check before we clear state.
    if engine == .whisper {
      let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext)
      let canWhisper = config != nil && config?.baseURL != nil
      if !canWhisper {
        await MainActor.run { showWhisperKeyAlert = true }
        return
      }
    }

    // Guard against double-tap or race conditions
    guard !isReprocessing else { return }
    // Whisper needs a provider with base URL; checked above via showWhisperKeyAlert.
    // Apple on-device and Cloud fallback don't require an external provider.
    // Re-analysis modes always need an AI provider.
    if mode != .transcribeOnly,
      !AIConfigService.shared.isAnalysisAvailable(context: modelContext)
    {
      analysisError = "No AI provider with an API key is configured. Go to Settings → AI Services."
      return
    }
    // Check for user-owned fields before re-processing (analysis modes only)
    if !confirmed, mode != .transcribeOnly {
      let userOwned = ["title", "bodyText"].filter { item.provenance.isUserOwned(field: $0) }
      if !userOwned.isEmpty {
        showReprocessWarning = true
        pendingReprocessMode = mode
        pendingReprocessEngine = engine
        return
      }
    }

    isReprocessing = true
    analysisError = nil
    defer { isReprocessing = false }

    // Override engine preference based on explicit user choice.
    if mode == .transcribeOnly || mode == .full, let engine {
      switch engine {
      case .appleOnDevice:
        TranscriptionSettings.shared.mode = .apple
        UserDefaults.standard.set(false, forKey: "transcription_allow_cloud")
      case .appleCloud:
        TranscriptionSettings.shared.mode = .apple
        UserDefaults.standard.set(true, forKey: "transcription_allow_cloud")
      case .whisper:
        TranscriptionSettings.shared.mode = .whisper
      }
    }

    let dir = fileStore.itemDirectoryURL(for: item.id)
    let doTranscribe = mode == .transcribeOnly || mode == .full
    let doAnalyze = mode == .analyzeOnly || mode == .full

    // ── Clear state ─────────────────────────────────────────────
    if doTranscribe {
      if item.type == .audio {
        item.transcriptionEngineId = nil
        item.status = .recorded
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        transcript = nil
      } else if item.type == .image {
        item.bodyText = nil
        item.status = .recorded
      }
    }
    if doAnalyze {
      item.analysisProviderId = nil
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.json"))
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("analysis.dynamic.json"))
      try? FileManager.default.removeItem(
        at: dir.appendingPathComponent("provider.response.raw.txt"))
      analysis = nil
      rawAnalysisJSON = [:]
    }
    // Prevent autoProcessPendingItems from double-processing.
    item.inboxDate = nil
    try? modelContext.save()

    // ── Run ────────────────────────────────────────────────────
    if doTranscribe && !doAnalyze {
      // Extraction-only: run directly with visible progress indicator.
      // The queue would also run Phase 2 (analysis) which we don't want.
      isTranscribing = true
      let extractionSvc = ContentExtractionService(
        modelContext: modelContext, fileStore: fileStore, preferredLocale: selectedLocale)
      if item.type == .audio {
        _ = await extractionSvc.extractTextFromAudio(item)
      } else if item.type == .image {
        _ = await extractionSvc.extractTextFromImage(item)
      }
      isTranscribing = false
      let fetchedItem = try? KnowledgeItemService(context: modelContext).fetchItem(id: item.id)
      AppLog.provider.info(
        "🔍 reprocessItem: extraction done — bodyText=\(fetchedItem?.bodyText?.count ?? 0) chars, hasVision=\(fetchedItem?.bodyText?.contains("VISUAL ANALYSIS") ?? false)"
      )
      refreshID = UUID()
      loadData()
    } else {
      // Analysis or full reprocess: enqueue for pipeline processing.
      // The queue handles both extraction + analysis with full progress tracking.
      processingQueue.enqueue(
        itemID: item.id, projectID: item.projectID,
        trigger: .directUserAction)
      AppLog.provider.info(
        "🔍 reprocessItem: enqueued mode=\(mode) for \(item.id.uuidString.prefix(8))")
    }
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
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
  }

  /// Get the first available extracted text for review (transcript, body, raw body).
  private func extractionPreview() -> String? {
    if let transcript = try? fileStore.readArtifact(
      Transcript.self, fileName: "transcript.json", meetingId: item.id)
    {
      let text = transcript.segments.map(\.text).joined(separator: " ")
      if !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
    }
    if let body = item.bodyText, !body.trimmingCharacters(in: .whitespaces).isEmpty {
      return body
    }
    return nil
  }

  /// Reads speakers.json and returns pending_confirmations array if present.
  private func pendingConfirmations() -> [[String: Any]]? {
    let url = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("speakers.json")
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pending = json["pending_confirmations"] as? [[String: Any]],
      !pending.isEmpty
    else { return nil }
    return pending
  }

  /// Handles user confirmation for a speaker. Builds a prompt from the answer
  /// and triggers a new agent iteration via the processing queue.
  private func confirmSpeaker(_ index: Int, answer: String) {
    guard var pending = pendingConfirmations(), index < pending.count else { return }
    guard var speakers = readSpeakersJSON() else { return }

    let pc = pending[index]
    let label = pc["speaker_label"] as? String ?? "Unknown"
    let guess = pc["best_guess"] as? String ?? "Unknown"

    // Build confirmation message for the agent
    var confirmMsg: String
    switch answer {
    case "yes":
      confirmMsg =
        "✅ CONFIRMED: \(label) is \(guess). Update speakers.json to mark this as high confidence."
      // Update in-memory: move from pending to confirmed
      speakers["speakers"] =
        (speakers["speakers"] as? [[String: Any]] ?? []) + [
          [
            "label": label, "resolved_to": guess, "confidence": "high",
            "evidence_summary": "User confirmed this identification.",
          ]
        ]
      pending.remove(at: index)
    case "no":
      confirmMsg = "❌ REJECTED: \(label) is NOT \(guess). Remove this candidate and reconsider."
      pending.remove(at: index)
    default:  // rephrase
      confirmMsg =
        "❓ REPHRASE: The user wants you to reformulate the question about \(label). Use data from other confirmed speakers to improve."
      // Keep pending, add rephrase flag
      pending[index] = pc.merging(["rephrase": true]) { $1 }
    }

    speakers["pending_confirmations"] = pending

    // Write updated speakers.json
    let url = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("speakers.json")
    if let data = try? JSONSerialization.data(withJSONObject: speakers, options: [.prettyPrinted]) {
      try? data.write(to: url, options: .atomic)
    }

    // Enqueue re-analysis with confirmation context
    item.analysisProviderId = nil
    try? modelContext.save()
    processingQueue.enqueue(
      itemID: item.id, projectID: item.projectID,
      trigger: .directUserAction)
    AppLog.provider.info(
      "🔍 confirmSpeaker: enqueued re-analysis for \(item.id.uuidString.prefix(8))")
  }

  /// Reads the full speakers.json file.
  private func readSpeakersJSON() -> [String: Any]? {
    let url = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("speakers.json")
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
  }

  // MARK: - Agent event badge

  @ViewBuilder
  private func agentEventBadge(_ evt: PipelineAgentEvent) -> some View {
    Group {
      switch evt.kind {
      case .thinking:
        Label(evt.detail.isEmpty ? "Thinking" : evt.detail, systemImage: "brain")
          .font(.caption2)
          .foregroundStyle(.purple)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.purple.opacity(0.1))
          .clipShape(Capsule())
      case .toolCall:
        Label(evt.detail, systemImage: "hammer")
          .font(.caption2)
          .foregroundStyle(.blue)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.blue.opacity(0.1))
          .clipShape(Capsule())
      case .toolResult:
        Label(evt.detail, systemImage: "checkmark.circle")
          .font(.caption2)
          .foregroundStyle(.green)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.green.opacity(0.1))
          .clipShape(Capsule())
      case .textDelta:
        Text(evt.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color(.tertiarySystemFill))
          .clipShape(Capsule())
      case .done:
        Label("Done", systemImage: "checkmark")
          .font(.caption2)
          .foregroundStyle(.green)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.green.opacity(0.1))
          .clipShape(Capsule())
      case .failed:
        Label(evt.detail.prefix(40), systemImage: "xmark.circle")
          .font(.caption2)
          .foregroundStyle(.red)
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.red.opacity(0.1))
          .clipShape(Capsule())
      }
    }
  }

  private func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m)m"
  }

  private func card<Content: View>(
    title: String, systemImage: String, copyText: String? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: systemImage).font(.headline)
        Spacer()
        if let copyText {
          Button {
            UIPasteboard.general.string = copyText
          } label: {
            Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
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

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let rows = arrange(
      proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
    for row in rows {
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y), proposal: .unspecified)
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

  struct LayoutItem {
    let index: Int
    let x: CGFloat
    let width: CGFloat
    let height: CGFloat
  }
  struct LayoutRow {
    let items: [LayoutItem]
    let y: CGFloat
    var maxY: CGFloat { (items.map(\.height).max() ?? 0) + y }
  }
}

// MARK: - Rich Body Renderer

/// Renders markdown body text as native SwiftUI using ContentParser.
/// Falls back to plain text if parsing fails or produces no structure.
struct RichBodyView: View {
  let text: String

  var body: some View {
    let (blocks, _) = ContentParser.parse(text)
    if blocks.count > 1
      || (blocks.count == 1 && { if case .text = blocks[0] { false } else { true } }())
    {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(blocks) { block in
          OutputBlockRenderer(block: block)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      // Fallback: plain text with basic markdown
      let md =
        (try? AttributedString(
          markdown: text,
          options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
      Text(md)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Mood Helpers

private func moodEmoji(_ mood: String) -> String {
  switch mood.lowercased() {
  case "great": return "😄"
  case "good": return "🙂"
  case "okay", "ok": return "😐"
  case "bad": return "😞"
  case "terrible": return "😢"
  case "anxious": return "😰"
  case "excited": return "🤩"
  case "tired": return "😴"
  case "grateful": return "🙏"
  case "productive": return "💪"
  case "reflective": return "🤔"
  default: return mood.first.map { String($0) }?.uppercased() ?? "•"
  }
}

private func moodColor(_ mood: String) -> Color {
  switch mood.lowercased() {
  case "great", "excited", "grateful", "productive": return .green
  case "good": return .blue
  case "okay", "ok", "reflective": return .secondary
  case "bad", "tired": return .orange
  case "terrible", "anxious": return .red
  default: return .secondary
  }
}

private func confidenceColor(_ conf: Double) -> Color {
  switch conf {
  case 0.9...1.0: return .green
  case 0.7..<0.9: return .blue
  case 0.5..<0.7: return .orange
  default: return .red
  }
}

// MARK: - Confidence Bar

struct ConfidenceBar: View {
  let confidence: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color(.systemGray5))
        RoundedRectangle(cornerRadius: 2)
          .fill(confidenceColor(confidence))
          .frame(width: geo.size.width * confidence)
      }
    }
  }

  private func confidenceColor(_ conf: Double) -> Color {
    switch conf {
    case 0.9...1.0: return .green
    case 0.7..<0.9: return .blue
    case 0.5..<0.7: return .orange
    default: return .red
    }
  }
}
