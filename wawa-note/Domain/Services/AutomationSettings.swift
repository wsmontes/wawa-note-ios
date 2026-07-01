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
  /// FIXME: This is set (ProviderConnectView, ConfigProjectService) but never
  /// consumed by resolveAutoAnalysisModel() — which always uses the active
  /// provider. Either wire it into model resolution or remove it.
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

  /// Revalidate automation settings against current providers.
  /// Call when providers change (add/remove/active provider change).
  /// Resets autoAnalysisModel/Provider if they reference a missing provider or unavailable model.
  func revalidateAutomationConfig(context: ModelContext) {
    let configs = ActiveProviderManager.shared.allProviders(context: context)
    let defaults = UserDefaults.standard

    // Validate autoAnalysisProvider exists
    let provider = defaults.string(forKey: Key.autoAnalysisProvider) ?? ""
    if !provider.isEmpty {
      let exists = configs.contains { $0.typeRaw == provider || $0.providerConfigId == provider }
      if !exists {
        AppLog.config.warning(
          "AutomationSettings: autoAnalysisProvider '\(provider)' not found — resetting")
        defaults.set("", forKey: Key.autoAnalysisProvider)
      }
    }

    // Validate autoAnalysisModel exists in at least one provider
    let model = defaults.string(forKey: Key.autoAnalysisModel) ?? ""
    if !model.isEmpty {
      var found = false
      for config in configs {
        let models = config.availableModels
        if models.isEmpty {
          // If availableModels not fetched, check AIConfigService
          let aiModels = AIConfigService.shared.availableModels(for: config.providerConfigId)
          if aiModels.contains(model) {
            found = true
            break
          }
        } else if models.contains(model) {
          found = true
          break
        }
      }
      if !found {
        AppLog.config.warning(
          "AutomationSettings: autoAnalysisModel '\(model)' not available in any provider — resetting"
        )
        defaults.set("", forKey: Key.autoAnalysisModel)
      }
    }
  }
}
