import Foundation
import Network

// Related JIRA: KAN-9, KAN-42

// MARK: - Provider protocol

// MARK: - Model metadata

struct ModelInfo: Sendable, Codable {
    let id: String
    let created: Date?
    let contextWindow: Int?
    let isRecommended: Bool
    let recommendedFor: [String]?  // e.g. ["chat", "analysis", "transcription"]
}

/// Protocol abstracting an AI language model provider (OpenAI, Anthropic, Gemini, or compatible).
///
/// Implementations handle provider-specific API formats, authentication, streaming,
/// and model discovery. The app uses `ProviderRouter` to resolve the active provider
/// based on user configuration, offline state, and budget constraints.
///
/// ## Implementations
/// - `OpenAICompatibleProvider` — OpenAI, Ollama, LM Studio, OpenRouter, LocalAI, DeepSeek
/// - `AnthropicProvider` — Claude models via Anthropic Messages API
/// - `GeminiProvider` — Google Gemini models
///
/// ## Related Docs
/// - `docs/PROVIDER_ROUTING.md` — routing, budget, metrics, circuit breaker
/// - `docs/API_PROVIDER_CONTRACTS.md` — contracts and capabilities
protocol AIProvider: Sendable {
    /// Unique identifier for this provider instance.
    var id: String { get }
    /// Human-readable name shown in settings and model picker.
    var displayName: String { get }
    /// The provider family (openai, anthropic, gemini, openaiCompatible).
    var providerType: ProviderType { get }
    /// Capabilities this provider supports (streaming, JSON mode, tools, etc.).
    var capabilities: AIProviderCapabilities { get }

    /// Send a chat completion request and receive the full response.
    /// - Parameter request: The chat request with model, messages, and parameters.
    /// - Returns: The completed response with content and usage metadata.
    func send(_ request: AIRequest) async throws -> AIResponse

    /// Generate embeddings for the given text.
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - model: The embedding model to use.
    /// - Returns: A vector of floating-point values.
    func embed(_ text: String, model: String) async throws -> [Float]

    /// Fetch available model names from the provider API.
    /// - Returns: Array of model identifier strings.
    func fetchModels() async throws -> [String]

    /// Enriched model list with metadata. Default implementation calls `fetchModels()` and wraps.
    /// - Returns: Array of `ModelInfo` with context window, recommendations, and creation dates.
    func fetchModelInfos() async throws -> [ModelInfo]
}

extension AIProvider {
    func embed(_ text: String, model: String) async throws -> [Float] {
        throw ProviderError.embeddingNotSupported
    }
    func fetchModels() async throws -> [String] { [] }
    func fetchModelInfos() async throws -> [ModelInfo] {
        try await fetchModels().map { ModelInfo(id: $0, created: nil, contextWindow: nil, isRecommended: false, recommendedFor: nil) }
    }
}

// MARK: - Provider metrics

/// Tracks API spending and enforces daily budget limits.
/// Writes to UserDefaults so budgets survive app restarts.
final class BudgetTracker: @unchecked Sendable {
    static let shared = BudgetTracker()
    private let defaults = UserDefaults.standard
    private let dailyBudgetKey = "budget_daily_limit"
    private let dailySpendKey = "budget_daily_spend"
    private let spendDateKey = "budget_spend_date"
    private let lock = NSLock()

    private init() {}

    // MARK: - Config

    /// Daily budget in USD. nil = unlimited. Default: $1.00.
    var dailyLimit: Double? {
        get { defaults.object(forKey: dailyBudgetKey) as? Double }
        set { defaults.set(newValue, forKey: dailyBudgetKey) }
    }

    /// Total spent today (USD).
    var spentToday: Double {
        lock.withLock { _spentToday() }
    }

    private func _spentToday() -> Double {
        let today = Calendar.current.startOfDay(for: Date())
        if let storedDate = defaults.object(forKey: spendDateKey) as? Date,
            Calendar.current.isDate(storedDate, inSameDayAs: today)
        {
            return defaults.double(forKey: dailySpendKey)
        }
        // New day — reset
        defaults.set(0.0, forKey: dailySpendKey)
        defaults.set(today, forKey: spendDateKey)
        return 0.0
    }

