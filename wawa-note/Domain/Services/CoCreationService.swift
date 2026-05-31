import Foundation

final class CoCreationService: @unchecked Sendable {

    func expand(
        content: String,
        instruction: String,
        using provider: any AIProvider,
        model: String
    ) async throws -> CocreationResult {
        let config = AIConfigService.shared
        let params = config.requestParams(for: "co_creation", model: model)
        let systemPrompt = config.systemPrompt(for: "co_creation")
            ?? "You are a collaborative AI writing partner."
        let userPrompt = (config.userPrompt(for: "co_creation") ?? "")
            .replacingOccurrences(of: "{content}", with: content)
            .replacingOccurrences(of: "{context}", with: "")
            .replacingOccurrences(of: "{instruction}", with: instruction)

        let response = try await provider.send(AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(userPrompt)])
            ],
            temperature: params.temperature,
            maxTokens: params.maxTokens,
            responseFormat: .jsonObject
        ))

        struct Raw: Decodable {
            let expandedText: String?
            let suggestions: [String]?
            let relatedItems: [String]?
            enum CodingKeys: String, CodingKey {
                case expandedText = "expanded_text"
                case suggestions
                case relatedItems = "related_items"
            }
        }

        if let raw = try? ProviderAdapter.decode(Raw.self, from: response.content) {
            let text = raw.expandedText ?? response.content
            let sugs = (raw.suggestions ?? []).map {
                CoCreationSuggestion(text: $0, category: .expansion, relatedItemIds: [])
            }
            let ids = (raw.relatedItems ?? []).compactMap(UUID.init(uuidString:))
            return CocreationResult(expandedText: text, suggestions: sugs, relatedItemIds: ids)
        }

        return CocreationResult(expandedText: response.content, suggestions: [], relatedItemIds: [])
    }

    func suggestConnections(
        for itemId: UUID,
        content: String,
        allItemIDs: [UUID],
        using provider: any AIProvider,
        model: String
    ) async throws -> [CoCreationSuggestion] {
        var suggestions: [CoCreationSuggestion] = []
        suggestions.append(CoCreationSuggestion(
            text: "Expand this note with more detail",
            category: .expansion,
            relatedItemIds: []
        ))
        suggestions.append(CoCreationSuggestion(
            text: "Check for related meetings",
            category: .connection,
            relatedItemIds: allItemIDs.prefix(3).map { $0 }
        ))
        return suggestions
    }
}
