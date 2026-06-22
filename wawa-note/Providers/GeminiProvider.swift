import Foundation
import OSLog
// Related JIRA: KAN-9, KAN-42


// MARK: - Gemini Generate Content API

private struct GeminiRequest: Encodable {
    let systemInstruction: SystemInstruction?
    let contents: [Content]
    let generationConfig: GenerationConfig?
    let tools: [GeminiTool]?

    struct SystemInstruction: Encodable {
        let parts: [Part]
    }

    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String?
        let functionCall: FunctionCall?
        let functionResponse: FunctionResponse?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let text { try container.encode(text, forKey: .text) }
            if let fc = functionCall { try container.encode(fc, forKey: .functionCall) }
            if let fr = functionResponse { try container.encode(fr, forKey: .functionResponse) }
        }

        struct FunctionCall: Encodable {
            let name: String
            let args: [String: GeminiAnyValue]
        }

        struct FunctionResponse: Encodable {
            let name: String
            let response: [String: GeminiAnyValue]
        }

        enum CodingKeys: String, CodingKey {
            case text, functionCall, functionResponse
        }
    }

    struct GeminiTool: Encodable {
        let functionDeclarations: [FunctionDeclaration]

        enum CodingKeys: String, CodingKey {
            case functionDeclarations
        }
    }

    struct FunctionDeclaration: Encodable {
        let name: String
        let description: String
        let parameters: Parameters

        struct Parameters: Encodable {
            let type: String
            let properties: [String: PropertyDef]?
            let required: [String]?

            struct PropertyDef: Encodable {
                let type: String
                let description: String
                let `enum`: [String]?
            }
        }
    }

    /// Recursive JSON value encoder for tool call arguments.
    enum GeminiAnyValue: Encodable {
        case string(String), int(Int), double(Double), bool(Bool)
        case object([String: GeminiAnyValue]), array([GeminiAnyValue]), null

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }

        static func from(_ value: Any) -> GeminiAnyValue {
            switch value {
            case let s as String: return .string(s)
            case let i as Int: return .int(i)
            case let d as Double: return .double(d)
            case let b as Bool: return .bool(b)
            case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
            case let arr as [Any]: return .array(arr.map { from($0) })
            default: return .null
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case systemInstruction, contents, generationConfig, tools
    }
}

struct GenerationConfig: Encodable {
    let temperature: Double?
    let maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case temperature
        case maxOutputTokens = "maxOutputTokens"
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
                let functionCall: FunctionCall?

                struct FunctionCall: Decodable {
                    let name: String
                    let args: [String: AnyDecodable]?
                }

                /// Type-erased decodable for arbitrary JSON in functionCall args.
                struct AnyDecodable: Decodable {
                    let value: Any

