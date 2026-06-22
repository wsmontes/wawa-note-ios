import SwiftUI
import SwiftData
// Related JIRA: KAN-10, KAN-52


struct ProviderDetailView: View {
    let provider: AIProviderConfigModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirmation = false
    @State private var showEditor = false

    private let keychain = SecureKeyStore()

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(provider.name).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Type")
                    Spacer()
                    Text(provider.type.displayName).foregroundStyle(.secondary)
                }
                if let url = provider.baseURLString {
                    HStack {
                        Text("Address")
                        Spacer()
                        Text(url).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    Text(provider.defaultModel).foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection")
            }

            Section {
                HStack {
                    Text("Streaming")
                    Spacer()
                    Image(systemName: provider.supportsStreaming ? "checkmark" : "xmark")
                        .foregroundStyle(provider.supportsStreaming ? .green : .secondary)
                }
                HStack {
                    Text("Audio")
                    Spacer()
                    Image(systemName: provider.supportsAudio ? "checkmark" : "xmark")
                        .foregroundStyle(provider.supportsAudio ? .green : .secondary)
                }
                HStack {
                    Text("Tools")
                    Spacer()
                    Image(systemName: provider.supportsTools ? "checkmark" : "xmark")
                        .foregroundStyle(provider.supportsTools ? .green : .secondary)
                }
            } header: {
                Text("Capabilities")
            }

            Section {
                Button {
                    showEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .navigationTitle(provider.name.isEmpty ? "AI Service" : provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            ProviderEditorView(existingProvider: provider)
        }
        .confirmationDialog(
            "Delete this AI service?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                deleteProvider()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The connection to \(provider.name.isEmpty ? "this service" : provider.name) will be removed.")
        }
    }

    private func deleteProvider() {
        if let keyId = provider.apiKeyKeychainIdentifier {
            try? keychain.deleteAPIKey(for: keyId)
        }
        modelContext.delete(provider)
        try? modelContext.save()
        dismiss()
    }
}
