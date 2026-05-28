import Foundation

// MARK: - Provider protocol

protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var providerType: ProviderType { get }
    var capabilities: AIProviderCapabilities { get }

    func send(_ request: AIRequest) async throws -> AIResponse
    func embed(_ text: String, model: String) async throws -> [Float]
    func fetchModels() async throws -> [String]
}

extension AIProvider {
    func embed(_ text: String, model: String) async throws -> [Float] {
        throw ProviderError.embeddingNotSupported
    }
    func fetchModels() async throws -> [String] { [] }
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
        var stringValue: String; var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
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
}

// MARK: - Message

struct AIMessage: Codable, Identifiable, Sendable {
    let id: UUID
    var role: AIRole
    var content: [AIContentBlock]

    init(id: UUID = UUID(), role: AIRole, content: [AIContentBlock]) {
        self.id = id
        self.role = role
        self.content = content
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
    var rawResponsePath: String?
    var usage: AIUsage?
}

struct AIUsage: Codable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
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

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Your API key is missing. Paste it in Settings > AI Services."
        case .invalidBaseURL:
            "The server address doesn't look right. Check it in Settings > AI Services."
        case .requestFailed(let code):
            code == 401 ? "Your API key was rejected. Check that it's correct in Settings > AI Services." :
            code == 404 ? "Couldn't reach the server at that address. Check the server address in Settings." :
            code == 429 ? "You've made too many requests. Wait a moment, then try again." :
            code >= 500 ? "The AI service is having trouble. This is on their end — try again in a few minutes." :
            "Something went wrong (error \(code)). Check your connection in Settings."
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
        }
    }
}

private func extractErrorBody(_ body: String) -> String {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any],
          let message = error["message"] as? String else {
        return String(body.prefix(200))
    }
    return message
}