    /// Remaining budget today. nil = unlimited.
    var remainingBudget: Double? {
        guard let limit = dailyLimit else { return nil }
        return max(0, limit - spentToday)
    }

    /// Whether we're over the daily budget.
    var isOverBudget: Bool {
        guard let remaining = remainingBudget else { return false }
        return remaining <= 0
    }

    // MARK: - Tracking

    /// Record a spend event. Typically called after each API response with usage data.
    /// Estimated at $0.002/1K tokens if no exact cost is known.
    func recordSpend(tokens: Int, costUSD: Double? = nil) {
        let cost = costUSD ?? (Double(tokens) / 1000.0 * 0.002)
        lock.withLock {
            let current = _spentToday()
            defaults.set(current + cost, forKey: dailySpendKey)
        }
        AppLog.provider.info("Budget: spent $\(String(format: "%.4f", cost)) (total today: $\(String(format: "%.4f", self.spentToday)))")

        if isOverBudget {
            AppLog.provider.warning("Budget: DAILY LIMIT EXCEEDED — consider switching to local provider")
        }
    }

    /// Best model tier given the current budget state.
    enum Tier {
        case premium  // budget remaining > 50%
        case standard  // budget remaining 25-50%
        case economy  // budget remaining < 25% or over budget
    }

    var recommendedTier: Tier {
        guard let limit = dailyLimit, limit > 0 else { return .premium }
        let ratio = spentToday / limit
        if ratio > 1.0 { return .economy }
        if ratio > 0.75 { return .economy }
        if ratio > 0.50 { return .standard }
        return .premium
    }
}

// MARK: - BudgetState

struct BudgetState: Sendable {
    let dailyLimit: Double?
    let spentToday: Double
    var remainingPercent: Double {
        guard let limit = dailyLimit, limit > 0 else { return 1.0 }
        return max(0, 1.0 - spentToday / limit)
    }
    var isOverBudget: Bool {
        guard let limit = dailyLimit, limit > 0 else { return false }
        return spentToday >= limit
    }
    var remainingBudget: Double? {
        guard let limit = dailyLimit else { return nil }
        return max(0, limit - spentToday)
    }

    static func from(_ tracker: BudgetTracker) -> BudgetState {
        BudgetState(dailyLimit: tracker.dailyLimit, spentToday: tracker.spentToday)
    }
}

// MARK: - ModelOverride

struct ModelOverride: Sendable {
    var model: String?
    var tier: String?
    var temperature: Double?
    var maxTokens: Int?
    var providerID: String?

    init(
        model: String? = nil, tier: String? = nil,
        temperature: Double? = nil, maxTokens: Int? = nil,
        providerID: String? = nil
    ) {
        self.model = model
        self.tier = tier
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.providerID = providerID
    }
}

// MARK: - ModelSelection

struct ModelSelection: Sendable {
    let model: String
    let tier: String
    let provider: ProviderType
    let reason: String
}

// MARK: - ProviderPreference

enum ProviderPreference: Sendable {
    case any
    case localPreferred
    case localRequired
    case specific(String)
}

struct ProviderMetrics: Codable, Sendable {
    var ttftMs: Double?  // Time to first token
    var totalLatencyMs: Double  // Total request latency
    var tokensPerSecond: Double?  // Throughput
    var promptTokens: Int?
    var completionTokens: Int?
    var costUSD: Double?  // OpenRouter cost tracking

