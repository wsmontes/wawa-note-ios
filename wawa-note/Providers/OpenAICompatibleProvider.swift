import Foundation
import OSLog

// MARK: - Request body codable types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }

    struct RequestMessage: Encodable {
        let role: String
        let content: String
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
        struct Message: Decodable {
            let content: String
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
        id: String,
        displayName: String,
        baseURL: URL,
        apiKey: String,
        model: String,
        capabilities: AIProviderCapabilities = AIProviderCapabilities(
            supportsStreaming: true,
            supportsAudioInput: false,
            supportsStructuredOutput: true,
            supportsToolCalling: false,
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
        let url = baseURL.appendingPathComponent("chat/completions")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = buildRequestBody(from: request)
        urlRequest.httpBody = try JSONEncoder().encode(body)

        AppLog.provider.info("Sending request to \(self.baseURL.host ?? "unknown") with model \(self.model)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.requestFailed(statusCode: -1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            AppLog.provider.error("Provider returned status \(httpResponse.statusCode)")
            throw ProviderError.requestFailed(statusCode: httpResponse.statusCode)
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

            return ChatCompletionRequest.RequestMessage(
                role: msg.role.rawValue,
                content: content
            )
        }

        let responseFormat: ChatCompletionRequest.ResponseFormat? = {
            if request.responseFormat == .json {
                return ChatCompletionRequest.ResponseFormat(type: "json_object")
            }
            return nil
        }()

        return ChatCompletionRequest(
            model: request.model.isEmpty ? model : request.model,
            messages: messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            responseFormat: responseFormat
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
}
