import SwiftData
import SwiftUI

// MARK: - View model

@MainActor
final class ProviderConnectViewModel: ObservableObject {
  let template: ProviderTemplate

  @Published var apiKey = ""
  @Published var modelName = ""
  @Published var connectionPhase: ConnectionPhase = .idle
  @Published var availableModels: [String] = []
  @Published var selectedModel: String = ""
  @Published var isFetchingModels = false
  @Published var modelFetchError: String?

  private let keychain = SecureKeyStore()
  private let router = ProviderRouter()
  private var savedProvider: AIProviderConfigModel?
  private let fetchKeychainId = UUID().uuidString

  var effectiveModel: String {
    if !selectedModel.isEmpty { return selectedModel }
    let m = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    return m.isEmpty ? template.defaultModel : m
  }

  enum ConnectionPhase: Equatable {
    case idle
    case scanningLocal
    case localFound(endpoint: String)
    case localNotFound
    case testing
    case success
    case failed(String)
  }

  init(template: ProviderTemplate) {
    self.template = template
    self.selectedModel = template.defaultModel
    self.modelName = template.defaultModel
  }

  // MARK: - Auto-scan (local only)

  func scanForLocalProvider() {
    guard template.category == .local else { return }

    connectionPhase = .scanningLocal

    Task {
      // Use LocalProviderScanner for multi-port localhost probing
      let discovered = await LocalProviderScanner.shared.quickScan()
      if let match = discovered.first(where: {
        $0.id == template.id || $0.name.lowercased() == template.id
      }) {
        await MainActor.run {
          connectionPhase = .localFound(endpoint: match.baseURL.absoluteString)
          if !match.models.isEmpty {
            let staticModels = AIConfigService.shared.availableModels(for: template.id)
            var merged = Set(staticModels)
            match.models.forEach { merged.insert($0) }
            availableModels = Array(merged).sorted()
            if let firstModel = availableModels.first {
              selectedModel = firstModel
            }
          }
        }
      } else {
        // Fallback: probe single endpoint as before
        let found = await probeLocalEndpoint()
        await MainActor.run {
          if found {
            connectionPhase = .localFound(endpoint: template.baseURL)
          } else {
            connectionPhase = .localNotFound
          }
        }
      }
    }
  }

