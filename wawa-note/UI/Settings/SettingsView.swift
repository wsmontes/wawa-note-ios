import OSLog
import Speech
import SwiftData
import SwiftUI

// Related JIRA: KAN-10, KAN-52

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @State private var showLogShareSheet = false
    @State private var logShareURL: URL?
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var transcriptionMode: TranscriptionMode = TranscriptionSettings.shared.mode
    @State private var autoTranscribe: Bool = AutomationSettings.shared.autoTranscribe
    @State private var autoAnalyze: Bool = AutomationSettings.shared.autoAnalyze
    @State private var autoAnalysisModel: String = AutomationSettings.shared.autoAnalysisModel
    @State private var useVoiceProcessing: Bool = AudioSessionManager.useVoiceProcessing
    @State private var speakerphoneMode: Bool = AudioSessionManager.speakerphoneMode
    @State private var preferBuiltInMic: Bool = AudioSessionManager.preferBuiltInMicOverBluetooth
    @State private var allowCloudTranscription: Bool = TranscriptionSettings.shared.allowCloud
    @State private var developerModeEnabled: Bool = UserDefaults.standard.bool(forKey: "developer_mode_enabled")

    /// All available models for the auto-analysis picker, sourced exclusively
    /// from the user's active AI providers — never from hardcoded presets.
    private var availableAutoAnalysisModels: [String] {
        var models = Set<String>()

        // Collect models from ALL configured providers, not just the active one.
        // The user may switch providers and should see all options.
        let allConfigs = ActiveProviderManager.shared.allProviders(context: modelContext)
        for config in allConfigs {
            // Provider's persisted available models (from connection flow)
            config.availableModels.forEach { models.insert($0) }
            // Default model for the provider
            if !config.defaultModel.isEmpty { models.insert(config.defaultModel) }
            // Models from ai_config.json for this provider
            let staticModels = AIConfigService.shared.availableModels(for: config.providerConfigId)
            staticModels.forEach { models.insert($0) }
            let typeModels = AIConfigService.shared.availableModels(for: config.typeRaw)
            typeModels.forEach { models.insert($0) }
        }

        // Always include the currently selected model so it's never hidden
        models.insert(autoAnalysisModel)

        // Filter out transcription-only models
        models.remove("whisper-1")

        return models.sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                // AI Services
                Section {
                    NavigationLink {
                        ProviderPickerView()
                    } label: {
                        Label("AI Services", systemImage: "brain.head.profile")
                    }
                } header: {
                    Text("AI & Transcription")
                }

                // Transcription mode
                Section {
                    Picker("Transcription Engine", selection: $transcriptionMode) {
                        Text(TranscriptionMode.apple.label)
                            .tag(TranscriptionMode.apple)
                        Text(TranscriptionMode.whisper.label)
                            .tag(TranscriptionMode.whisper)
                    }
                    .pickerStyle(.menu)

                    if transcriptionMode == .apple {
                        Toggle("Allow Cloud Processing", isOn: $allowCloudTranscription)
                            .onChange(of: allowCloudTranscription) { _, v in
                                UserDefaults.standard.set(v, forKey: "transcription_allow_cloud")
                            }
                    }
                } header: {
                    Text("Transcription Mode")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if transcriptionMode == .whisper {
                            if hasWhisperProvider {
                                Text("Whisper API will be used. Language is auto-detected — no need to pick a locale.")
                            } else {
                                Text("No provider with audio support configured. Add an OpenAI API key in AI Services to use Whisper.")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("On-device transcription. Works offline, no API key needed. Locale: \(supportedLocales().joined(separator: ", "))")
                            if allowCloudTranscription {
                                Text("Cloud processing may improve accuracy but sends audio to Apple servers.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onChange(of: transcriptionMode) { _, newValue in
                    TranscriptionSettings.shared.mode = newValue
                }

                // Automation
                Section {
                    Toggle("Automatic Transcription", isOn: $autoTranscribe)
                        .onChange(of: autoTranscribe) { _, v in AutomationSettings.shared.autoTranscribe = v }
                    Toggle("Automatic Analysis", isOn: $autoAnalyze)
                        .onChange(of: autoAnalyze) { _, v in AutomationSettings.shared.autoAnalyze = v }

                    if autoAnalyze {
                        Picker("Analysis Model", selection: $autoAnalysisModel) {
                            ForEach(availableAutoAnalysisModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: autoAnalysisModel) { _, v in
                            AutomationSettings.shared.autoAnalysisModel = v
                        }
                    }
                } header: {
                    Text("Automation")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("When enabled, new recordings are transcribed and analyzed automatically after saving.")
                        if autoAnalyze {
                            Text("Automatic analysis uses the selected model above. Pick a fast, affordable model for cost efficiency.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Audio
                Section {
                    Toggle("Voice Processing", isOn: $useVoiceProcessing)
                        .onChange(of: useVoiceProcessing) { _, v in
                            AudioSessionManager.useVoiceProcessing = v
                        }
                    Toggle("Speakerphone Mode", isOn: $speakerphoneMode)
                        .onChange(of: speakerphoneMode) { _, v in
                            AudioSessionManager.speakerphoneMode = v
                        }
                    Toggle("Prefer Built-in Mic", isOn: $preferBuiltInMic)
                        .onChange(of: preferBuiltInMic) { _, v in
                            AudioSessionManager.preferBuiltInMicOverBluetooth = v
                        }
                } header: {
                    Text("Audio")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice Processing enhances speech clarity and reduces background noise. Disable for raw audio capture (music, ambient sound).")
                        if speakerphoneMode {
                            Text(
                                "Speakerphone Mode uses the front microphone array with far-field beamforming — ideal when the iPhone is on a table during meetings."
                            )
                            .foregroundStyle(.secondary)
                        }
                        if preferBuiltInMic {
                            Text(
                                "The iPhone microphone (48 kHz with beamforming) will be preferred over Bluetooth headsets (8 kHz call quality). Enable for maximum transcription accuracy."
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                // Knowledge workspace
                Section {
                    HStack {
                        Label("Items", systemImage: "tray.full")
                        Spacer()
                        Text("\(allItems.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Folders", systemImage: "folder")
                        Spacer()
                        Text("\(folders.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Library")
                }

                // Privacy
                Section {
                    HStack {
                        Label("Storage", systemImage: "lock.shield")
                        Spacer()
                        Text("On this iPhone")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Privacy & Data")
                }

                // Data Export
                Section {
                    if let jsonData = try? InstanceExportService().exportComplete(context: modelContext, includeHistory: false),
                        let jsonStr = String(data: jsonData, encoding: .utf8)
                    {
                        let stats = InstanceExportService().exportStatistics(context: modelContext)
                        ShareLink(item: jsonStr, preview: SharePreview("Wawa Note Export", image: Image(systemName: "doc.text"))) {
                            HStack {
                                Label("Export Complete JSON", systemImage: "arrow.up.doc")
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(stats.itemCount) items").font(.caption).foregroundStyle(.secondary)
                                    let size = ByteCountFormatter.string(fromByteCount: Int64(jsonData.count), countStyle: .file)
                                    Text(size).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Exports all projects, items, analyses, signals, frames, prompts, and configuration as a complete JSON file. File may be large.")
                }

                // Anarlog Sync
                Section {
                    // Anarlog Sync removed (KAN-258)
                } header: {
                    Text("Synchronization")
                } footer: {
                    Text("Sync meeting notes with anarlog desktop app. Choose a shared folder to enable bidirectional import and export of .md session notes.")
                }

                // Analysis Skills
                Section {
                    NavigationLink {
                        SkillsSettingsView()
                    } label: {
                        Label("Analysis Skills", systemImage: "sparkles")
                    }
                    NavigationLink {
                        AnalysisSchemaSettingsView()
                    } label: {
                        Label("Analysis Fields", systemImage: "square.grid.3x3")
                    }
                } header: {
                    Text("AI Analysis")
                } footer: {
                    Text("Configure how the AI analyzes your content. Each skill defines a procedure and output format for a specific type of content.")
                }

                // Debug Logs
                Section {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        Label("Debug Logs", systemImage: "terminal")
                    }
                    Toggle("Developer Mode", isOn: $developerModeEnabled)
                        .onChange(of: developerModeEnabled) { _, v in
                            UserDefaults.standard.set(v, forKey: "developer_mode_enabled")
                        }
                } header: {
                    Text("Developer")
                } footer: {
                    let crashed = FileLogService.shared.previousSessionCrashed
                    Text(
                        crashed
                            ? "⚠️ Previous session crashed. Logs may contain crash information."
                            : "Developer Mode shows raw LLM responses in knowledge detail views.")
                }

                // Advanced
                Section {
                    NavigationLink {
                        LensesSettingsView()
                    } label: {
                        Label("AI Lenses", systemImage: "eye")
                    }
                    // Model Resolution + Summary Cache removed (KAN-258)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Fine-tune AI behavior. Lenses define analysis perspectives for different content types.")
                }

                // MARK: Debug Logs (KAN-257)
                Section {
                    HStack {
                        Text("Log Size")
                        Spacer()
                        Text(ByteCountFormatter().string(fromByteCount: FileLogService.shared.totalLogSize))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        let data = FileLogService.shared.exportLogsJSON()
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("wawa-logs-\(ISO8601DateFormatter().string(from: Date())).json")
                        try? data.write(to: tempURL)
                        logShareURL = tempURL
                        showLogShareSheet = true
                    } label: {
                        Label("Export Logs (JSON)", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Exports timestamped logs as JSON for external analysis. View in Console.app with subsystem filter: com.wawa-note.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogShareSheet) {
                if let url = logShareURL {
                    ActivityView(activityItems: [url])
                }
            }
            .onAppear {
                // Ensure auto-analysis model comes from the user's configured
                // providers, never from hardcoded defaults. If the current
                // model is invalid or empty, pick the first available one.
                let valid = availableAutoAnalysisModels
                if autoAnalysisModel.isEmpty, let first = valid.first {
                    autoAnalysisModel = first
                    AutomationSettings.shared.autoAnalysisModel = first
                } else if !valid.contains(autoAnalysisModel), let first = valid.first {
                    autoAnalysisModel = first
                    AutomationSettings.shared.autoAnalysisModel = first
                }
            }
        }
    }

    // MARK: - Debug Log Viewer

    struct DebugLogView: View {
        @State private var logs: String = ""
        @State private var isLoading = true

        var body: some View {
            Group {
                if isLoading {
                    ProgressView("Loading logs...")
                } else if logs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No logs yet").font(.headline)
                        Text("Logs will appear here as the app runs.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        Text(logs)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .navigationTitle("Debug Logs")
            .safeAreaInset(edge: .top) {
                Text("⚠️ Logs may contain personal data (transcripts, file paths, metadata). API keys are automatically redacted. Review before sharing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            isLoading = true
                            logs =
                                FileLogService.shared.retrieveLogs()
                                + "\n\n=== OSLOG (audio) ===\n"
                                + (DebugLogView.retrieveOSLogs() ?? "OSLog not available")
                            isLoading = false
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button {
                            FileLogService.shared.clearLogs()
                            logs = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                        if let url = FileLogService.shared.exportLogs() {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .onAppear {
                logs =
                    FileLogService.shared.retrieveLogs()
                    + "\n\n=== OSLOG (audio) ===\n"
                    + (DebugLogView.retrieveOSLogs() ?? "OSLog not available")
                isLoading = false
            }
            .refreshable {
                logs =
                    FileLogService.shared.retrieveLogs()
                    + "\n\n=== OSLOG (audio) ===\n"
                    + (DebugLogView.retrieveOSLogs() ?? "OSLog not available")
            }
        }

        static func retrieveOSLogs() -> String? {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
            let position = store.position(date: Date().addingTimeInterval(-3600))
            var lines: [String] = []
            for entry in (try? store.getEntries(at: position)) ?? AnySequence([]) {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let msg = logEntry.composedMessage
                guard
                    msg.contains("audio") || msg.contains("Audio") || msg.contains("recording") || msg.contains("Recording") || msg.contains("route")
                        || msg.contains("Route")
                        || msg.contains("engine") || msg.contains("Engine") || msg.contains("session") || msg.contains("Session")
                        || msg.contains("segment") || msg.contains("Segment")
                else { continue }
                lines.append("[\(logEntry.date.formatted(.iso8601))] [\(logEntry.level)] \(msg)")
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    // MARK: - AI Lenses Settings

    struct LensesSettingsView: View {
        private var lensEntries: [(key: String, lens: AIConfig.LensJSON)] {
            guard let lenses = AIConfigService.shared.config.lenses else { return [] }
            return lenses.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        }

        var body: some View {
            List {
                if lensEntries.isEmpty {
                    ContentUnavailableView(
                        "No Lenses Configured",
                        systemImage: "eye.slash",
                        description: Text("AI lenses are defined in ai_config.json. Add lenses to enable different analysis perspectives.")
                    )
                } else {
                    ForEach(lensEntries, id: \.key) { entry in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: entry.lens.icon ?? "sparkles")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                    Text(entry.lens.name ?? entry.key)
                                        .font(.headline)
                                }
                                if let desc = entry.lens.description {
                                    Text(desc)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let model = entry.lens.model {
                                    LabeledContent("Default Model", value: model)
                                }
                                if let temp = entry.lens.temperature {
                                    LabeledContent("Temperature", value: String(format: "%.1f", temp))
                                }
                                if let prompt = entry.lens.systemPrompt {
                                    DisclosureGroup("System Prompt") {
                                        Text(prompt)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("AI Lenses")
        }
    }

    // MARK: - Model Resolver Settings

    struct ModelResolverSettingsView: View { var body: some View { EmptyView() } }
    // MARK: - Summary Cache Management

    struct SummaryCacheManagementView: View { var body: some View { EmptyView() } }

    // MARK: - Analysis Schema Settings

    struct AnalysisSchemaSettingsView: View {
        var body: some View {
            List {
                Section {
                    Text("Choose which fields the AI should include when analyzing content.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(AnalysisFieldSettings.allFields, id: \.self) { field in
                        HStack {
                            Image(systemName: AnalysisFieldSettings.icon(for: field))
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AnalysisFieldSettings.displayName(for: field))
                                    .font(.subheadline)
                                Text("Include in analysis output")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { AnalysisFieldSettings.isEnabled(field) },
                                    set: { AnalysisFieldSettings.setEnabled(field, enabled: $0) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text("Enabled Fields")
                } footer: {
                    let enabled = AnalysisFieldSettings.allFields.filter { AnalysisFieldSettings.isEnabled($0) }
                    let disabled = AnalysisFieldSettings.allFields.filter { !AnalysisFieldSettings.isEnabled($0) }
                    if !disabled.isEmpty {
                        Text(
                            "\(enabled.count) of \(AnalysisFieldSettings.allFields.count) fields enabled. Disabled fields will be excluded from AI analysis instructions."
                        )
                    } else {
                        Text("All fields enabled. The AI will include whatever fields are relevant to the content.")
                    }
                }
            }
            .navigationTitle("Analysis Fields")
        }
    }

    private var hasWhisperProvider: Bool {
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
            let keyId = config.apiKeyKeychainIdentifier,
            let apiKey = try? SecureKeyStore().loadAPIKey(for: keyId),
            !apiKey.isEmpty
        else {
            return false
        }
        return config.type == .openAI || config.type == .openAICompatible
    }

    private func supportedLocales() -> [String] {
        let all = SFSpeechRecognizer.supportedLocales()
        let configured = Set(["pt-BR", "pt-PT", "en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "ja-JP", "zh-CN"])
        let available = all.filter { configured.contains($0.identifier) }
        let usable = available.filter { SFSpeechRecognizer(locale: $0)?.isAvailable == true }
        if usable.isEmpty { return [Locale(identifier: "en-US").identifier] }
        return usable.map(\.identifier)
    }
}

// MARK: - UIActivityViewController Wrapper (KAN-257)

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