    var summary: String {
        var parts: [String] = []
        if let ttft = ttftMs { parts.append("⏱ TTFT: \(String(format: "%.1f", ttft))ms") }
        parts.append("⏱ Total: \(String(format: "%.1f", totalLatencyMs))ms")
        if let tps = tokensPerSecond { parts.append("📊 \(String(format: "%.0f", tps)) tok/s") }
        if let cost = costUSD { parts.append("💰 $\(String(format: "%.4f", cost))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Request priority

enum RequestPriority: Sendable, Comparable {
    case interactive  // user-facing chat — highest priority
    case userInitiated  // user action (export, analyze) — medium
    case background  // pipeline, indexing — lowest

    var timeoutSeconds: TimeInterval {
        switch self {
        case .interactive: 60  // users won't wait >60s
        case .userInitiated: 120
        case .background: 300  // pipelines can wait
        }
    }
}

// MARK: - Metrics history store

/// Persists daily aggregated metrics per provider.
/// Stored in UserDefaults as JSON, keyed by provider ID + date.
final class MetricsHistoryStore: @unchecked Sendable {
    static let shared = MetricsHistoryStore()
    private let defaults = UserDefaults.standard
    private let prefix = "metrics_history_"

    private init() {}

    private func key(for providerID: String, date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(prefix)\(providerID)_\(fmt.string(from: day))"
    }

    /// Daily aggregate metrics for a provider.
    struct DailyAggregate: Codable {
        var requestCount: Int = 0
        var totalTokens: Int = 0
        var totalLatencyMs: Double = 0
        var minTTFTMs: Double = .infinity
        var maxTTFTMs: Double = 0
        var totalCost: Double = 0
        var errorCount: Int = 0

        var avgLatencyMs: Double { requestCount > 0 ? totalLatencyMs / Double(requestCount) : 0 }
        var avgTTFTMs: Double { requestCount > 0 && minTTFTMs != .infinity ? (minTTFTMs + maxTTFTMs) / 2 : 0 }
    }

    func record(metrics: ProviderMetrics, for providerID: String) {
        let k = key(for: providerID, date: Date())
        var agg = load(key: k)
        agg.requestCount += 1
        agg.totalTokens += (metrics.promptTokens ?? 0) + (metrics.completionTokens ?? 0)
        agg.totalLatencyMs += metrics.totalLatencyMs
        if let ttft = metrics.ttftMs {
            agg.minTTFTMs = min(agg.minTTFTMs, ttft)
            agg.maxTTFTMs = max(agg.maxTTFTMs, ttft)
        }
        if let cost = metrics.costUSD { agg.totalCost += cost }
        save(agg, key: k)
    }

    func recordError(for providerID: String) {
        let k = key(for: providerID, date: Date())
        var agg = load(key: k)
        agg.errorCount += 1
        save(agg, key: k)
    }

    func today(for providerID: String) -> DailyAggregate {
        load(key: key(for: providerID, date: Date()))
    }

    private func load(key: String) -> DailyAggregate {
        guard let data = defaults.data(forKey: key),
            let agg = try? JSONDecoder().decode(DailyAggregate.self, from: data)
        else {
            return DailyAggregate()
        }
        return agg
    }

    private func save(_ agg: DailyAggregate, key: String) {
        guard let data = try? JSONEncoder().encode(agg) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Tracks request timing and builds ProviderMetrics on completion.
final class MetricsTracker {
    private let startTime: CFAbsoluteTime
    private var firstTokenTime: CFAbsoluteTime?
    private var totalTokens: Int = 0
    private var totalCost: Double = 0

    init() { startTime = CFAbsoluteTimeGetCurrent() }

    func recordFirstToken() { if firstTokenTime == nil { firstTokenTime = CFAbsoluteTimeGetCurrent() } }
    func recordTokens(_ count: Int) { totalTokens += count }
    func recordCost(_ cost: Double) { totalCost += cost }

    func build(promptTokens: Int? = nil, completionTokens: Int? = nil) -> ProviderMetrics {
        let now = CFAbsoluteTimeGetCurrent()
        let totalMs = (now - startTime) * 1000
        let ttft: Double? = firstTokenTime.map { ($0 - startTime) * 1000 }
        let tps: Double? = ttft.map { _ in
            let generateTime = max(0.001, (now - (firstTokenTime ?? startTime)) * 1000)
            return Double(totalTokens) / (generateTime / 1000.0)
        }
        return ProviderMetrics(
            ttftMs: ttft, totalLatencyMs: totalMs, tokensPerSecond: tps,
            promptTokens: promptTokens, completionTokens: completionTokens, costUSD: totalCost > 0 ? totalCost : nil)
    }
}

// MARK: - Model cache

final class ModelCache: @unchecked Sendable {
    static let shared = ModelCache()
    private let defaults = UserDefaults.standard
    private let cacheKeyPrefix = "model_cache_"
    private let ttlKeyPrefix = "model_cache_ttl_"
    private let cacheTTL: TimeInterval = 3600  // 1 hour

    private init() {}

    func getCachedModels(for providerId: String) -> [String]? {
        guard let ttl = defaults.object(forKey: ttlKeyPrefix + providerId) as? Date,
            Date() < ttl,
            let data = defaults.data(forKey: cacheKeyPrefix + providerId),
            let models = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return models
    }

    func cacheModels(_ models: [String], for providerId: String) {
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: cacheKeyPrefix + providerId)
            defaults.set(Date().addingTimeInterval(cacheTTL), forKey: ttlKeyPrefix + providerId)
        }
    }

    func invalidate(for providerId: String) {
        defaults.removeObject(forKey: cacheKeyPrefix + providerId)
        defaults.removeObject(forKey: ttlKeyPrefix + providerId)
    }
}

// MARK: - Unified model list response (handles OpenAI, Anthropic, Ollama, Gemini formats)

struct UnifiedModelsResponse: Decodable {
    let modelIDs: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKeys.self)
        if let data = try? container.decode([DataItem].self, forKey: DynamicKeys(stringValue: "data")!) {
            self.modelIDs = data.map(\.id)
        } else if let models = try? container.decode([OllamaItem].self, forKey: DynamicKeys(stringValue: "models")!) {
            self.modelIDs = models.map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name }
        } else {
            self.modelIDs = []
        }
    }

    private struct DataItem: Decodable { let id: String }
    private struct OllamaItem: Decodable { let name: String }

    private struct DynamicKeys: CodingKey {
        var stringValue: String
        var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }
}

// MARK: - Capabilities

struct AIProviderCapabilities: Codable, Equatable, Sendable {
    var supportsStreaming: Bool
    var supportsAudioInput: Bool
    var supportsStructuredOutput: Bool
    var supportsToolCalling: Bool
    var supportsEmbeddings: Bool
}

// MARK: - Request

struct AIRequest: Sendable {
    var model: String
    var messages: [AIMessage]
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: AIResponseFormat?

