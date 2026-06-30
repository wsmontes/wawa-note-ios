import SwiftData
import SwiftUI

// Related JIRA: KAN-10, KAN-52

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
                            Text(key).tag(key)
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
                                    try? modelContext.save()
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
                Text("Used for summaries, analysis, and cross-reference. Connect a provider to enable AI features.")
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
        providers.map { "\($0.type.displayName) · \($0.defaultModel)" }
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
            activeModelKey = "\(active.type.displayName) · \(active.defaultModel)"
        } else if let first = providers.first {
            activeManager.setActiveProviderID(first.id.uuidString)
            activeModelKey = "\(first.type.displayName) · \(first.defaultModel)"
        }
    }

    private func updateActiveFromKey(_ key: String) {
        guard let provider = providers.first(where: { "\($0.type.displayName) · \($0.defaultModel)" == key }) else { return }
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
        providers.first { $0.type == template.providerType && $0.baseURLString == template.baseURL }
    }

    private func isConnected(to template: ProviderTemplate) -> Bool {
        providers.contains { $0.type == template.providerType && $0.baseURLString == template.baseURL }
    }

    private func isDetected(_ template: ProviderTemplate) -> Bool {
        detectedLocalEndpoints.contains(template.id)
    }

    // MARK: - Network scan

    private func scanNetwork() async {
        isScanningNetwork = true
        defer { isScanningNetwork = false }
        detectedLocalEndpoints.removeAll()
        await withTaskGroup(of: (String, Bool).self) { group in
            for template in ProviderTemplate.localTemplates {
                guard template.scanPort != nil, let path = template.scanPath else { continue }
                let baseURL = template.baseURL
                group.addTask {
                    let found = await probeEndpoint(baseURL: baseURL, path: path)
                    return (template.id, found)
                }
            }
            for await (id, found) in group where found {
                detectedLocalEndpoints.insert(id)
            }
        }
    }

    private func probeEndpoint(baseURL: String, path: String) async -> Bool {
        guard let url = URL(string: baseURL)?.appendingPathComponent(path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}

#Preview {
    NavigationStack { ProviderPickerView() }
}
