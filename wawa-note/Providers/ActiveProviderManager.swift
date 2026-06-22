import Foundation
import SwiftData
// Related JIRA: KAN-9, KAN-42


extension Notification.Name {
    /// Posted when the active AI provider changes (connected, switched, or removed).
    static let activeProviderChanged = Notification.Name("ActiveProviderChanged")
}

// MARK: - Task-based routing

enum ProviderTaskType: String, Codable, CaseIterable {
    case chat
    case analysis
    case transcription
    case summarization
    case embeddings
}

final class ActiveProviderManager: @unchecked Sendable {
    static let shared = ActiveProviderManager()
    private let defaults = UserDefaults.standard
    private let key = UserDefaultsKey.activeProviderID
    private let routingKey = UserDefaultsKey.providerRouting

    // MARK: - Active provider

    func getActiveProviderID() -> String? {
        defaults.string(forKey: key)
    }

    func setActiveProviderID(_ id: String) {
        defaults.set(id, forKey: key)
        NotificationCenter.default.post(name: .activeProviderChanged, object: nil)
    }

    func getActiveProvider(context: ModelContext) -> AIProviderConfigModel? {
        guard let activeId = getActiveProviderID(),
              let uuid = UUID(uuidString: activeId) else {
            let descriptor = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(descriptor).first
        }
        let descriptor = FetchDescriptor<AIProviderConfigModel>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first ?? {
            let fallback = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(fallback).first
        }()
    }

    // MARK: - Task routing (multi-provider)

    /// Routing rules: maps task types → provider IDs.
    /// If a task type is not mapped, the active provider is used.
    struct RoutingRules: Codable {
        var rules: [String: String] = [:]  // taskType.rawValue → providerUUID
    }

    func getRoutingRules() -> RoutingRules {
        guard let data = defaults.data(forKey: routingKey),
              let rules = try? JSONDecoder().decode(RoutingRules.self, from: data) else {
            return RoutingRules()
        }
        return rules
    }

    func setRoutingRule(task: ProviderTaskType, providerID: String) {
        var rules = getRoutingRules()
        rules.rules[task.rawValue] = providerID
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: routingKey)
        }
    }

    func removeRoutingRule(task: ProviderTaskType) {
        var rules = getRoutingRules()
        rules.rules.removeValue(forKey: task.rawValue)
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: routingKey)
        }
    }

    func getProviderFor(task: ProviderTaskType, context: ModelContext) -> AIProviderConfigModel? {
        let rules = getRoutingRules()
        if let providerID = rules.rules[task.rawValue],
           let uuid = UUID(uuidString: providerID) {
            let descriptor = FetchDescriptor<AIProviderConfigModel>(predicate: #Predicate { $0.id == uuid })
            if let match = try? context.fetch(descriptor).first {
                return match
            }
        }
        // Fallback to active provider
        return getActiveProvider(context: context)
    }

    // MARK: - All configured providers

    func allProviders(context: ModelContext) -> [AIProviderConfigModel] {
        let descriptor = FetchDescriptor<AIProviderConfigModel>()
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Auto-select provider by model name

    func bestProviderFor(model: String, context: ModelContext) -> AIProviderConfigModel? {
        let providers = allProviders(context: context)
        let config = AIConfigService.shared

        // Check each provider's config for the model
        for provider in providers {
            let availableModels = AIConfigService.shared.availableModels(for: provider.providerConfigId)
            if availableModels.contains(model) {
                return provider
            }
            // Also check if the model name prefix matches a provider pattern
            let lower = model.lowercased()
            if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
                if provider.type == .openAI || (provider.type == .openAICompatible && provider.baseURLString?.contains("api.openai.com") == true) {
                    return provider
                }
            }
            if lower.hasPrefix("claude-") {
                if provider.type == .anthropic { return provider }
            }
            if lower.hasPrefix("gemini-") {
                if provider.type == .gemini { return provider }
            }
            if lower.hasPrefix("deepseek-") {
                if provider.baseURLString?.contains("deepseek.com") == true { return provider }
            }
        }
        return getActiveProvider(context: context)
    }
}

// MARK: - Provider health monitor

/// Monitors provider health every 30s via lightweight pings.
/// Tracks latency, error rate, and triggers failover when needed.
@MainActor
final class ProviderHealthMonitor: @unchecked Sendable {
    static let shared = ProviderHealthMonitor()

    enum Status: Sendable { case healthy, degraded, unhealthy, unknown }