    enum AIResponseFormat: Sendable {
        case jsonObject
        case jsonSchema(name: String, schema: String)
    }

    var tools: [AIToolDefinition]?
    var toolChoice: String?
    var stop: [String]?  // stop sequences (for local models that don't stop naturally)
    var thinkingBudgetTokens: Int?  // max tokens for thinking/reasoning (Claude, DeepSeek)
}

// MARK: - Message

struct AIMessage: Identifiable, Sendable {
    let id: UUID
    var role: AIRole
    var content: [AIContentBlock]
    var toolCalls: [AIToolCall]?
    var toolCallId: String?

    init(id: UUID = UUID(), role: AIRole, content: [AIContentBlock], toolCalls: [AIToolCall]? = nil, toolCallId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

enum AIContentBlock: Codable, Sendable {
    case text(String)
    case audioFile(URL)
    case imageFile(URL)
}

// MARK: - Response

struct AIResponse: Codable, Sendable {
    var id: String?
    var model: String?
    var content: String
    var reasoningContent: String?  // DeepSeek/Claude thinking tokens
    var rawResponsePath: String?
    var usage: AIUsage?
    var toolCalls: [AIToolCall]?
    var finishReason: String?
}

struct AIUsage: Codable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

// MARK: - Tool Calls

struct AIToolCall: Codable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

enum AIFinishReason: String, Codable, Sendable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
}

// MARK: - Streaming

enum AIStreamEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)  // reasoning/thinking tokens (Claude, DeepSeek)
    case toolCallDelta(id: String, name: String?, arguments: String?)
    case finished(AIFinishReason?)
}

extension AIProvider {
    func sendStreaming(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.send(request)

                    // Emit thinking/reasoning tokens first (if any)
                    if let reasoning = response.reasoningContent, !reasoning.isEmpty {
                        continuation.yield(.thinkingDelta(reasoning))
                    }

                    if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                        for tc in toolCalls {
                            continuation.yield(.toolCallDelta(id: tc.id, name: tc.name, arguments: tc.arguments))
                        }
                    }

                    if !response.content.isEmpty {
                        continuation.yield(.textDelta(response.content))
                    }

