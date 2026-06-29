import Foundation
import OSLog

/// Tiered model fallback system for AI tasks.
///
/// Ported from anarlog's `StaticModelResolver` in `crates/llm-proxy/src/model.rs`.
///
/// Each task has a prioritized list of models. When the primary model fails
/// (rate limit, timeout, unavailable), the resolver tries the next one.
///
/// Tasks map to Wawa Note features:
/// - `.chat` → agentic chat
/// - `.enhance` → content analysis pipeline
/// - `.title` → auto-title generation
/// - `.toolCalling` → agent tool execution
/// - `.audio` → audio transcription
///
/// Usage:
/// ```swift
/// let resolver = ModelResolver.shared
/// let models = resolver.models(for: .enhance)
/// // ["claude-sonnet-4-6", "gpt-5.5", "claude-haiku-4.5", "gpt-4o"]
/// ```
@MainActor
final class ModelResolver: ObservableObject {
    static let shared = ModelResolver()

    private let logger = Logger(subsystem: "com.wawa.note", category: "ModelResolver")
    private let defaults = UserDefaults.standard

    // MARK: - Task types

    enum Task: String, CaseIterable, Codable {
        case chat
        case enhance  // meeting analysis
        case title  // auto-title generation
        case toolCalling  // agent tool execution
        case audio  // transcription
        case embedding  // semantic search embeddings
        case summary  // daily/weekly summaries
        case quick  // fast, cheap operations

        var displayName: String {
            switch self {
            case .chat: "Chat"
            case .enhance: "Content Analysis"
            case .title: "Title Generation"
            case .toolCalling: "Tool Calling"
            case .audio: "Audio Transcription"
            case .embedding: "Embeddings"
            case .summary: "Summaries"
            case .quick: "Quick Operations"
            }
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
            case .enhance: "magnifyingglass.circle"
            case .title: "textformat.alt"
            case .toolCalling: "hammer"
            case .audio: "waveform"
            case .embedding: "circle.grid.3x3"
            case .summary: "doc.text"
            case .quick: "bolt"
            }
        }
    }

    // MARK: - Model tier lists

    /// Default model tiers per task (from anarlog's StaticModelResolver + Wawa Note models).
    private let defaultTiers: [Task: [String]] = [
        .chat: [
            "claude-sonnet-4-6",
            "claude-opus-4-7",
            "gpt-5.5",
            "claude-haiku-4.5",
            "gpt-4o",
        ],
        .enhance: [
            "claude-sonnet-4-6",
            "gpt-5.5",
            "claude-opus-4-7",
            "gpt-4o",
        ],
        .title: [
            "gpt-5-nano",
            "claude-haiku-4.5",
            "gpt-4o-mini",
        ],
        .toolCalling: [
            "claude-sonnet-4-6",
            "claude-opus-4-7",
            "gpt-5.5",
            "claude-haiku-4.5",
        ],
        .audio: [
            "gpt-5.5",  // Whisper via OpenAI
            "claude-sonnet-4-6",  // Some models support audio
        ],
        .embedding: [
            "gpt-5.5",
            "gpt-4o",
        ],
        .summary: [
            "claude-haiku-4.5",
            "gpt-5-nano",
            "gpt-4o-mini",
        ],
        .quick: [
            "gpt-5-nano",
            "claude-haiku-4.5",
            "gpt-4o-mini",
        ],
    ]

    /// User-customized model tiers (overrides defaults).
    @Published private var customTiers: [Task: [String]] = [:]

    private init() {
        loadCustomTiers()
    }

    // MARK: - Model resolution

    /// Get the model tier list for a task.
    func models(for task: Task) -> [String] {
        customTiers[task] ?? defaultTiers[task] ?? []
    }

    /// Get the primary (preferred) model for a task.
    func primaryModel(for task: Task) -> String? {
        models(for: task).first
    }

    /// Get the next model after a failed one.
    func fallbackModel(after failedModel: String, for task: Task) -> String? {
        let tier = models(for: task)
        guard let failedIndex = tier.firstIndex(of: failedModel),
            failedIndex + 1 < tier.count
        else {
            return nil
        }
        return tier[failedIndex + 1]
    }

    /// Get all available models for a task.
    func allModels(for task: Task) -> [String] {
        models(for: task)
    }

    // MARK: - Customization

    /// Set custom model tiers for a task.
    func setModels(_ modelIDs: [String], for task: Task) {
        customTiers[task] = modelIDs
        saveCustomTiers()
    }

    /// Reset a task's tiers to defaults.
    func resetToDefaults(for task: Task) {
        customTiers.removeValue(forKey: task)
        saveCustomTiers()
    }

    /// Reset all tasks to defaults.
    func resetAllToDefaults() {
        customTiers.removeAll()
        saveCustomTiers()
    }

    // MARK: - Persistence

    private func loadCustomTiers() {
        guard let data = defaults.data(forKey: "model_resolver_tiers"),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            return
        }
        for (key, models) in decoded {
            if let task = Task(rawValue: key) {
                customTiers[task] = models
            }
        }
    }

    private func saveCustomTiers() {
        let dict = customTiers.mapValues { $0 }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        defaults.set(data, forKey: "model_resolver_tiers")
    }
}

// MARK: - Integration with AIConfigService

extension ModelResolver {
    /// Resolve the best available model for a task, considering what's configured.
    /// Returns the first tier model that is available in the active provider config.
    func resolveAvailableModel(
        for task: Task,
        availableModels: [String]
    ) -> String? {
        let tier = models(for: task)
        for model in tier {
            if availableModels.contains(model) {
                return model
            }
        }
        return availableModels.first  // Fallback to whatever is available
    }

    /// Check if a model is appropriate for a given task.
    func isModelAppropriate(_ modelID: String, for task: Task) -> Bool {
        models(for: task).contains(modelID)
    }
}
