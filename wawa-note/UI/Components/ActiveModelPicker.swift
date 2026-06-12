import SwiftUI
import SwiftData

/// A compact menu-style picker that shows all available models for the active provider.
/// Merges static models from ai_config.json with dynamically fetched ones.
struct ActiveModelPicker: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var selectedModel: String
    var label: String = "Model"

    @State private var availableModels: [String] = []
    @State private var isLoading = false
    @State private var providerName: String = ""

    var body: some View {
        HStack(spacing: 6) {
            if !providerName.isEmpty {
                Text(providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                if isLoading {
                    ProgressView()
                }
                ForEach(availableModels, id: \.self) { model in
                    Button {
                        selectedModel = model
                    } label: {
                        HStack {
                            Text(model)
                            if isDeprecated(model) {
                                Text("Deprecated")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            if model == selectedModel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption)
                    Text(selectedModel)
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task {
            await loadModels()
        }
    }

    private func loadModels() async {
        isLoading = true
        defer { isLoading = false }

        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            availableModels = [selectedModel]
            return
        }

        providerName = config.name

        // Start with static models from config (use providerConfigId, fallback to typeRaw)
        var allModels = Set(AIConfigService.shared.availableModels(for: config.providerConfigId))
        if allModels.isEmpty {
            allModels = Set(AIConfigService.shared.availableModels(for: config.typeRaw))
        }
        // Merge persisted available models from provider connection
        config.availableModels.forEach { allModels.insert($0) }

        // Always include the currently selected and default models
        allModels.insert(selectedModel)
        allModels.insert(config.defaultModel)

        // Try dynamic fetch
        if let fetched = try? await provider.fetchModels() {
            fetched.forEach { allModels.insert($0) }
        }

        availableModels = Array(allModels).sorted()
        if availableModels.isEmpty {
            availableModels = [selectedModel]
        }
    }

    private func isDeprecated(_ model: String) -> Bool {
        AIConfigService.shared.presetFor(model: model)?.deprecated != nil
    }
}

// MARK: - Convenience helper

extension ActiveModelPicker {
    /// Resolve the effective model for an operation, with a feature-level fallback.
    static func effectiveModel(context: ModelContext, feature: String) -> String {
        if let config = ActiveProviderManager.shared.getActiveProvider(context: context),
           !config.defaultModel.isEmpty {
            return config.defaultModel
        }
        return AIConfigService.shared.modelFor(feature: feature)
    }
}
