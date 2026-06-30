import SwiftData
import SwiftUI

@MainActor
final class ProviderEditorViewModel: ObservableObject {
  @Published var name = ""
  @Published var type: ProviderType = .openAICompatible
  @Published var baseURLString = ""
  @Published var apiKey = ""
  @Published var defaultModel = ""
  @Published var supportsStreaming = true
  @Published var supportsAudio = false
  @Published var supportsTools = false
  @Published var supportsEmbeddings = false
  @Published var notes = ""

  @Published var connectionStatus: ConnectionStatus = .notTested
  @Published var isSaving = false

  private let keychain = SecureKeyStore()
  private let router = ProviderRouter()
  private var existingProvider: AIProviderConfigModel?
  private let keychainIdentifier: String

  enum ConnectionStatus {
    case notTested
    case testing
    case success
    case failed(String)
  }

  init(existingProvider: AIProviderConfigModel?) {
    self.existingProvider = existingProvider
    self.keychainIdentifier = existingProvider?.apiKeyKeychainIdentifier ?? UUID().uuidString

    guard let provider = existingProvider else { return }

    name = provider.name
    type = provider.type
    baseURLString = provider.baseURLString ?? ""
    defaultModel = provider.defaultModel
    supportsStreaming = provider.supportsStreaming
    supportsAudio = provider.supportsAudio
    supportsTools = provider.supportsTools
    supportsEmbeddings = provider.supportsEmbeddings
    notes = provider.notes ?? ""

    if let keyId = provider.apiKeyKeychainIdentifier {
      apiKey = (try? keychain.loadAPIKey(for: keyId)) ?? ""
    }
  }

  func save(context: ModelContext) {
    isSaving = true
    defer { isSaving = false }

    if let provider = existingProvider {
      update(provider: provider)
    } else {
      let provider = AIProviderConfigModel()
      context.insert(provider)
      update(provider: provider)
    }

    try? context.save()
  }

  private func update(provider: AIProviderConfigModel) {
    provider.name = name
    provider.type = type
    provider.baseURLString = baseURLString.nilIfEmpty
    provider.defaultModel = defaultModel
    provider.supportsStreaming = supportsStreaming
    provider.supportsAudio = supportsAudio
    provider.supportsTools = supportsTools
    provider.supportsEmbeddings = supportsEmbeddings
    provider.notes = notes.nilIfEmpty
    provider.apiKeyKeychainIdentifier = keychainIdentifier

    if !apiKey.isEmpty {
      try? keychain.saveAPIKey(apiKey, for: keychainIdentifier)
    } else if apiKey.isEmpty && existingProvider != nil {
      try? keychain.deleteAPIKey(for: keychainIdentifier)
    }
  }

  func testConnection() async {
    connectionStatus = .testing

    guard let url = URL(string: baseURLString) else {
      connectionStatus = .failed("Invalid URL")
      return
    }

    if !apiKey.isEmpty {
      try? keychain.saveAPIKey(apiKey, for: keychainIdentifier)
    }

    let testConfig = AIProviderConfigModel(
      name: name.isEmpty ? "Test" : name,
      type: type,
      baseURL: url,
      defaultModel: defaultModel.isEmpty ? "gpt-3.5-turbo" : defaultModel,
      supportsStreaming: supportsStreaming,
      supportsAudio: supportsAudio,
      supportsTools: supportsTools,
      supportsEmbeddings: supportsEmbeddings,
      apiKeyKeychainIdentifier: keychainIdentifier
    )

    do {
      let provider = try router.provider(for: testConfig)
      let request = AIRequest(
        model: defaultModel.isEmpty ? "gpt-3.5-turbo" : defaultModel,
        messages: [
          AIMessage(role: .user, content: [.text("Hello")])
        ],
        maxTokens: 50
      )
      let response = try await provider.send(request)
      connectionStatus = response.content.isEmpty ? .failed("Empty response") : .success
    } catch let error as ProviderError {
      connectionStatus = .failed(error.userMessage)
    } catch {
      connectionStatus = .failed("Could not connect to provider.")
    }

    if !apiKey.isEmpty && existingProvider == nil {
      try? keychain.deleteAPIKey(for: keychainIdentifier)
    }
  }
}

struct ProviderEditorView: View {
  let existingProvider: AIProviderConfigModel?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @StateObject private var viewModel: ProviderEditorViewModel

  init(existingProvider: AIProviderConfigModel?) {
    self.existingProvider = existingProvider
    _viewModel = StateObject(
      wrappedValue: ProviderEditorViewModel(existingProvider: existingProvider))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") {
          TextField("Service name", text: $viewModel.name)
        }

        Section("Type") {
          Picker("Service type", selection: $viewModel.type) {
            ForEach(ProviderType.allCases, id: \.self) { type in
              Text(type.displayName).tag(type)
            }
          }
        }

        if viewModel.type != .appleLocal {
          Section("Connection") {
            TextField("Base URL", text: $viewModel.baseURLString)
              .keyboardType(.URL)
              .autocapitalization(.none)
              .disableAutocorrection(true)

            SecureField("API key", text: $viewModel.apiKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)

            TextField("Default model", text: $viewModel.defaultModel)
              .autocapitalization(.none)
              .disableAutocorrection(true)
          }
        }

        Section("Capabilities") {
          Toggle("Streaming", isOn: $viewModel.supportsStreaming)
          Toggle("Audio", isOn: $viewModel.supportsAudio)
          Toggle("Tools / Function calling", isOn: $viewModel.supportsTools)
          Toggle("Embeddings", isOn: $viewModel.supportsEmbeddings)
        }

        Section {
          HStack {
            Button("Test Connection") {
              Task { await viewModel.testConnection() }
            }
            .disabled(viewModel.baseURLString.isEmpty)

            Spacer()

            connectionStatusView
          }
        }

        Section("Notes") {
          TextField("Notes", text: $viewModel.notes, axis: .vertical)
            .lineLimit(3)
        }
      }
      .navigationTitle(existingProvider == nil ? "Add AI Service" : "Edit AI Service")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            viewModel.save(context: modelContext)
            dismiss()
          }
          .bold()
          .disabled(viewModel.isSaving)
        }
      }
    }
  }

  @ViewBuilder
  private var connectionStatusView: some View {
    switch viewModel.connectionStatus {
    case .notTested:
      EmptyView()
    case .testing:
      ProgressView()
    case .success:
      AppStatusBadge(title: "Connected", systemImage: "checkmark", tone: .success)
    case .failed(let message):
      AppStatusBadge(title: message, systemImage: "xmark", tone: .error)
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
