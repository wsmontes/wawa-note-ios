import Foundation
import OSLog

// MARK: - Request body codable types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?
    let usesMaxTokens: Bool // true = use "max_tokens", false = use "max_completion_tokens"

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokensAlt = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        if let tokens = maxTokens {
            if usesMaxTokens {
                try container.encode(tokens, forKey: .maxTokensAlt)
            } else {
                try container.encode(tokens, forKey: .maxCompletionTokens)
            }
        }
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
    }

    struct RequestMessage: Encodable {
        let role: String; let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }

    struct Usage: Decodable {
        let promptTokens: Int?; let completionTokens: Int?; let totalTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

// MARK: - Provider

final class OpenAICompatibleProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let capabilities: AIProviderCapabilities

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(
        id: String, displayName: String, baseURL: URL, apiKey: String, model: String,
        capabilities: AIProviderCapabilities = AIProviderCapabilities(
            supportsStreaming: true, supportsAudioInput: false,
            supportsStructuredOutput: true, supportsToolCalling: false,
            supportsEmbeddings: false
        ),
        session: URLSession = .shared
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.session = session
    }

    func send(_ request: AIRequest) async throws -> AIResponse {
        guard let url = URL(string: baseURL.absoluteString + "/chat/completions") else {
            throw ProviderError.invalidBaseURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = buildRequestBody(from: request)
        let bodyData = try JSONEncoder().encode(body)
        urlRequest.httpBody = bodyData

        AppLog.provider.info("POST \(url.absoluteString)")
        AppLog.provider.info("Request body: \(String(data: bodyData, encoding: .utf8) ?? "<err>")")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.requestFailed(statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
            AppLog.provider.error("Provider returned \(httpResponse.statusCode). Body: \(bodyStr.prefix(500))")
            throw ProviderError.apiError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Private

    private func buildRequestBody(from request: AIRequest) -> ChatCompletionRequest {
        let messages = request.messages.map { msg in
            let content = msg.content.map { block -> String in
                switch block {
                case .text(let text): return text
                case .audioFile: return "[audio]"
                case .imageFile: return "[image]"
                }
            }.joined(separator: "\n")

            return ChatCompletionRequest.RequestMessage(role: msg.role.rawValue, content: content)
        }

        let effectiveModel = request.model.isEmpty ? model : request.model
        let preset = AIConfigService.shared.presetFor(model: effectiveModel)
        let usesMaxTokens = preset?.usesMaxCompletionTokens == false

        let responseFormat: ChatCompletionRequest.ResponseFormat? = {
            if request.responseFormat == .json {
                return ChatCompletionRequest.ResponseFormat(type: "json_object")
            }
            return nil
        }()

        return ChatCompletionRequest(
            model: effectiveModel,
            messages: messages,
            temperature: (preset?.supportsTemperature == false) ? nil : request.temperature,
            maxTokens: (preset?.supportsMaxTokens == false) ? nil : request.maxTokens,
            responseFormat: responseFormat,
            usesMaxTokens: usesMaxTokens
        )
    }

    private func parseResponse(data: Data) throws -> AIResponse {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            AppLog.provider.error("Failed to decode response: \(error.localizedDescription)")
            throw ProviderError.decodingFailed
        }

        let usage: AIUsage? = {
            if let u = decoded.usage {
                return AIUsage(promptTokens: u.promptTokens, completionTokens: u.completionTokens, totalTokens: u.totalTokens)
            }
            return nil
        }()

        let response = AIResponse(
            id: decoded.id,
            model: decoded.model,
            content: decoded.choices.first?.message.content ?? "",
            usage: usage
        )
        AppLog.provider.info("Received response: \(response.content.prefix(100))...")
        return response
    }

    func embed(_ text: String, model: String) async throws -> [Float] {
        guard capabilities.supportsEmbeddings else {
            throw ProviderError.embeddingNotSupported
        }
        let endpoint = baseURL.appendingPathComponent("embeddings")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "input": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
}