                    let finish: AIFinishReason? = response.finishReason.flatMap { AIFinishReason(rawValue: $0) }
                    continuation.yield(.finished(finish))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case requestFailed(statusCode: Int)
    case apiError(statusCode: Int, body: String)
    case decodingFailed
    case providerNotFound
    case networkUnavailable
    case unauthorized
    case timeout
    case embeddingNotSupported
    /// Rate limited — retry after the given interval.
    case rateLimited(retryAfter: TimeInterval)
    /// Context window exceeded — the request's token count is too high.
    case contextWindowExceeded(maxTokens: Int)

    var errorDescription: String? { userMessage }

    /// Whether this error is retryable (transient) or permanent.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .networkUnavailable: true
        case .requestFailed(let code): code >= 500  // server errors are transient
        case .apiError(let code, _): code >= 500 || code == 429
        default: false
        }
    }

    /// Suggested delay before retrying, if retryable.
    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let d): d
        case .timeout: 5
        case .requestFailed(let code) where code >= 500: 2
        case .apiError(let code, _) where code == 429: 30
        default: nil
        }
    }

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Your API key is missing. Paste it in Settings > AI Services."
        case .invalidBaseURL:
            "The server address doesn't look right. Check it in Settings > AI Services."
        case .requestFailed(let code):
            code == 401
                ? "Your API key was rejected. Check that it's correct in Settings > AI Services."
                : code == 404
                    ? "Couldn't reach the server at that address. Check the server address in Settings."
                    : code == 429
                        ? "You've made too many requests. Wait a moment, then try again."
                        : code >= 500
                            ? "The AI service is having trouble. This is on their end — try again in a few minutes."
                            : "Something went wrong (error \(code)). Check your connection in Settings."
        case .apiError(let code, let body):
            "Error \(code): \(extractErrorBody(body))"
        case .decodingFailed:
            "The AI service sent back a response we couldn't read. Your data is safe. Try again or check that you picked the right service type."
        case .providerNotFound:
            "No AI service connected. Go to Settings > AI Services to connect one."
        case .networkUnavailable:
            "No internet connection. Check your Wi-Fi or cellular data, then try again."
        case .unauthorized:
            "Your API key was rejected. Check that it's correct in Settings > AI Services."
        case .timeout:
            "The request took too long. The AI service may be busy. Try again in a moment."
        case .embeddingNotSupported:
            "This provider does not support embeddings. Choose a provider that supports embeddings (OpenAI, etc.) in Settings."
        case .rateLimited(let retryAfter):
            "Rate limited. Try again in \(Int(retryAfter)) seconds."
        case .contextWindowExceeded(let maxTokens):
            "This request exceeds the model's context window of \(maxTokens) tokens. Try with fewer messages or a larger model."
        }
    }
}

private func extractErrorBody(_ body: String) -> String {
    guard let data = body.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = json["error"] as? [String: Any],
        let message = error["message"] as? String
    else {
        return String(body.prefix(200))
    }
    return message
}

// MARK: - Retry policy

struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitter: Double  // 0.0–1.0

    static let standard = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 32.0, jitter: 0.3)
    static let aggressive = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 4.0, jitter: 0.2)

    func delay(for attempt: Int) -> TimeInterval {
        let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
        let j = Double.random(in: 0...(exponential * jitter))
        return exponential + j
    }
}

extension RetryPolicy {
    /// Executes an async operation with exponential backoff retry.
    /// Only retries on errors where `isRetryable` is true.
    func execute<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch let error as ProviderError {
                lastError = error
                guard error.isRetryable, attempt + 1 < maxAttempts else { throw error }
                let wait = error.retryAfter ?? delay(for: attempt)
                AppLog.provider.warning("Retry \(attempt + 1)/\(maxAttempts) after \(String(format: "%.1f", wait))s — \(error.userMessage.prefix(80))")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                throw error  // non-ProviderError — don't retry
            }
        }
        throw lastError ?? ProviderError.requestFailed(statusCode: -1)
    }
}

// MARK: - Circuit breaker

final class CircuitBreaker: @unchecked Sendable {
    enum State: Sendable { case closed, open, halfOpen }

    private let failureThreshold: Int
    private let recoveryTimeout: TimeInterval
    private let lock = NSLock()
    private nonisolated(unsafe) var _state: State = .closed
    private nonisolated(unsafe) var _failureCount: Int = 0
    private nonisolated(unsafe) var _lastFailureTime: Date?

