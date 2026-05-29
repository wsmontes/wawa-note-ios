import SwiftUI
import SwiftData
import Speech

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var transcriptionMode: TranscriptionMode = TranscriptionSettings.shared.mode

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
            }
            .navigationTitle("Settings")
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
