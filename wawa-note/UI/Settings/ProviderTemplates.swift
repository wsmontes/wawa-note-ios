import Foundation

// MARK: - Provider category

enum ProviderCategory: String, CaseIterable {
    case cloud
    case local
}

// MARK: - Provider template

struct ProviderTemplate: Identifiable, Equatable {
    let id: String
    let displayName: String
    let subtitle: String
    let systemImageName: String
    let providerType: ProviderType
    let baseURL: String
    let defaultModel: String
    let category: ProviderCategory
    let getAPIKeyURL: URL?
    let requiresAuth: Bool
    let scanPort: Int?
    let scanPath: String?

    // MARK: - Cloud providers

    static let openAI = ProviderTemplate(
        id: "openai",
        displayName: "ChatGPT by OpenAI",
        subtitle: "Cloud AI. Requires an API key.",
        systemImageName: "brain.head.profile",
        providerType: .openAI,
        baseURL: "https://api.openai.com/v1",
        defaultModel: "gpt-4o",
        category: .cloud,
        getAPIKeyURL: URL(string: "https://platform.openai.com/api-keys"),
        requiresAuth: true,
        scanPort: nil,
        scanPath: nil
    )

    static let anthropic = ProviderTemplate(
        id: "anthropic",
        displayName: "Claude by Anthropic",
        subtitle: "Cloud AI. Requires an API key.",
        systemImageName: "sparkles",
        providerType: .anthropic,
        baseURL: "https://api.anthropic.com/v1",
        defaultModel: "claude-sonnet-4-20250514",
        category: .cloud,
        getAPIKeyURL: URL(string: "https://console.anthropic.com/keys"),
        requiresAuth: true,
        scanPort: nil,
        scanPath: nil
    )

    static let gemini = ProviderTemplate(
        id: "gemini",
        displayName: "Google Gemini",
        subtitle: "Cloud AI. Requires an API key.",
        systemImageName: "circle.hexagongrid",
        providerType: .gemini,
        baseURL: "https://generativelanguage.googleapis.com/v1beta",
        defaultModel: "gemini-2.0-flash",
        category: .cloud,
        getAPIKeyURL: URL(string: "https://aistudio.google.com/apikey"),
        requiresAuth: true,
        scanPort: nil,
        scanPath: nil
    )

    // MARK: - Local providers

    static let lmStudio = ProviderTemplate(
        id: "lmstudio",
        displayName: "LM Studio",
        subtitle: "Runs on your Mac. No API key needed. Free.",
        systemImageName: "desktopcomputer",
        providerType: .localNetwork,
        baseURL: "http://localhost:1234/v1",
        defaultModel: "local-model",
        category: .local,
        getAPIKeyURL: nil,
        requiresAuth: false,
        scanPort: 1234,
        scanPath: "/v1/models"
    )

    static let ollama = ProviderTemplate(
        id: "ollama",
        displayName: "Ollama",
        subtitle: "Runs on your Mac. No API key needed. Free.",
        systemImageName: "shippingbox",
        providerType: .localNetwork,
        baseURL: "http://localhost:11434",
        defaultModel: "llama3",
        category: .local,
        getAPIKeyURL: nil,
        requiresAuth: false,
        scanPort: 11434,
        scanPath: "/api/tags"
    )

    // MARK: - Collections

    static let all: [ProviderTemplate] = [.openAI, .anthropic, .gemini, .lmStudio, .ollama]
    static let cloudTemplates: [ProviderTemplate] = [.openAI, .anthropic, .gemini]
    static let localTemplates: [ProviderTemplate] = [.lmStudio, .ollama]

    // MARK: - Equatable

    static func == (lhs: ProviderTemplate, rhs: ProviderTemplate) -> Bool {
        lhs.id == rhs.id
    }
}
