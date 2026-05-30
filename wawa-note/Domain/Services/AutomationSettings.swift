import Foundation
import SwiftData

struct AutomationSettings: @unchecked Sendable {
    nonisolated(unsafe) static var shared = AutomationSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let autoTranscribe = "automation_auto_transcribe"
        static let autoAnalyze = "automation_auto_analyze"
        static let autoAnalysisModel = "automation_auto_analysis_model"
        static let autoAnalysisProvider = "automation_auto_analysis_provider"
    }

    var autoTranscribe: Bool {
        get { defaults.object(forKey: Key.autoTranscribe) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoTranscribe) }
    }

    var autoAnalyze: Bool {
        get { defaults.object(forKey: Key.autoAnalyze) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoAnalyze) }
    }

    /// Model used for automatic analysis — cheap, fast. Default: GPT-5 nano.
    var autoAnalysisModel: String {
        get { defaults.string(forKey: Key.autoAnalysisModel) ?? "gpt-5-nano" }
        set { defaults.set(newValue, forKey: Key.autoAnalysisModel) }
    }

    /// Provider type string for auto-analysis model resolution
    var autoAnalysisProvider: String {
        get { defaults.string(forKey: Key.autoAnalysisProvider) ?? "openAI" }
        set { defaults.set(newValue, forKey: Key.autoAnalysisProvider) }
    }

    /// Resolve the auto-analysis model for the active provider.
    /// Returns the auto-analysis model if the active provider supports it,
    /// falls back to providerʼs default model, then to the first available model.
    /// Returns nil only if no provider is configured.
    func resolveAutoAnalysisModel(context: ModelContext) -> String? {
        let config = ActiveProviderManager.shared.getActiveProvider(context: context)
        guard let config else { return nil }
        let available = AIConfigService.shared.availableModels(for: config.typeRaw)
        guard !available.isEmpty else { return nil }
        // Use auto-analysis model only if the active provider actually supports it
        if available.contains(autoAnalysisModel) { return autoAnalysisModel }
        // Fall back to providerʼs configured default model
        let def = config.defaultModel
        if !def.isEmpty, available.contains(def) { return def }
        // Last resort: first available model
        return available.first
    }
}