    var state: State {
        lock.withLock {
            if case .open = _state, let last = _lastFailureTime,
                Date().timeIntervalSince(last) > recoveryTimeout
            {
                _state = .halfOpen
            }
            return _state
        }
    }

    init(failureThreshold: Int = 5, recoveryTimeout: TimeInterval = 30) {
        self.failureThreshold = failureThreshold
        self.recoveryTimeout = recoveryTimeout
    }

    func recordSuccess() {
        lock.withLock {
            _state = .closed
            _failureCount = 0
        }
    }

    func recordFailure() {
        lock.withLock {
            _failureCount += 1
            _lastFailureTime = Date()
            if _failureCount >= failureThreshold { _state = .open }
        }
    }

    func allowRequest() -> Bool {
        switch state {
        case .closed, .halfOpen: true
        case .open: false
        }
    }
}

// MARK: - Network monitor

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wawa.networkmonitor", qos: .background)
    private let lock = NSLock()
    private nonisolated(unsafe) var _isAvailable: Bool = true
    private nonisolated(unsafe) var _isExpensive: Bool = false

    var isAvailable: Bool { lock.withLock { _isAvailable } }
    var isExpensive: Bool { lock.withLock { _isExpensive } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock {
                _isAvailable = path.status == .satisfied
                _isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    /// Throws ProviderError.networkUnavailable if offline (call before requests).
    func requireConnectivity() throws {
        if !isAvailable { throw ProviderError.networkUnavailable }
    }
}

// MARK: - Local Provider Scanner

/// Result from scanning the local network for AI providers.
struct DiscoveredProvider: Identifiable, Sendable {
    let id: String
    let name: String
    let providerType: ProviderType
    let baseURL: URL
    let scanPath: String?
    let category: ProviderCategory
    let models: [String]
    let isReachable: Bool
    let latencyMs: Double?
    let bonjourName: String?

    var displayName: String {
        if let bonjour = bonjourName { return "\(name) (\(bonjour))" }
        return name
    }

    var modelCountDescription: String {
        models.isEmpty ? "No models found" : "\(models.count) model\(models.count == 1 ? "" : "s")"
    }
}

/// Scans the local network for AI providers (LM Studio, Ollama, etc.) using
/// port probes and Bonjour/mDNS discovery.
/// Thread-safe container for Bonjour scan results. Used by LocalProviderScanner
/// to satisfy Swift 6 concurrency checking when mutable state is captured in
/// concurrent browser/async closures.
private final class LockedBonjourState: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [(name: String, host: String, port: Int)] = []

    func addServiceIfMissing(name: String, host: String, port: Int) {
        lock.withLock {
            if !services.contains(where: { $0.name == name && $0.port == port }) {
                services.append((name: name, host: host, port: port))
            }
        }
    }

    func snapshotServices() -> [(name: String, host: String, port: Int)] {
        lock.withLock { services }
    }
}

final class LocalProviderScanner: @unchecked Sendable {
    static let shared = LocalProviderScanner()

    private struct LocalProviderDef: Sendable {
        let id: String
        let name: String
        let defaultPort: Int
        let modelPath: String
        let providerType: ProviderType
    }

    private static let knownProviders: [LocalProviderDef] = [
        LocalProviderDef(id: "ollama", name: "Ollama", defaultPort: 11434, modelPath: "api/tags", providerType: .openAICompatible),
        LocalProviderDef(id: "lmstudio", name: "LM Studio", defaultPort: 1234, modelPath: "v1/models", providerType: .openAICompatible),
        LocalProviderDef(id: "localai", name: "LocalAI", defaultPort: 8080, modelPath: "v1/models", providerType: .openAICompatible),
    ]

    private let scanQueue = DispatchQueue(label: "com.wawa.localproviderscanner", qos: .userInitiated)
    private let probeTimeout: TimeInterval = 3.0

    private init() {}

