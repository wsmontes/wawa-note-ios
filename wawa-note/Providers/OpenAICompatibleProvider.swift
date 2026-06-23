import Foundation
import OSLog
// Related JIRA: KAN-9, KAN-42


// MARK: - Chat Completions API

private struct ChatCompletionResponse: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        struct Message: Decodable {
            let role: String?
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCall]?

            /// DeepSeek V4 thinking mode: content is often empty string,
            /// real output is in reasoning_content. Prefer non-empty content.
            var effectiveContent: String {
                if let c = content, !c.isEmpty { return c }
                return reasoningContent ?? ""
            }

            struct ToolCall: Decodable {
                let id: String?
                let type: String?
                let function: FunctionCall?

                struct FunctionCall: Decodable {
                    let name: String?
                    let arguments: String?
                }
            }

            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

// MARK: - Embeddings API

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: String
}

// MARK: - Provider

final class OpenAICompatibleProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let providerType: ProviderType
    let capabilities: AIProviderCapabilities

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpointPath: String

    init(
        id: String, displayName: String, providerType: ProviderType, baseURL: URL, apiKey: String, model: String,
        capabilities: AIProviderCapabilities = AIProviderCapabilities(
            supportsStreaming: true, supportsAudioInput: false,
            supportsStructuredOutput: true, supportsToolCalling: false,
            supportsEmbeddings: false
        ),
        endpointPath: String = "chat/completions",
        session: URLSession = {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 180
            config.timeoutIntervalForResource = 300
            return URLSession(configuration: config)
        }()
    ) {
        self.id = id
        self.displayName = displayName
        self.providerType = providerType
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.endpointPath = endpointPath
        self.session = session
    }

    // MARK: - Chat Completions

    func send(_ request: AIRequest) async throws -> AIResponse {
        let url = baseURL.appendingPathComponent(endpointPath)
        let effectiveModel = request.model.isEmpty ? model : request.model

        let bodyMessages: [[String: Any]] = request.messages.map { msg in
            let textContent = msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")
            let imageBlocks = msg.content.compactMap { block -> URL? in
                if case .imageFile(let url) = block { return url }
                return nil
            }

            if imageBlocks.isEmpty {
                var m: [String: Any] = ["role": msg.role.apiName, "content": textContent]

                // Tool calls in assistant messages
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    m["tool_calls"] = tcs.map { tc -> [String: Any] in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments
                            ]
                        ]
                    }
                }

                // Tool call ID in tool messages
                if let tci = msg.toolCallId {
                    m["tool_call_id"] = tci
                }

                return m
            }
            var parts: [[String: Any]] = []
            if !textContent.isEmpty {
                parts.append(["type": "text", "text": textContent])
            }
            for imgURL in imageBlocks {
                let urlString = Self.base64DataURL(from: imgURL) ?? imgURL.absoluteString
                parts.append(["type": "image_url", "image_url": ["url": urlString]])
            }
            return ["role": msg.role.apiName, "content": parts]
        }

        let preset = AIConfigService.shared.presetFor(model: effectiveModel)

        var body: [String: Any] = [
            "model": effectiveModel,
            "messages": bodyMessages
        ]

        // Temperature: only send if the model supports it
        if let t = request.temperature {
            if preset?.supportsTemperature ?? true {
                body["temperature"] = t
            }
            // else: reasoning models don't support temperature, omit silently
        }

        // Max tokens: use the correct parameter name per model
        if let mt = request.maxTokens {
            if preset?.usesMaxCompletionTokens == true {
                body["max_completion_tokens"] = mt
            } else {
                body["max_tokens"] = mt
            }
        }

        // Response format: only send if the model supports it
        if let fmt = request.responseFormat {
            if AIConfigService.shared.supportsJSONFormat(for: effectiveModel) {
                switch fmt {
                case .jsonObject:
                    body["response_format"] = ["type": "json_object"]
                case .jsonSchema(let name, let schemaJSON):
                    if let schemaData = schemaJSON.data(using: .utf8),
                       let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
                        body["response_format"] = [
                            "type": "json_schema",
                            "json_schema": [
                                "name": name,
                                "strict": true,
                                "schema": schemaObj
                            ]
                        ]
                    } else {
                        body["response_format"] = ["type": "json_object"]
                    }
                }
            }
            // else: reasoning models don't support response_format, omit silently
        }

        // Stop sequences (for local models that don't stop naturally)
        if let stop = request.stop, !stop.isEmpty {
            body["stop"] = stop
        }

        // Thinking budget tokens (Claude, DeepSeek)
        if let thinkingBudget = request.thinkingBudgetTokens {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
        } else if preset?.explicitlyDisableThinking == true {
            body["thinking"] = ["type": "disabled"]
        }

        // Tools (function calling)
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                var parameters: [String: Any] = [
                    "type": tool.parameters.type,
                    "properties": tool.parameters.properties.mapValues { prop -> [String: Any] in
                        var p: [String: Any] = ["type": prop.type, "description": prop.description]
                        if let en = prop.enum { p["enum"] = en }
                        return p
                    }
                ]
                if !tool.parameters.required.isEmpty {
                    parameters["required"] = tool.parameters.required
                }
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters
                    ]
                ]
            }
            if let tc = request.toolChoice { body["tool_choice"] = tc }
        }

        // OpenRouter-specific fields: provider routing + fallback configuration
        let isOR = baseURL.absoluteString.contains("openrouter.ai")
        if isOR {
            // Provider routing: prefer Anthropic for quality, OpenAI for speed
            body["provider"] = ["order": ["Anthropic", "OpenAI", "Google"], "allow_fallbacks": true]
            // Include model in transforms for pricing-aware routing
            body["transforms"] = ["pricing"]  // request pricing info in response
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyOpenRouterHeaders(&urlRequest)

        AppLog.provider.info("POST \(url.absoluteString)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.requestFailed(statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
            // Log the failing request for debugging
            if let reqBody = urlRequest.httpBody, let reqStr = String(data: reqBody, encoding: .utf8) {
                AppLog.provider.error("Provider returned \(httpResponse.statusCode): \(bodyStr.prefix(300))")
                AppLog.provider.error("Failing request body (last 1000 chars): \(String(reqStr.suffix(1000)))")
            }
            throw ProviderError.apiError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            AppLog.provider.error("Failed to decode chat completion: \(error)")
            throw ProviderError.decodingFailed
        }

        let usage: AIUsage? = {
            if let u = decoded.usage {
                return AIUsage(promptTokens: u.promptTokens, completionTokens: u.completionTokens, totalTokens: u.totalTokens)
            }
            return nil
        }()

        let msg = decoded.choices.first?.message
        let text = msg?.effectiveContent ?? ""
        // Preserve reasoning_content for DeepSeek/thinking models
        let reasoningContent: String? = {
            if let rc = msg?.reasoningContent, !rc.isEmpty, rc != text { return rc }
            return nil
        }()
        let finishReason = decoded.choices.first?.finishReason

        let toolCalls: [AIToolCall]? = msg?.toolCalls?.compactMap { tc -> AIToolCall? in
            guard let id = tc.id, let fn = tc.function, let name = fn.name else { return nil }
            return AIToolCall(id: id, name: name, arguments: fn.arguments ?? "{}")
        }

        AppLog.provider.info("Response: \(text.prefix(100))...")
        return AIResponse(id: decoded.id, model: decoded.model, content: text,
            reasoningContent: reasoningContent, usage: usage, toolCalls: toolCalls, finishReason: finishReason)
    }

    // MARK: - Embeddings

    func embed(_ text: String, model: String) async throws -> [Float] {
        guard capabilities.supportsEmbeddings else {
            throw ProviderError.embeddingNotSupported
        }

        // Detect Ollama — uses /api/embed with a different format
        let isOllama = baseURL.absoluteString.contains("11434") || providerType == .localNetwork
        if isOllama {
            return try await ollamaEmbed(text: text, model: model)
        }

        let endpoint = baseURL.appendingPathComponent("embeddings")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = EmbeddingRequest(model: model, input: text)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let embedding = dataArr.first?["embedding"] as? [Double] else {
            throw ProviderError.decodingFailed
        }
        return embedding.map { Float($0) }
    }

    // MARK: - Ollama-specific embeddings

    private func ollamaEmbed(text: String, model: String) async throws -> [Float] {
        let endpoint = baseURL.appendingPathComponent("api/embed")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ollamaBody: [String: Any] = ["model": model, "input": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: ollamaBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Decode the embedding response, which differs by provider:
        // • OpenAI-compatible: {"data": [{"embedding": [...]}]}
        // • Ollama:            {"embeddings": [[...]]}  (array of vectors, one per input)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decodingFailed
        }

        // OpenAI-compatible shape (most providers)
        if let data = json["data"] as? [[String: Any]],
           let first = data.first,
           let embedding = first["embedding"] as? [Double] {
            return embedding.map { Float($0) }
        }

        // Ollama shape: {"embeddings": [[0.1, ...]]}
        if let embeddings = json["embeddings"] as? [[Double]],
           let embedding = embeddings.first {
            return embedding.map { Float($0) }
        }

        // Legacy Ollama shape (single vector)
        if let embedding = json["embedding"] as? [Double] {
            return embedding.map { Float($0) }
        }

        throw ProviderError.decodingFailed
    }

    // MARK: - Model warm-up (local providers)

    /// Sends a lightweight request to preload the model into memory.
    /// Local models (Ollama, LM Studio) take 2-10s to load on first inference.
    /// Call this when connecting to a local provider to eliminate first-request latency.
    func warmUp() async {
        guard providerType.isLocal else { return }
        AppLog.provider.info("Warming up local model \(self.model)...")
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let request = AIRequest(model: model, messages: [
                AIMessage(role: .user, content: [.text("Hi")])
            ], maxTokens: 1)
            _ = try await send(request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            AppLog.provider.info("Warm-up complete in \(String(format: "%.0f", elapsed))ms")
        } catch {
            AppLog.provider.warning("Warm-up failed: \(error.localizedDescription) — model may load on first real request")
        }
    }

    // MARK: - Ollama model info

    /// Queries Ollama's `/api/show` to get model details (quantization, context window, etc.)
    struct OllamaModelDetail: Sendable {
        let quantization: String?       // e.g. "Q4_K_M"
        let contextWindow: Int?         // e.g. 8192
        let parameterSize: String?      // e.g. "8B"
        let family: String?            // e.g. "llama"
        var description: String {
            var parts: [String] = []
            if let fam = family { parts.append(fam) }
            if let size = parameterSize { parts.append(size) }
            if let quant = quantization { parts.append(quant) }
            if let ctx = contextWindow { parts.append("\(ctx) ctx") }
            return parts.joined(separator: ", ")
        }
    }

    func fetchOllamaModelDetail(model: String) async throws -> OllamaModelDetail {
        let endpoint = baseURL.appendingPathComponent("api/show")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decodingFailed
        }

        let details = json["details"] as? [String: Any]
        let modelInfo = json["model_info"] as? [String: Any]

        // Extract quantization from details.family or model_info
        let quant: String? = {
            if let fam = details?["family"] as? String, fam.contains("Q") { return fam }
            if let fam = modelInfo?["general.quantization_version"] as? String { return fam }
            // Parse from parameter key like "Q4_K_M" in model_info keys
            if let keys = modelInfo?.keys {
                for key in keys {
                    if key.contains("Q") && (key.contains("_K") || key.contains("_0")) {
                        return key.components(separatedBy: ".").last
                    }
                }
            }
            return nil
        }()

        // Context window from model_info
        let contextWindow: Int? = {
            if let ctx = modelInfo?["llama.context_length"] as? Int { return ctx }
            if let ctx = modelInfo?["general.context_length"] as? Int { return ctx }
            return (details?["parameter_size"] as? String)?.contains("70B") == true ? 32768 : nil
        }()

        let parameterSize = details?["parameter_size"] as? String
        let family = details?["family"] as? String

        AppLog.provider.info("Ollama model \(model): \(OllamaModelDetail(quantization: quant, contextWindow: contextWindow, parameterSize: parameterSize, family: family).description)")
        return OllamaModelDetail(quantization: quant, contextWindow: contextWindow, parameterSize: parameterSize, family: family)
    }

    // MARK: - Model discovery

    func fetchModels() async throws -> [String] {
        // Ollama uses /api/tags, everyone else uses /models
        let path = providerType == .localNetwork && baseURL.absoluteString.contains("11434")
            ? "api/tags" : "models"
        let endpoint = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoded = try JSONDecoder().decode(UnifiedModelsResponse.self, from: data)
        return decoded.modelIDs.sorted()
    }

    // MARK: - OpenRouter helpers

    /// Configures OpenRouter-specific headers (HTTP-Referer, X-Title).
    /// Call before making requests to OpenRouter.
    func applyOpenRouterHeaders(_ request: inout URLRequest) {
        guard baseURL.absoluteString.contains("openrouter.ai") else { return }
        request.setValue("wawa-note://", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Wawa Note", forHTTPHeaderField: "X-Title")
    }

    /// Extracts OpenRouter cost from response JSON.
    /// OpenRouter returns `usage.cost` (USD) in every response chunk.
    static func extractOpenRouterCost(from dict: [String: Any]) -> Double? {
        if let usage = dict["usage"] as? [String: Any], let cost = usage["cost"] as? Double {
            return cost
        }
        return nil
    }

    // MARK: - Image helpers

    /// Converts a local file:// URL to a base64 data URL the remote API can read.
    /// Returns nil if the file cannot be read or is not a local file.
    static func base64DataURL(from url: URL) -> String? {
        guard url.isFileURL else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let mime: String = {
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "heic", "heif": return "image/heic"
            default: return "image/jpeg"
            }
        }()
        let base64 = data.base64EncodedString()
        return "data:\(mime);base64,\(base64)"
    }
}

