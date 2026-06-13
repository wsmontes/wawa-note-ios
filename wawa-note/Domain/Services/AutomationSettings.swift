import Foundation
import SwiftData

// MARK: - Shared UserDefaults Keys
// Centralized key constants to prevent divergence between ConfigProjectService,
// AutomationSettings, TranscriptionSettings, AudioSessionManager, and Settings UI.

enum UserDefaultsKey {
    // Transcription
    static let transcriptionMode = "transcription_mode"
    static let transcriptionAllowCloud = "transcription_allow_cloud"

    // Automation
    static let autoTranscribe = "automation_auto_transcribe"
    static let autoAnalyze = "automation_auto_analyze"
    static let autoAnalysisModel = "automation_auto_analysis_model"
    static let autoAnalysisProvider = "automation_auto_analysis_provider"

    // Audio
    static let audioRawMode = "audio_raw_mode"
    static let audioSpeakerphoneMode = "audio_speakerphone_mode"
    static let audioPreferBuiltinMic = "audio_prefer_builtin_mic"

    // Active provider
    static let activeProviderID = "active_provider_id"
    static let providerRouting = "provider_routing"

    // Developer
    static let developerModeEnabled = "developer_mode_enabled"

    // Anarlog
    static let anarlogAutoImport = "anarlog_auto_import"
    static let anarlogAutoExport = "anarlog_auto_export"

    // Feature flags
    static let hasShownWelcome = "has_shown_welcome"
    static let onboardedV1 = "_onboarded_v1"
    static let onboardedV2 = "_onboarded_v2"

    // Model
    static let modelResolverTiers = "model_resolver_tiers"
    static let modelPref = "model_pref_"
}

struct AutomationSettings: @unchecked Sendable {
    nonisolated(unsafe) static var shared = AutomationSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let autoTranscribe = UserDefaultsKey.autoTranscribe
        static let autoAnalyze = UserDefaultsKey.autoAnalyze
        static let autoAnalysisModel = UserDefaultsKey.autoAnalysisModel
        static let autoAnalysisProvider = UserDefaultsKey.autoAnalysisProvider
    }

    var autoTranscribe: Bool {
        get { defaults.object(forKey: Key.autoTranscribe) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoTranscribe) }
    }

    var autoAnalyze: Bool {
        get { defaults.object(forKey: Key.autoAnalyze) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoAnalyze) }
    }

    /// Model used for automatic analysis. Returns the stored model name,
    /// or empty string if none has been selected yet (the UI will pick the
    /// first available model from the active provider on first launch).
    var autoAnalysisModel: String {
        get { defaults.string(forKey: Key.autoAnalysisModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.autoAnalysisModel) }
    }

    /// Provider type string for auto-analysis model resolution.
    var autoAnalysisProvider: String {
        get { defaults.string(forKey: Key.autoAnalysisProvider) ?? "" }
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