    /// Scans localhost for known providers. Returns results sorted by reachability then latency.
    func scan(includeNetworkScan: Bool = false) async -> [DiscoveredProvider] {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                Task {
                    var results: [DiscoveredProvider] = []
                    await withTaskGroup(of: DiscoveredProvider?.self) { group in
                        for def in Self.knownProviders {
                            group.addTask { await self.probeLocalProvider(def) }
                        }
                        for await result in group { if let r = result { results.append(r) } }
                    }
                    if includeNetworkScan {
                        let bonjourResults = await self.scanBonjour()
                        for b in bonjourResults where !results.contains(where: { $0.baseURL == b.baseURL }) {
                            results.append(b)
                        }
                    }
                    results.sort { a, b in
                        if a.isReachable != b.isReachable { return a.isReachable }
                        return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
                    }
                    continuation.resume(returning: results)
                }
            }
        }
    }

    func quickScan() async -> [DiscoveredProvider] { await scan(includeNetworkScan: false) }

    private func probeLocalProvider(_ def: LocalProviderDef) async -> DiscoveredProvider? {
        let baseURL = URL(string: "http://localhost:\(def.defaultPort)")!
        let modelsURL = baseURL.appendingPathComponent(def.modelPath)
        let start = CFAbsoluteTimeGetCurrent()
        var isReachable = false
        var models: [String] = []
        var latencyMs: Double?
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                isReachable = true
                let decoded = try? JSONDecoder().decode(UnifiedModelsResponse.self, from: data)
                models = decoded?.modelIDs.sorted() ?? []
            }
        } catch {
            AppLog.provider.debug("Local scan: \(def.name) not reachable on port \(def.defaultPort)")
        }
        guard isReachable else { return nil }
        AppLog.provider.info("Local scan: found \(def.name) with \(models.count) models (latency: \(String(format: "%.0f", latencyMs ?? 0))ms)")
        return DiscoveredProvider(
            id: def.id, name: def.name, providerType: def.providerType,
            baseURL: baseURL, scanPath: def.modelPath, category: .local,
            models: models, isReachable: true, latencyMs: latencyMs, bonjourName: nil)
    }

    private func scanBonjour() async -> [DiscoveredProvider] {
        // Use a lock-protected wrapper to satisfy Swift 6 concurrency checking
        // for local mutable state captured in concurrent browser/async closures.
        let state = LockedBonjourState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[DiscoveredProvider], Never>) in
            let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: .tcp)
            browser.stateUpdateHandler = { s in
                if case .failed(let error) = s { AppLog.provider.debug("Bonjour failed: \(error.localizedDescription)") }
            }
            browser.browseResultsChangedHandler = { resultsSet, _ in
                for result in resultsSet {
                    if case .service(let name, _, _, _) = result.endpoint {
                        let lower = name.lowercased()
                        let known = ["ollama", "lmstudio", "lm-studio", "localai", "local-ai"]
                        if known.contains(where: { lower.contains($0) }) {
                            let port: Int = lower.contains("ollama") ? 11434 : (lower.contains("lmstudio") || lower.contains("lm-studio") ? 1234 : 8080)
                            state.addServiceIfMissing(name: name, host: "\(name).local", port: port)
                        }
                    }
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                browser.cancel()
                Task {
                    let services = state.snapshotServices()
                    var results: [DiscoveredProvider] = []
                    for service in services {
                        let baseURL = URL(string: "http://\(service.host):\(service.port)")!
                        let modelPath = service.name.lowercased().contains("ollama") ? "api/tags" : "v1/models"
                        var models: [String] = []
                        var isReachable = false
                        var req = URLRequest(url: baseURL.appendingPathComponent(modelPath))
                        req.httpMethod = "GET"
                        req.timeoutInterval = 3
                        if let (data, resp) = try? await URLSession.shared.data(for: req),
                            let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
                        {
                            isReachable = true
                            let decoded = try? JSONDecoder().decode(UnifiedModelsResponse.self, from: data)
                            models = decoded?.modelIDs.sorted() ?? []
                        }
                        results.append(
                            DiscoveredProvider(
                                id: "bonjour-\(service.name)", name: service.name,
                                providerType: .openAICompatible, baseURL: baseURL, scanPath: modelPath,
                                category: .local, models: models, isReachable: isReachable,
                                latencyMs: isReachable ? nil : nil, bonjourName: service.name))
                    }
                    continuation.resume(returning: results)
                }
            }
        }
    }

    func fetchModels(from url: URL, scanPath: String?) async throws -> [String] {
        let endpoint = url.appendingPathComponent(scanPath ?? "v1/models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(UnifiedModelsResponse.self, from: data).modelIDs.sorted()
    }
}