// MARK: - OpenRouter model cache

/// Caches OpenRouter's /models response (300+ models with pricing).
/// TTL: 1 hour. Stores pricing, context window, and quality metrics.
struct OpenRouterModelEntry: Codable, Sendable {
    let id: String
    let name: String
    let pricing: OpenRouterPricing?
    let contextLength: Int?
    let architecture: String?  // e.g. "llama", "claude", "gpt"

    struct OpenRouterPricing: Codable, Sendable {
        let prompt: String?     // USD per 1M tokens
        let completion: String?
    }
}

final class OpenRouterModelCache: @unchecked Sendable {
    static let shared = OpenRouterModelCache()
    private let defaults = UserDefaults.standard
    private let cacheKey = "openrouter_models_cache"
    private let ttlKey = "openrouter_models_ttl"
    private let ttl: TimeInterval = 3600

    private init() {}

    var models: [OpenRouterModelEntry] {
        guard let ttlDate = defaults.object(forKey: ttlKey) as? Date, Date() < ttlDate,
              let data = defaults.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([OpenRouterModelEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func cacheModels(_ entries: [OpenRouterModelEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: cacheKey)
        defaults.set(Date().addingTimeInterval(ttl), forKey: ttlKey)
        AppLog.provider.info("OpenRouter: cached \(entries.count) models with pricing")
    }

    /// Rank models by cost/quality ratio (cheapest with best context window wins).
    func bestValue(limit: Int = 10) -> [OpenRouterModelEntry] {
        models.sorted { a, b in
            let aCost = parseCost(a.pricing?.completion) ?? 999
            let bCost = parseCost(b.pricing?.completion) ?? 999
            let aCtx = a.contextLength ?? 0
            let bCtx = b.contextLength ?? 0
            if aCost != bCost { return aCost < bCost }
            return aCtx > bCtx
        }
    }

    /// Best quality models (highest context window, regardless of cost).
    func bestQuality(limit: Int = 10) -> [OpenRouterModelEntry] {
        models.sorted { ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
    }

    private func parseCost(_ costStr: String?) -> Double? {
        // OpenRouter pricing: "0.0000015" (USD per token, not per 1M)
        guard let s = costStr, let cost = Double(s) else { return nil }
        return cost * 1_000_000  // Convert to per-1M-tokens for display
    }
}
