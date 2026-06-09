import Foundation
import OSLog

// MARK: - Chat Completions API

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?

    struct Message: Encodable {
        let role: String
        let content: Content

        enum Content: Encodable {
            case string(String)
            case parts([ContentPart])

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let s): try container.encode(s)
                case .parts(let p): try container.encode(p)
                }
            }
        }

        struct ContentPart: Encodable {
            let type: String
            let text: String?
            let imageUrl: ImageURL?

            enum CodingKeys: String, CodingKey {
                case type, text
                case imageUrl = "image_url"
            }

            struct ImageURL: Encodable {
                let url: String
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    struct ResponseFormat: Encodable {
        let type: String
        var jsonSchema: JSONSchema? = nil

        struct JSONSchema: Encodable {
            let name: String
            let strict: Bool
            let schema: String
        }

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(jsonSchema, forKey: .jsonSchema)
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

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

            /// Returns content or reasoning_content (DeepSeek V4, o3, etc.)
            var effectiveContent: String? { content ?? reasoningContent }

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

        var body: [String: Any] = [
            "model": effectiveModel,
            "messages": bodyMessages
        ]
        if let t = request.temperature { body["temperature"] = t }
        if let mt = request.maxTokens {
            let preset = AIConfigService.shared.presetFor(model: effectiveModel)
            if preset?.usesMaxCompletionTokens == true {
                body["max_completion_tokens"] = mt
            } else {
                body["max_tokens"] = mt
            }
        }

        if let fmt = request.responseFormat {
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

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        let finishReason = decoded.choices.first?.finishReason

        let toolCalls: [AIToolCall]? = msg?.toolCalls?.compactMap { tc -> AIToolCall? in
            guard let id = tc.id, let fn = tc.function, let name = fn.name else { return nil }
            return AIToolCall(id: id, name: name, arguments: fn.arguments ?? "{}")
        }

        AppLog.provider.info("Response: \(text.prefix(100))...")
        return AIResponse(id: decoded.id, model: decoded.model, content: text, usage: usage, toolCalls: toolCalls, finishReason: finishReason)
    }

    private func buildContent(from blocks: [AIContentBlock]) -> ChatCompletionRequest.Message.Content {
        let textBlocks = blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }
        let imageBlocks = blocks.compactMap { block -> URL? in
            if case .imageFile(let url) = block { return url }
            return nil
        }

        if imageBlocks.isEmpty {
            return .string(textBlocks.joined(separator: "\n"))
        }

        var parts: [ChatCompletionRequest.Message.ContentPart] = []
        for text in textBlocks {
            parts.append(ChatCompletionRequest.Message.ContentPart(type: "text", text: text, imageUrl: nil))
        }
        for imageURL in imageBlocks {
            let urlString = Self.base64DataURL(from: imageURL) ?? imageURL.absoluteString
            parts.append(ChatCompletionRequest.Message.ContentPart(
                type: "image_url",
                text: nil,
                imageUrl: ChatCompletionRequest.Message.ContentPart.ImageURL(url: urlString)
            ))
        }
        return .parts(parts)
    }

    // MARK: - Embeddings

    func embed(_ text: String, model: String) async throws -> [Float] {
        guard capabilities.supportsEmbeddings else {
            throw ProviderError.embeddingNotSupported
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
