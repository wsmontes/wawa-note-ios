import Foundation

// MARK: - Provider protocol

protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: AIProviderCapabilities { get }

    func send(_ request: AIRequest) async throws -> AIResponse
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

struct AIRequest: Codable, Sendable {
    var model: String
    var messages: [AIMessage]
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: AIResponseFormat?

    enum AIResponseFormat: String, Codable, Sendable {
        case json
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

enum ProviderError: Error {
    case missingAPIKey
    case invalidBaseURL
    case requestFailed(statusCode: Int)
    case decodingFailed
    case providerNotFound
    case networkUnavailable
    case unauthorized
    case timeout

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
        }
    }
}
