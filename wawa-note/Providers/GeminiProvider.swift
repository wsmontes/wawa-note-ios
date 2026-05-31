import Foundation
import OSLog

// MARK: - Gemini Generate Content API

private struct GeminiRequest: Encodable {
    let systemInstruction: SystemInstruction?
    let contents: [Content]
    let generationConfig: GenerationConfig?

    struct SystemInstruction: Encodable {
        let parts: [Part]
    }

    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let temperature: Double?
        let maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxOutputTokens = "maxOutputTokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case systemInstruction
        case contents
        case generationConfig
    }
}

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]
    let usageMetadata: UsageMetadata?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?

        struct Content: Decodable {
            let parts: [Part]
            let role: String?

            struct Part: Decodable {
                let text: String?
            }
        }

        enum CodingKeys: String, CodingKey {
            case content
            case finishReason = "finishReason"
        }
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }
}

// MARK: - Gemini Embedding API

private struct GeminiEmbeddingRequest: Encodable {
    let model: String
    let content: Content

    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }
}

private struct GeminiEmbeddingResponse: Decodable {
    let embedding: Embedding

    struct Embedding: Decodable {
        let values: [Double]
    }
}

// MARK: - Provider

final class GeminiProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let providerType: ProviderType = .gemini
    let capabilities: AIProviderCapabilities

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static var configuredSession: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    init(
        id: String, displayName: String, baseURL: URL, apiKey: String, model: String,
        session: URLSession = GeminiProvider.configuredSession
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.capabilities = AIProviderCapabilities(
            supportsStreaming: true,
            supportsAudioInput: false,
            supportsStructuredOutput: true,
            supportsToolCalling: true,
            supportsEmbeddings: true
        )
        self.session = session
    }

    func send(_ request: AIRequest) async throws -> AIResponse {
        let effectiveModel = request.model.isEmpty ? model : request.model
        let url = baseURL.appendingPathComponent("models/\(effectiveModel):generateContent")

        // Extract system instruction as top-level field
        let systemText = request.messages
            .filter { $0.role == .system }
            .compactMap { msg in msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n") }
            .joined(separator: "\n\n")
            .nilIfEmpty

        let systemInstruction = systemText.map {
            GeminiRequest.SystemInstruction(parts: [GeminiRequest.Part(text: $0)])
        }

        // Non-system messages (Gemini uses "user" and "model" roles)
        let conversationMessages = request.messages.filter { $0.role != .system }
        let contents: [GeminiRequest.Content] = conversationMessages.map { msg in
            let textContent = msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")

            // Gemini uses "model" instead of "assistant"
            let role: String
            switch msg.role {
            case .assistant: role = "model"
            case .user: role = "user"
            case .system: role = "user"
            case .tool: role = "user"
            }

            return GeminiRequest.Content(role: role, parts: [GeminiRequest.Part(text: textContent)])
        }

        let genConfig = GeminiRequest.GenerationConfig(
            temperature: request.temperature,
            maxOutputTokens: request.maxTokens
        )

        let body = GeminiRequest(
            systemInstruction: systemInstruction,
            contents: contents,
            generationConfig: genConfig
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        AppLog.provider.info("POST \(url.absoluteString)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.requestFailed(statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
            AppLog.provider.error("Gemini returned \(httpResponse.statusCode): \(bodyStr.prefix(500))")
            throw ProviderError.apiError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        let decoded: GeminiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            AppLog.provider.error("Failed to decode Gemini response: \(error)")
            throw ProviderError.decodingFailed
        }

        let text = decoded.candidates.first?.content?.parts
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""

        let usage: AIUsage? = {
            guard let u = decoded.usageMetadata else { return nil }
            return AIUsage(
                promptTokens: u.promptTokenCount,
                completionTokens: u.candidatesTokenCount,
                totalTokens: u.totalTokenCount
            )
        }()

        AppLog.provider.info("Gemini response: \(text.prefix(100))...")
        return AIResponse(id: nil, model: effectiveModel, content: text, usage: usage)
    }

    // MARK: - Embeddings

    func embed(_ text: String, model: String) async throws -> [Float] {
        guard capabilities.supportsEmbeddings else {
            throw ProviderError.embeddingNotSupported
        }

        let embeddingModel = model.isEmpty ? "text-embedding-004" : model
        let url = baseURL.appendingPathComponent("models/\(embeddingModel):embedContent")

        let body = GeminiEmbeddingRequest(
            model: "models/\(embeddingModel)",
            content: GeminiEmbeddingRequest.Content(
                parts: [GeminiEmbeddingRequest.Part(text: text)]
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let decoded = try? JSONDecoder().decode(GeminiEmbeddingResponse.self, from: data) else {
            throw ProviderError.decodingFailed
        }
        return decoded.embedding.values.map { Float($0) }
    }

    func fetchModels() async throws -> [String] {
        let endpoint = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoded = try JSONDecoder().decode(UnifiedModelsResponse.self, from: data)
        return decoded.modelIDs.sorted()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
