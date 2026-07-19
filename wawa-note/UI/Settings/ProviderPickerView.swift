import SwiftData
import SwiftUI

// Related JIRA: KAN-543

struct ProviderPickerView: View {
  @Query(sort: \AIProviderConfigModel.name) private var providers: [AIProviderConfigModel]
  @Environment(\.modelContext) private var modelContext

  @State private var selectedTemplate: ProviderTemplate?
  @State private var selectedProvider: AIProviderConfigModel?
  @State private var showCustomEditor = false
  @State private var isScanningNetwork = false
  @State private var detectedLocalEndpoints: Set<String> = []

  @State private var activeModelKey: String = ""
  private let activeManager = ActiveProviderManager.shared

  var body: some View {
    List {
      // Active model selector
      Section {
        if providers.isEmpty {
          HStack {
            Image(systemName: "brain.head.profile")
              .font(.title3)
              .foregroundStyle(.secondary)
            Text("No AI service connected")
              .foregroundStyle(.secondary)
          }
        } else {
          Picker("Provider", selection: $activeModelKey) {
            ForEach(allModelKeys, id: \.self) { key in
              if let provider = providers.first(where: { $0.id.uuidString == key }) {
                Text(displayLabel(for: provider)).tag(key)
              }
            }
          }
          .pickerStyle(.menu)
          if let active = activeProvider {
            Picker(
              "Model",
              selection: Binding(
                get: { active.defaultModel },
                set: { newModel in
                  active.defaultModel = newModel
                  modelContext.safeSave(context: "update-active-model")
                  syncActiveSelection()
                }
              )
            ) {
              ForEach(availableModelsForActive, id: \.self) { model in
                Text(model).tag(model)
              }
            }
            .pickerStyle(.menu)
          }
        }
      } header: {
        Text("Active AI Service")
      } footer: {
        Text(
          "Used for summaries, analysis, and cross-reference. Connect a provider to enable AI features."
        )
      }

      cloudServicesSection
      localServicesSection
      advancedSection
    }
    .navigationTitle("AI Services")
    .navigationDestination(item: $selectedProvider) { provider in
      ProviderDetailView(provider: provider)
    }
    .sheet(item: $selectedTemplate) { template in
      ProviderConnectView(template: template)
    }
    .sheet(isPresented: $showCustomEditor) {
      ProviderEditorView(existingProvider: nil)
    }
    .onAppear { syncActiveSelection() }
    .onChange(of: activeModelKey) { _, newKey in
      updateActiveFromKey(newKey)
    }
  }

  // MARK: - Model key management

  private var allModelKeys: [String] {
    // Use provider UUID as the picker identity — concatenated display strings
    // collide when two providers share the same type + default model.
    providers.map { $0.id.uuidString }
  }

  private func displayLabel(for provider: AIProviderConfigModel) -> String {
    "\(provider.type.displayName) · \(provider.defaultModel)"
  }

  private var activeProvider: AIProviderConfigModel? {
    guard let activeId = activeManager.getActiveProviderID(),
      let uuid = UUID(uuidString: activeId)
    else { return nil }
    return providers.first(where: { $0.id == uuid })
  }

  private var availableModelsForActive: [String] {
    guard let active = activeProvider else { return [] }
    var models = Set(AIConfigService.shared.availableModels(for: active.providerConfigId))
    if models.isEmpty {
      models = Set(AIConfigService.shared.availableModels(for: active.typeRaw))
    }
    active.availableModels.forEach { models.insert($0) }
    models.insert(active.defaultModel)
    return Array(models).sorted()
  }

  private func syncActiveSelection() {
    if let activeId = activeManager.getActiveProviderID(),
      let uuid = UUID(uuidString: activeId),
      let active = providers.first(where: { $0.id == uuid })
    {
      activeModelKey = active.id.uuidString
    } else if let first = providers.first {
      activeManager.setActiveProviderID(first.id.uuidString)
      activeModelKey = first.id.uuidString
    }
  }

  private func updateActiveFromKey(_ key: String) {
    guard
      let provider = providers.first(where: { $0.id.uuidString == key }
      )
    else { return }
    activeManager.setActiveProviderID(provider.id.uuidString)
  }

  // MARK: - Sections

  private var cloudServicesSection: some View {
    Section {
      ForEach(ProviderTemplate.cloudTemplates) { template in
        ProviderCard(
          template: template,
          isConnected: isConnected(to: template),
          action: { selectTemplate(template) }
        )
      }
    } header: {
      Text("Cloud AI Services")
    } footer: {
      Text("Cloud providers process your data on their servers.")
    }
  }

  private var localServicesSection: some View {
    Section {
      ForEach(ProviderTemplate.localTemplates) { template in
        ProviderCard(
          template: template,
          isConnected: isConnected(to: template),
          action: { selectTemplate(template) }
        )
        .overlay(alignment: .trailing) {
          if isDetected(template) && !isConnected(to: template) {
            detectedBadge.padding(.trailing, 32)
          }
        }
      }
      scanNetworkButton
    } header: {
      Text("On Your Computer")
    } footer: {
      Text("Models run locally on your Mac. No API key or internet required.")
    }
  }

  private var scanNetworkButton: some View {
    Button {
      Task { await scanNetwork() }
    } label: {
      HStack {
        if isScanningNetwork { ProgressView().controlSize(.small) }
        Label("Scan Network", systemImage: "antenna.radiowaves.left.and.right")
      }
    }
    .disabled(isScanningNetwork)
  }

  private var detectedBadge: some View {
    AppStatusBadge(title: "Detected", systemImage: "wifi", tone: .success)
  }

  private var advancedSection: some View {
    Section {
      DisclosureGroup("Advanced") {
        Button {
          showCustomEditor = true
        } label: {
          Label("Custom Provider", systemImage: "gearshape.2")
        }
      }
    } footer: {
      Text("For power users who need a custom endpoint.")
    }
  }

  // MARK: - Actions

  private func selectTemplate(_ template: ProviderTemplate) {
    if let existing = findExistingConfig(for: template) {
      selectedProvider = existing
    } else {
      selectedTemplate = template
    }
  }

  private func findExistingConfig(for template: ProviderTemplate) -> AIProviderConfigModel? {
    providers.first {
      $0.providerConfigId == template.id
        || ($0.type == template.providerType && $0.baseURLString == template.baseURL)
    }
  }

  private func isConnected(to template: ProviderTemplate) -> Bool {
    providers.contains {
      $0.providerConfigId == template.id
        || ($0.type == template.providerType && $0.baseURLString == template.baseURL)
    }
  }

  private func isDetected(_ template: ProviderTemplate) -> Bool {
    detectedLocalEndpoints.contains(template.id)
  }

  // MARK: - Network scan

  private func scanNetwork() async {
    isScanningNetwork = true
    defer { isScanningNetwork = false }
    detectedLocalEndpoints.removeAll()
    let discovered = await LocalProviderScanner.shared.scan(includeNetworkScan: true)
    for provider in discovered where provider.isReachable {
      for template in ProviderTemplate.localTemplates
      where provider.id == template.id
        || provider.name.lowercased().contains(template.displayName.lowercased())
      {
        detectedLocalEndpoints.insert(template.id)
      }
    }
  }
}

#Preview {
  NavigationStack { ProviderPickerView() }
}
