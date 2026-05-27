import SwiftUI
import SwiftData
import Speech

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt) private var allItems: [KnowledgeItem]
    @Query(sort: \Folder.name) private var folders: [Folder]

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
                } footer: {
                    Text(transcriptionFooter)
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
                    Text("Knowledge Workspace")
                }

                // Privacy
                Section {
                    HStack {
                        Label("Storage", systemImage: "lock.shield")
                        Spacer()
                        Text("All data stored locally on this iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Transcription", systemImage: "text.alignleft")
                        Spacer()
                        Text(transcriptionMode)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Privacy & Data")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var transcriptionMode: String {
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              config.supportsAudio else {
            return "Apple Speech (on-device)"
        }
        return config.name
    }

    private var transcriptionFooter: String {
        let locales = supportedLocales()
        let base = "On-device: \(locales.joined(separator: ", "))"
        if let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
           config.supportsAudio {
            return "Remote (\(config.name)) + \(base)"
        }
        return base
    }

    private func supportedLocales() -> [String] {
        let all = SFSpeechRecognizer.supportedLocales()
        let configured = Set(["pt-BR", "pt-PT", "en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "ja-JP", "zh-CN"])
        var available = all.filter { configured.contains($0.identifier) }
        // Also check which are actually usable (language pack downloaded)
        let usable = available.filter { SFSpeechRecognizer(locale: $0)?.isAvailable == true }
        if usable.isEmpty {
            available = [Locale(identifier: "en-US")] // fallback
        }
        return usable.map { "\($0.identifier)✓" } + available.filter { !usable.contains($0) }.map { "\($0.identifier)⬇" }
    }
}

#Preview {
    SettingsView()
}
