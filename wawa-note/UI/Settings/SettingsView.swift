import SwiftUI
import SwiftData
import Speech

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var transcriptionMode: TranscriptionMode = TranscriptionSettings.shared.mode
    @State private var autoTranscribe: Bool = AutomationSettings.shared.autoTranscribe
    @State private var autoAnalyze: Bool = AutomationSettings.shared.autoAnalyze

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
                } header: {
                    Text("Automation")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("When enabled, new recordings are transcribed and analyzed automatically after saving.")
                        if autoAnalyze {
                            Text("Automatic analysis uses a fast, affordable model (GPT-5 nano). Manual re-analysis uses your selected model.")
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
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
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
                    NavigationLink {
                        AnarlogSyncSettingsView()
                    } label: {
                        Label("Anarlog Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Synchronization")
                } footer: {
                    Text("Sync meeting notes with anarlog desktop app. Choose a shared folder to enable bidirectional import and export of .md session notes.")
                }

                // Debug Logs
                Section {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        Label("Debug Logs", systemImage: "terminal")
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    let crashed = FileLogService.shared.previousSessionCrashed
                    Text(crashed
                         ? "⚠️ Previous session crashed. Logs may contain crash information."
                         : "Persistent logs survive crashes. Use for debugging.")
                }
            }
            .navigationTitle("Settings")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
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
        .onAppear { logs = FileLogService.shared.retrieveLogs(); isLoading = false }
        .refreshable { logs = FileLogService.shared.retrieveLogs() }
    }
}

    private var hasWhisperProvider: Bool {
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              let keyId = config.apiKeyKeychainIdentifier,
              let apiKey = try? SecureKeyStore().loadAPIKey(for: keyId),
              !apiKey.isEmpty else {
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