    private var timer: Timer?
    private var health: [String: (status: Status, avgLatencyMs: Double, lastCheck: Date)] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    func start(context: ModelContext) {
        stop()
        let container = context.container
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                let ctx = ModelContext(container)
                await self?.checkAllProviders(context: ctx)
            }
        }
        // Run initial check immediately
        Task { await checkAllProviders(context: ModelContext(container)) }
        AppLog.provider.info("Health monitor started (30s interval)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Health checks

    private func checkAllProviders(context: ModelContext) async {
        let configs = ActiveProviderManager.shared.allProviders(context: context)
        for config in configs {
            await checkProvider(config, context: context)
        }
    }

    private func checkProvider(_ config: AIProviderConfigModel, context: ModelContext) async {
        let id = config.id.uuidString
        let start = CFAbsoluteTimeGetCurrent()

        do {
            let provider = try ProviderRouter().provider(for: config)
            let models = try await provider.fetchModels()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            lock.withLock {
                let status: Status = elapsed < 3000 ? .healthy : elapsed < 10000 ? .degraded : .unhealthy
                health[id] = (status: status, avgLatencyMs: elapsed, lastCheck: Date())
            }
            AppLog.provider.debug("Health: \(config.name) → \(models.count) models, \(String(format: "%.0f", elapsed))ms")
        } catch {
            lock.withLock {
                health[id] = (status: .unhealthy, avgLatencyMs: 9999, lastCheck: Date())
            }
            AppLog.provider.warning("Health: \(config.name) → UNHEALTHY: \(error.localizedDescription.prefix(80))")

            // Trigger failover if this was the active provider
            if config.id.uuidString == ActiveProviderManager.shared.getActiveProviderID() {
                await triggerFailover(context: context, failedProviderID: id)
            }
        }
    }

    func status(for providerID: String) -> Status {
        lock.withLock { health[providerID]?.status ?? .unknown }
    }

    func avgLatency(for providerID: String) -> Double? {
        lock.withLock { health[providerID]?.avgLatencyMs }
    }

    // MARK: - Failover

    private func triggerFailover(context: ModelContext, failedProviderID: String) async {
        let configs = ActiveProviderManager.shared.allProviders(context: context)
        let healthyConfigs = configs.filter { config in
            config.id.uuidString != failedProviderID && status(for: config.id.uuidString) == .healthy
        }

        guard let fallback = healthyConfigs.first else {
            AppLog.provider.error("Failover: no healthy provider available")
            return
        }

        ActiveProviderManager.shared.setActiveProviderID(fallback.id.uuidString)
        AppLog.provider.warning("Failover: switched from \(failedProviderID.prefix(8)) to \(fallback.name) — previous provider unhealthy")
    }
}

// MARK: - Provider pool

/// Manages a pool of providers with priority-based routing and load balancing.
/// Primary → cloud (high quality), Secondary → cloud (cheaper), Local → offline/fallback.
final class ProviderPool: @unchecked Sendable {
    struct Config {
        var primary: (provider: any AIProvider, config: AIProviderConfigModel)?
        var secondary: (provider: any AIProvider, config: AIProviderConfigModel)?
        var local: (provider: any AIProvider, config: AIProviderConfigModel)?
    }

    private var pool = Config()

    func register(_ provider: any AIProvider, config: AIProviderConfigModel, role: ProviderTaskType) {
        switch role {
        case .analysis, .chat: pool.primary = (provider, config)
        case .summarization: pool.secondary = (provider, config)
        case .transcription, .embeddings: pool.local = (provider, config)
        }
    }

    /// Resolves the best provider for a task, considering health status.
    func resolve(for task: ProviderTaskType) async throws -> (any AIProvider, AIProviderConfigModel) {
        let healthy = await MainActor.run {
            let monitor = ProviderHealthMonitor.shared
            let primaryHealthy = pool.primary.map { monitor.status(for: $0.config.id.uuidString) != .unhealthy } ?? false
            let secondaryHealthy = pool.secondary.map { monitor.status(for: $0.config.id.uuidString) != .unhealthy } ?? false
            return (primaryHealthy, secondaryHealthy)
        }

        // Try primary first (for analysis/chat)
        if task == .analysis || task == .chat {
            if let p = pool.primary, healthy.0 {
                return p
            }
        }

        // Try secondary (summarization, or primary's fallback)
        if let s = pool.secondary, healthy.1 {
            return s
        }

        // Try local (always available if configured)
        if let l = pool.local {
            return l
        }

        // Last resort: primary even if unhealthy
        if let p = pool.primary { return p }

        throw ProviderError.providerNotFound
    }
}
