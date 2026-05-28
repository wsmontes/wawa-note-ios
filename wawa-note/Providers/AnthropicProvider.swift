import Foundation
import OSLog

// MARK: - Messages API

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]
    let temperature: Double?
    let stopSequences: [String]?

    struct Message: Encodable {
        let role: String
        let content: Content

        enum Content: Encodable {
            case string(String)
            case blocks([ContentBlock])

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let s): try container.encode(s)
                case .blocks(let b): try container.encode(b)
                }
            }
        }

        struct ContentBlock: Encodable {
            let type: String
            let text: String?
        }

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages, temperature
        case stopSequences = "stop_sequences"
    }
}

private struct AnthropicResponse: Decodable {
    let id: String
    let model: String
    let content: [ContentBlock]
    let stopReason: String?
    let stopSequence: String?
    let usage: Usage

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, model, content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }
}

// MARK: - Provider

final class AnthropicProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let providerType: ProviderType = .anthropic
    let capabilities: AIProviderCapabilities

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(
        id: String, displayName: String, baseURL: URL, apiKey: String, model: String,
        session: URLSession = .shared
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
            supportsEmbeddings: false
        )
        self.session = session
    }

    func send(_ request: AIRequest) async throws -> AIResponse {
        let url = baseURL.appendingPathComponent("messages")

        // Extract system prompt from messages (Anthropic uses top-level system field)
        let systemPrompt = request.messages
            .filter { $0.role == .system }
            .compactMap { msg in msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n") }
            .joined(separator: "\n\n")
            .nilIfEmpty

        // Non-system messages (must start with user, alternate user/assistant)
        let conversationMessages = request.messages.filter { $0.role != .system }

        let messages: [AnthropicRequest.Message] = conversationMessages.isEmpty
            ? [AnthropicRequest.Message(role: "user", content: .string("Hello"))]
            : conversationMessages.map { msg in
                let roleString = msg.role == .assistant ? "assistant" : "user"
                let textContent = msg.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: "\n")
                return AnthropicRequest.Message(role: roleString, content: .string(textContent))
            }

        let effectiveModel = request.model.isEmpty ? model : request.model
        let maxTokens = request.maxTokens ?? 4096

        let body = AnthropicRequest(
            model: effectiveModel,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: messages,
            temperature: request.temperature,
            stopSequences: nil
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        AppLog.provider.info("POST \(url.absoluteString)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.requestFailed(statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
            AppLog.provider.error("Anthropic returned \(httpResponse.statusCode): \(bodyStr.prefix(500))")
            throw ProviderError.apiError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            AppLog.provider.error("Failed to decode Anthropic response: \(error)")
            throw ProviderError.decodingFailed
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")

        let usage = AIUsage(
            promptTokens: decoded.usage.inputTokens,
            completionTokens: decoded.usage.outputTokens,
            totalTokens: (decoded.usage.inputTokens ?? 0) + (decoded.usage.outputTokens ?? 0)
        )

        AppLog.provider.info("Anthropic response: \(text.prefix(100))...")
        return AIResponse(id: decoded.id, model: decoded.model, content: text, usage: usage)
    }

    func fetchModels() async throws -> [String] {
        let endpoint = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