                    init(from decoder: any Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let s = try? container.decode(String.self) { value = s }
                        else if let i = try? container.decode(Int.self) { value = i }
                        else if let d = try? container.decode(Double.self) { value = d }
                        else if let b = try? container.decode(Bool.self) { value = b }
                        else if let arr = try? container.decode([AnyDecodable].self) { value = arr.map(\.value) }
                        else if let obj = try? container.decode([String: AnyDecodable].self) { value = obj.mapValues { $0.value } }
                        else { value = "null" }
                    }
                }
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
            GeminiRequest.SystemInstruction(parts: [GeminiRequest.Part(text: $0, functionCall: nil, functionResponse: nil)])
        }

        // Non-system messages (Gemini uses "user" and "model" roles)
        let conversationMessages = request.messages.filter { $0.role != .system }
        let contents: [GeminiRequest.Content] = conversationMessages.flatMap { msg -> [GeminiRequest.Content] in
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

            // Tool call: serialize as functionCall part
            if msg.role == .assistant, let tcs = msg.toolCalls, !tcs.isEmpty {
                var parts: [GeminiRequest.Part] = []
                if !textContent.isEmpty {
                    parts.append(GeminiRequest.Part(text: textContent, functionCall: nil, functionResponse: nil))
                }
                for tc in tcs {
                    let argsObj: [String: GeminiRequest.GeminiAnyValue]
                    if let data = tc.arguments.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        argsObj = obj.mapValues { GeminiRequest.GeminiAnyValue.from($0) }
                    } else {
                        argsObj = [:]
                    }
                    parts.append(GeminiRequest.Part(
                        text: nil,
                        functionCall: GeminiRequest.Part.FunctionCall(name: tc.name, args: argsObj),
                        functionResponse: nil))
                }
                return [GeminiRequest.Content(role: "model", parts: parts)]
            }

            // Tool result: serialize as functionResponse part
            if msg.role == .tool {
                let toolName = msg.toolCallId ?? "unknown"
                let responseObj: [String: GeminiRequest.GeminiAnyValue] = [
                    "content": .string(textContent)
                ]
                let part = GeminiRequest.Part(
                    text: nil, functionCall: nil,
                    functionResponse: GeminiRequest.Part.FunctionResponse(name: toolName, response: responseObj))
                return [GeminiRequest.Content(role: "user", parts: [part])]
            }

            return [GeminiRequest.Content(role: role, parts: [GeminiRequest.Part(text: textContent, functionCall: nil, functionResponse: nil)])]
        }

        let genConfig = GenerationConfig(
            temperature: request.temperature,
            maxOutputTokens: request.maxTokens
        )

        // Map AI tool definitions to Gemini format
        let geminiTools: [GeminiRequest.GeminiTool]? = request.tools?.map { tool in
            let props = tool.parameters.properties.mapValues { p in
                GeminiRequest.FunctionDeclaration.Parameters.PropertyDef(type: p.type, description: p.description, enum: p.enum)
            }
            return GeminiRequest.GeminiTool(functionDeclarations: [
                GeminiRequest.FunctionDeclaration(
                    name: tool.name,
                    description: tool.description,
                    parameters: GeminiRequest.FunctionDeclaration.Parameters(
                        type: tool.parameters.type,
                        properties: props.isEmpty ? nil : props,
                        required: tool.parameters.required.isEmpty ? nil : tool.parameters.required
                    )
                )
            ])
        }

        let body = GeminiRequest(
            systemInstruction: systemInstruction,
            contents: contents,
            generationConfig: genConfig,
            tools: geminiTools
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

        guard let candidate = decoded.candidates.first else {
            AppLog.provider.warning("Gemini response had no candidates")
            return AIResponse(id: nil, model: effectiveModel, content: "", usage: nil)
        }

        let parts = candidate.content?.parts ?? []

        let text = parts.compactMap(\.text).joined(separator: "\n")

        // Extract functionCall parts as AIToolCall objects
        let toolCalls: [AIToolCall]? = {
            let fcParts = parts.compactMap { $0.functionCall }
            guard !fcParts.isEmpty else { return nil }
            return fcParts.map { fc in
                let argsStr: String
                if let args = fc.args {
                    let raw: [String: Any] = args.mapValues { $0.value }
                    if let data = try? JSONSerialization.data(withJSONObject: raw),
                       let jsonStr = String(data: data, encoding: .utf8) {
                        argsStr = jsonStr
                    } else {
                        argsStr = "{}"
                    }
                } else {
                    argsStr = "{}"
                }
                return AIToolCall(id: fc.name, name: fc.name, arguments: argsStr)
            }
        }()

        let finishReason = candidate.finishReason

        let usage: AIUsage? = {
            guard let u = decoded.usageMetadata else { return nil }
            return AIUsage(
                promptTokens: u.promptTokenCount,
                completionTokens: u.candidatesTokenCount,
                totalTokens: u.totalTokenCount
            )
        }()

        AppLog.provider.info("Gemini response: \(text.prefix(100))...")
        return AIResponse(id: nil, model: effectiveModel, content: text, usage: usage, toolCalls: toolCalls, finishReason: finishReason)
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