  private func probeLocalEndpoint() async -> Bool {
    guard template.scanPort != nil, let path = template.scanPath else {
      return false
    }
    guard let url = URL(string: template.baseURL)?.appendingPathComponent(path) else {
      return false
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 4

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  // MARK: - Fetch models

  func fetchModels() async {
    guard let baseURL = URL(string: template.baseURL) else {
      modelFetchError = "Invalid server address."
      return
    }
    isFetchingModels = true
    modelFetchError = nil

    do {
      let models: [String]

      // Check cache first (1h TTL)
      if let cached = ModelCache.shared.getCachedModels(for: template.id) {
        models = cached
      } else if apiKey.isEmpty && template.requiresAuth {
        models = AIConfigService.shared.availableModels(for: template.id)
      } else {
        if template.requiresAuth && !apiKey.isEmpty {
          try? keychain.saveAPIKey(apiKey, for: fetchKeychainId)
        }
        let testConfig = AIProviderConfigModel(
          name: template.displayName, type: template.providerType, providerConfigId: template.id,
          baseURL: baseURL,
          defaultModel: effectiveModel, supportsStreaming: true, supportsAudio: false,
          supportsTools: true,
          supportsEmbeddings: template.providerType == .openAI || template.providerType == .gemini,
          apiKeyKeychainIdentifier: template.requiresAuth ? fetchKeychainId : nil
        )
        let provider = try router.provider(for: testConfig)
        models = try await provider.fetchModels()
        // Cache the fetched models
        ModelCache.shared.cacheModels(models, for: template.id)
        // Clean up temp keychain entry if pre-connect
        if savedProvider == nil && template.requiresAuth {
          try? keychain.deleteAPIKey(for: fetchKeychainId)
        }
      }

      let staticModels = AIConfigService.shared.availableModels(for: template.id)
      var merged = Set(staticModels)
      models.forEach { merged.insert($0) }
      // Sort by quality: recommended first, then config order (reflects capability),
      // then reverse-alpha so newer/faster models surface before legacy ones.
      let recommended = AIConfigService.shared.config.defaultModels
      let recSet = Set(
        [recommended?.analysis, recommended?.chat, recommended?.transcription].compactMap { $0 })
      let configOrder: [String: Int] = Dictionary(
        uniqueKeysWithValues: staticModels.enumerated().map { ($1, $0) })
      availableModels = Array(merged).sorted { a, b in
        let aRec = recSet.contains(a)
        let bRec = recSet.contains(b)
        if aRec != bRec { return aRec }
        let aIdx = configOrder[a] ?? Int.max
        let bIdx = configOrder[b] ?? Int.max
        if aIdx != bIdx { return aIdx < bIdx }
        return a > b  // reverse-alpha: gpt-5.5 before babbage
      }
      if availableModels.isEmpty {
        modelFetchError = "No models available."
      } else if selectedModel.isEmpty || !availableModels.contains(selectedModel) {
        selectedModel = template.defaultModel
      }
    } catch {
      let staticModels = AIConfigService.shared.availableModels(for: template.id)
      if !staticModels.isEmpty {
        availableModels = staticModels  // already in capability order from ai_config.json
        selectedModel = template.defaultModel
      } else {
        modelFetchError = "Could not fetch models."
      }
    }
    isFetchingModels = false
  }

  // MARK: - Connect

  func connect(context: ModelContext) async {
    connectionPhase = .testing

    // Generate a keychain identifier for the API key.
    let keychainId = UUID().uuidString

    // Save API key if this is a cloud provider.
    if template.requiresAuth && !apiKey.isEmpty {
      do {
        try keychain.saveAPIKey(apiKey, for: keychainId)
      } catch {
        connectionPhase = .failed("Could not save API key to the secure store.")
        return
      }
    }

    // Build a temporary config for testing.
    guard let baseURL = URL(string: template.baseURL) else {
      connectionPhase = .failed("Invalid server address in template.")
      return
    }

    let testConfig = AIProviderConfigModel(
      name: template.displayName,
      type: template.providerType,
      providerConfigId: template.id,
      baseURL: baseURL,
      defaultModel: effectiveModel,
      supportsStreaming: true,
      supportsAudio: false,
      supportsTools: true,
      supportsEmbeddings: template.providerType == .openAI || template.providerType == .gemini,
      apiKeyKeychainIdentifier: template.requiresAuth ? keychainId : nil,
      notes: nil
    )

    do {
      let provider = try router.provider(for: testConfig)
      let request = AIRequest(
        model: effectiveModel,
        messages: [
          AIMessage(role: .user, content: [.text("Say hi")])
        ],
        maxTokens: nil
      )
      let response = try await provider.send(request)

      if response.content.isEmpty {
        connectionPhase = .failed(
          "Connected but received an empty response. The model may not be available.")
        // Clean up keychain entry on failure.
        if template.requiresAuth {
          try? keychain.deleteAPIKey(for: keychainId)
        }
        return
      }

      // Connection successful. Remove old configs for the same provider before saving.
      let existingDescriptor = FetchDescriptor<AIProviderConfigModel>()
      if let existing = try? context.fetch(existingDescriptor) {
        for old in existing
        where old.type == template.providerType && old.baseURLString == template.baseURL {
          if let oldKeyId = old.apiKeyKeychainIdentifier {
            try? keychain.deleteAPIKey(for: oldKeyId)
          }
          context.delete(old)
        }
      }

      // Persist the new provider.
      let savedProvider = AIProviderConfigModel(
        name: template.displayName,
        type: template.providerType,
        providerConfigId: template.id,
        baseURL: baseURL,
        defaultModel: effectiveModel,
        supportsStreaming: true,
        supportsAudio: false,
        supportsTools: true,
        supportsEmbeddings: template.providerType == .openAI || template.providerType == .gemini,
        apiKeyKeychainIdentifier: template.requiresAuth ? keychainId : nil,
        notes: nil
      )
      context.insert(savedProvider)
      do {
        try context.save()
      } catch {
        if template.requiresAuth { try? keychain.deleteAPIKey(for: keychainId) }
        connectionPhase = .failed("Could not save configuration. Please try again.")
        return
      }
      self.savedProvider = savedProvider
      ActiveProviderManager.shared.setActiveProviderID(savedProvider.id.uuidString)

      // Attempt model discovery.
      let models = await discoverModels(baseURL: baseURL, apiKeyId: keychainId)
      availableModels = models
      if let firstModel = models.first {
        selectedModel = firstModel
        savedProvider.defaultModel = firstModel
      }
      savedProvider.availableModels = models
      try? context.save()

      // Auto-populate AI settings with this provider's models.
      // The user just connected a provider — its models should immediately
      // be available across all AI fields (analysis, chat, etc.) instead
      // of showing empty selections or stale defaults.
      let bestModel = savedProvider.defaultModel.isEmpty ? models.first : savedProvider.defaultModel
      if let model = bestModel, !model.isEmpty {
        AutomationSettings.shared.autoAnalysisModel = model
        AutomationSettings.shared.autoAnalysisProvider = savedProvider.typeRaw
      }

      connectionPhase = .success

    } catch let error as ProviderError {
      // Clean up keychain entry on failure.
      if template.requiresAuth {
        try? keychain.deleteAPIKey(for: keychainId)
      }
      connectionPhase = .failed(error.userMessage)
    } catch {
      if template.requiresAuth {
        try? keychain.deleteAPIKey(for: keychainId)
      }
      connectionPhase = .failed("Could not connect. Check your network and try again.")
    }
  }

  // MARK: - Model discovery

  private func discoverModels(baseURL: URL, apiKeyId: String?) async -> [String] {
    guard let savedProvider else { return [] }
    do {
      let provider = try router.provider(for: savedProvider)
      return try await provider.fetchModels()
    } catch {
      return AIConfigService.shared.availableModels(for: template.id)
    }
  }

  func updateModel(context: ModelContext) {
    guard let provider = savedProvider else { return }
    provider.defaultModel = selectedModel
    try? context.save()
  }
}

// MARK: - Connect view

struct ProviderConnectView: View {
  let template: ProviderTemplate

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @StateObject private var viewModel: ProviderConnectViewModel
  @State private var showAdvanced = false

  init(template: ProviderTemplate) {
    self.template = template
    _viewModel = StateObject(wrappedValue: ProviderConnectViewModel(template: template))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          headerView

          switch template.category {
          case .cloud:
            cloudConnectionUI
          case .local:
            localConnectionUI
          }

          connectionResultView

          Spacer(minLength: 16)

          advancedLink
        }
        .padding(AppSpacing.xl)
      }
      .navigationTitle("Connect")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        if case .success = viewModel.connectionPhase {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
              .bold()
          }
        }
      }
      .sheet(isPresented: $showAdvanced) {
        ProviderEditorView(existingProvider: nil)
      }
    }
  }

  // MARK: - Header

  private var headerView: some View {
    VStack(spacing: AppSpacing.md) {
      ZStack {
        RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
          .fill(headerIconBackground)
          .frame(width: 72, height: 72)

        Image(systemName: template.systemImageName)
          .font(.largeTitle)
          .foregroundStyle(headerIconForeground)
      }

      VStack(spacing: 4) {
        Text(template.displayName)
          .font(.title2)
          .fontWeight(.bold)

        Text(headerSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.top, 8)
  }

  private var headerSubtitle: String {
    switch template.category {
    case .cloud:
      return "Enter your API key to connect."
    case .local:
      return "Connect to a model running on your computer."
    }
  }

  private var headerIconBackground: Color {
    switch template.category {
    case .cloud: return Color.accentColor.opacity(0.12)
    case .local: return AppColor.privacy.opacity(0.12)
    }
  }

  private var headerIconForeground: Color {
    switch template.category {
    case .cloud: return Color.accentColor
    case .local: return AppColor.privacy
    }
  }

  // MARK: - Cloud connection UI

  @ViewBuilder
  private var cloudConnectionUI: some View {
    if case .success = viewModel.connectionPhase {
      // On success, show model picker (if models were discovered).
      modelPickerView
    } else {
      VStack(spacing: AppSpacing.lg) {
        apiKeyField
        modelField
        modelPickerSection
        apiKeyLink
        connectButton
      }
    }
  }

  private var apiKeyField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("API Key")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)

      SecureField("Paste your API key here", text: $viewModel.apiKey)
        .textFieldStyle(.roundedBorder)
        .font(.body)
        .autocapitalization(.none)
        .disableAutocorrection(true)
        .disabled(viewModel.connectionPhase == .testing)
    }
  }

  @ViewBuilder
  private var modelPickerSection: some View {
    if let error = viewModel.modelFetchError {
      Text(error).font(.caption).foregroundStyle(.red)
    }
    if !viewModel.availableModels.isEmpty {
      Picker("Model", selection: $viewModel.selectedModel) {
        ForEach(viewModel.availableModels, id: \.self) { m in
          Text(m).tag(m)
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var modelField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Model")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("Model name", text: $viewModel.modelName)
          .textFieldStyle(.roundedBorder)
          .font(.body)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .disabled(viewModel.connectionPhase == .testing)

        Button {
          Task { await viewModel.fetchModels() }
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.body)
        }
        .disabled(viewModel.apiKey.isEmpty || viewModel.isFetchingModels)
      }
    }
  }

  private var apiKeyLink: some View {
    HStack(spacing: 4) {
      Image(systemName: "arrow.up.forward.square")
        .font(.caption)
      if let url = template.getAPIKeyURL {
        Link("Get an API key at \(url.host() ?? "provider website")", destination: url)
          .font(.caption)
      }
    }
    .foregroundStyle(.secondary)
  }

  private var connectButton: some View {
    PrimaryActionButton(
      title: "Connect",
      systemImage: "link",
      isLoading: viewModel.connectionPhase == .testing
    ) {
      Task { await viewModel.connect(context: modelContext) }
    }
    .disabled(viewModel.apiKey.isEmpty || viewModel.connectionPhase == .testing)
    .padding(.top, 4)
  }

  // MARK: - Local connection UI

  @ViewBuilder
  private var localConnectionUI: some View {
    switch viewModel.connectionPhase {
    case .idle, .scanningLocal:
      scanningView
    case .localFound(let endpoint):
      localFoundView(endpoint: endpoint)
    case .localNotFound:
      localNotFoundView
    case .testing:
      localTestingView
    case .success:
      modelPickerView
    case .failed:
      localFailedView
    }
  }

  private var scanningView: some View {
    VStack(spacing: AppSpacing.lg) {
      HStack(spacing: AppSpacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text("Looking for \(template.displayName) on your network...")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear {
      viewModel.scanForLocalProvider()
    }
  }

  private func localFoundView(endpoint: String) -> some View {
    VStack(spacing: AppSpacing.lg) {
      AppStatusBadge(
        title: "Found \(template.displayName)",
        systemImage: "checkmark.circle.fill",
        tone: .success
      )

      Text("\(template.displayName) is running on your computer.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      PrimaryActionButton(
        title: "Connect",
        systemImage: "link"
      ) {
        Task { await viewModel.connect(context: modelContext) }
      }
    }
  }

  private var localNotFoundView: some View {
    VStack(spacing: AppSpacing.lg) {
      AppStatusBadge(
        title: "Not found",
        systemImage: "wifi.slash",
        tone: .warning
      )

      VStack(spacing: 8) {
        Text("Could not find \(template.displayName).")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Text(
          "Make sure \(template.displayName) is running and both devices are on the same Wi-Fi network."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }

      PrimaryActionButton(
        title: "Scan Again",
        systemImage: "arrow.clockwise"
      ) {
        viewModel.scanForLocalProvider()
      }

      Divider()
        .padding(.vertical, 4)

      Text("Or configure manually:")
        .font(.caption)
        .foregroundStyle(.secondary)

      Button {
        showAdvanced = true
      } label: {
        Label("Manual Setup", systemImage: "gearshape.2")
      }
      .buttonStyle(.bordered)
    }
  }

  private var localTestingView: some View {
    VStack(spacing: AppSpacing.sm) {
      ProgressView()
      Text("Testing connection...")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var localFailedView: some View {
    VStack(spacing: AppSpacing.lg) {
      PrimaryActionButton(
        title: "Try Again",
        systemImage: "arrow.clockwise"
      ) {
        Task { await viewModel.connect(context: modelContext) }
      }
    }
  }

  // MARK: - Connection result

  @ViewBuilder
  private var connectionResultView: some View {
    switch viewModel.connectionPhase {
    case .success:
      successView
    case .failed(let message):
      failureView(message: message)
    case .idle, .scanningLocal, .localFound, .localNotFound, .testing:
      EmptyView()
    }
  }

  private var successView: some View {
    VStack(spacing: 12) {
      AppStatusBadge(
        title: "Connected to \(template.displayName)",
        systemImage: "checkmark.circle.fill",
        tone: .success
      )

      if !viewModel.availableModels.isEmpty {
        Text("Using \(viewModel.selectedModel).")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Using \(viewModel.effectiveModel).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, AppSpacing.sm)
  }

  private func failureView(message: String) -> some View {
    VStack(spacing: 12) {
      AppStatusBadge(
        title: "Connection failed",
        systemImage: "xmark.circle.fill",
        tone: .error
      )

      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if template.category == .cloud {
        PrimaryActionButton(
          title: "Try Again",
          systemImage: "arrow.clockwise"
        ) {
          Task { await viewModel.connect(context: modelContext) }
        }
      }
    }
    .padding(.vertical, AppSpacing.sm)
  }

  // MARK: - Model picker

  @ViewBuilder
  private var modelPickerView: some View {
    if !viewModel.availableModels.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Model")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        Picker("Model", selection: $viewModel.selectedModel) {
          ForEach(viewModel.availableModels, id: \.self) { model in
            Text(model).tag(model)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: viewModel.selectedModel) { _, _ in
          viewModel.updateModel(context: modelContext)
        }
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
          .fill(Color(.systemGray6))
      )
    }
  }

  // MARK: - Advanced link

  private var advancedLink: some View {
    Button {
      showAdvanced = true
    } label: {
      Text("Advanced settings")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Preview

#Preview("Cloud - idle") {
  if let t = ProviderTemplate.openAI {
    ProviderConnectView(template: t)
  }
}

#Preview("Local - idle") {
  if let t = ProviderTemplate.lmStudio {
    ProviderConnectView(template: t)
  }
}
