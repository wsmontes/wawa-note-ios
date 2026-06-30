import Foundation
import OSLog

// Related JIRA: KAN-9, KAN-42

// MARK: - Messages API

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]
    let temperature: Double?
    let stopSequences: [String]?
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?
    let stream: Bool?

    struct AnthropicTool: Encodable {
        let name: String
        let description: String
        let inputSchema: InputSchema

        struct InputSchema: Encodable {
            let type: String
            let properties: [String: PropertyDef]?
            let required: [String]?

            struct PropertyDef: Encodable {
                let type: String
                let description: String
                let `enum`: [String]?

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                    try container.encode(description, forKey: .description)
                    try container.encodeIfPresent(`enum`, forKey: .enum)
                }

                enum CodingKeys: String, CodingKey {
                    case type, description, `enum`
                }
            }

            enum CodingKeys: String, CodingKey {
                case type, properties, required
            }
        }

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    struct AnthropicToolChoice: Encodable {
        let type: String
    }

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
            let id: String?
            let name: String?
            let inputJSON: String?  // arguments as JSON string (tool_use)
            let toolUseId: String?  // tool_result blocks
            let content: String?  // tool_result text

            private enum CodingKeys: String, CodingKey {
                case type, text, id, name, input
                case toolUseId = "tool_use_id"
                case content
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(type, forKey: .type)
                switch type {
                case "text":
                    try container.encodeIfPresent(text, forKey: .text)
                case "tool_use":
                    try container.encodeIfPresent(id, forKey: .id)
                    try container.encodeIfPresent(name, forKey: .name)
                    if let jsonStr = inputJSON, !jsonStr.isEmpty,
                        let data = jsonStr.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        try container.encode(obj.mapValues { AnyEncodableValue.from($0) }, forKey: .input)
                    }
                case "tool_result":
                    try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
                    try container.encodeIfPresent(content, forKey: .content)
                default:
                    break
                }
            }
        }

        /// Type-erased encodable wrapper for JSON values in tool_use input.
        enum AnyEncodableValue: Encodable {
            case string(String)
            case int(Int)
            case double(Double)
            case bool(Bool)
            case object([String: AnyEncodableValue])
            case array([AnyEncodableValue])
            case null

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

            static func from(_ value: Any) -> AnyEncodableValue {
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
            case role, content
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages, temperature
        case stopSequences = "stop_sequences"
        case tools
        case toolChoice = "tool_choice"
        case stream
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
        let id: String?
        let name: String?
        let input: [String: AnyDecodable]?

        struct AnyDecodable: Decodable {
            let value: Any
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let s = try? container.decode(String.self) {
                    value = s
                } else if let i = try? container.decode(Int.self) {
                    value = i
                } else if let d = try? container.decode(Double.self) {
                    value = d
                } else if let b = try? container.decode(Bool.self) {
                    value = b
                } else if let arr = try? container.decode([AnyDecodable].self) {
                    value = arr.map(\.value)
                } else if let obj = try? container.decode([String: AnyDecodable].self) {
                    value = obj.mapValues(\.value)
                } else {
                    value = "null"
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input
        }
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

    private static var configuredSession: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    init(
        id: String, displayName: String, baseURL: URL, apiKey: String, model: String,
        session: URLSession = AnthropicProvider.configuredSession
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

    // MARK: - Request body builder (shared by send + sendStreaming)

    private func buildRequestBody(_ request: AIRequest, stream: Bool = false) throws -> AnthropicRequest {
        let systemPrompt = request.messages
            .filter { $0.role == .system }
            .compactMap { msg in
                msg.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: "\n")
            }
            .joined(separator: "\n\n").nilIfEmpty

        let conversationMessages = request.messages.filter { $0.role != .system }
        let messages: [AnthropicRequest.Message] =
            conversationMessages.isEmpty
            ? [AnthropicRequest.Message(role: "user", content: .string("Hello"))]
            : conversationMessages.flatMap { msg -> [AnthropicRequest.Message] in
                let textContent = msg.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: "\n")
                if msg.role == .assistant, let tcs = msg.toolCalls, !tcs.isEmpty {
                    var blocks: [AnthropicRequest.Message.ContentBlock] = []
                    if !textContent.isEmpty {
                        blocks.append(
                            AnthropicRequest.Message.ContentBlock(
                                type: "text", text: textContent, id: nil, name: nil, inputJSON: nil, toolUseId: nil, content: nil))
                    }
                    for tc in tcs {
                        blocks.append(
                            AnthropicRequest.Message.ContentBlock(
                                type: "tool_use", text: nil, id: tc.id, name: tc.name, inputJSON: tc.arguments, toolUseId: nil, content: nil))
                    }
                    return [AnthropicRequest.Message(role: "assistant", content: .blocks(blocks))]
                }
                if msg.role == .tool {
                    let toolResultText = msg.content.compactMap { block -> String? in
                        if case .text(let t) = block { return t }
                        return nil
                    }.joined(separator: "\n")
                    return [
                        AnthropicRequest.Message(
                            role: "user",
                            content: .blocks([
                                AnthropicRequest.Message.ContentBlock(
                                    type: "tool_result", text: nil, id: nil, name: nil, inputJSON: nil, toolUseId: msg.toolCallId ?? "", content: toolResultText
                                )
                            ]))
                    ]
                }
                let roleString = msg.role == .assistant ? "assistant" : "user"
                return [AnthropicRequest.Message(role: roleString, content: .string(textContent))]
            }

        let effectiveModel = request.model.isEmpty ? model : request.model
        let maxTokens = request.maxTokens ?? 4096
        let anthropicTools: [AnthropicRequest.AnthropicTool]? = request.tools?.map { tool in
            let props = tool.parameters.properties.mapValues { p in
                AnthropicRequest.AnthropicTool.InputSchema.PropertyDef(type: p.type, description: p.description, enum: p.enum)
            }
            return AnthropicRequest.AnthropicTool(
                name: tool.name, description: tool.description,
                inputSchema: AnthropicRequest.AnthropicTool.InputSchema(
                    type: tool.parameters.type,
                    properties: props.isEmpty ? nil : props, required: tool.parameters.required.isEmpty ? nil : tool.parameters.required))
        }

        return AnthropicRequest(
            model: effectiveModel, maxTokens: maxTokens, system: systemPrompt,
            messages: messages, temperature: request.temperature, stopSequences: nil,
            tools: anthropicTools, toolChoice: (anthropicTools != nil) ? AnthropicRequest.AnthropicToolChoice(type: "auto") : nil,
            stream: stream ? true : nil)
    }

    func send(_ request: AIRequest) async throws -> AIResponse {
        let url = baseURL.appendingPathComponent("messages")
        let body = try buildRequestBody(request, stream: false)

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
        do { decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data) } catch {
            AppLog.provider.error("Failed to decode Anthropic response: \(error)")
            throw ProviderError.decodingFailed
        }

        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        let thinkingText = decoded.content.filter { $0.type == "thinking" }.compactMap(\.text).joined(separator: "\n").nilIfEmpty

        let toolCalls: [AIToolCall]? = {
            let toolBlocks = decoded.content.filter { $0.type == "tool_use" }
            guard !toolBlocks.isEmpty else { return nil }
            return toolBlocks.compactMap { block -> AIToolCall? in
                guard let id = block.id, let name = block.name else { return nil }
                let args: String
                if let input = block.input {
                    let raw: [String: Any] = input.mapValues { $0.value }
                    if let data = try? JSONSerialization.data(withJSONObject: raw), let js = String(data: data, encoding: .utf8) {
                        args = js
                    } else {
                        args = "{}"
                    }
                } else {
                    args = "{}"
                }
                return AIToolCall(id: id, name: name, arguments: args)
            }
        }()

        let usage = AIUsage(
            promptTokens: decoded.usage.inputTokens, completionTokens: decoded.usage.outputTokens,
            totalTokens: (decoded.usage.inputTokens ?? 0) + (decoded.usage.outputTokens ?? 0))

        AppLog.provider.info("Anthropic response: \(text.prefix(100))... tool_calls: \(toolCalls?.count ?? 0)")
        return AIResponse(
            id: decoded.id, model: decoded.model, content: text,
            reasoningContent: thinkingText, usage: usage, toolCalls: toolCalls, finishReason: decoded.stopReason)
    }

    // MARK: - Streaming (SSE)

    func sendStreaming(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("messages")
                    let body = try buildRequestBody(request, stream: true)

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.httpBody = try JSONEncoder().encode(body)

                    AppLog.provider.info("POST \(url.absoluteString) (streaming)")

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await byte in bytes { errorBody.append(Character(UnicodeScalar(byte))) }
                        continuation.finish(throwing: ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: errorBody))
                        return
                    }

                    var currentToolID = ""
                    var currentToolName: String?
                    var currentToolArgs = ""
                    var finishReason: String?

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8),
                            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let type = obj["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any] {
                                let deltaType = delta["type"] as? String ?? ""
                                if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                                    continuation.yield(.thinkingDelta(thinking))
                                } else if let textDelta = delta["text"] as? String {
                                    continuation.yield(.textDelta(textDelta))
                                } else if deltaType == "input_json_delta",
                                    let partial = delta["partial_json"] as? String
                                {
                                    currentToolArgs += partial
                                    if currentToolID.isEmpty, let index = obj["index"] as? Int { currentToolID = "tc_\(index)" }
                                    continuation.yield(.toolCallDelta(id: currentToolID, name: currentToolName, arguments: partial))
                                }
                            }
                        case "content_block_start":
                            if let block = obj["content_block"] as? [String: Any] {
                                if block["type"] as? String == "tool_use" {
                                    currentToolID = block["id"] as? String ?? currentToolID
                                    currentToolName = block["name"] as? String ?? currentToolName
                                    currentToolArgs = ""
                                }
                                // Thinking block detection — no delta needed, just note it started
                            }
                        case "message_delta":
                            if let delta = obj["delta"] as? [String: Any] { finishReason = delta["stop_reason"] as? String }
                        case "message_stop":
                            continuation.yield(.finished(finishReason.flatMap { AIFinishReason(rawValue: $0) }))
                            continuation.finish()
                            return
                        default: break
                        }
                    }
                    continuation.yield(.finished(finishReason.flatMap { AIFinishReason(rawValue: $0) }))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
