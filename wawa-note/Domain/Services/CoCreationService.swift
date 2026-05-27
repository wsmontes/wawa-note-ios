import Foundation

final class CoCreationService: @unchecked Sendable {

    func expand(
        content: String,
        instruction: String,
        using provider: any AIProvider,
        model: String
    ) async throws -> CocreationResult {
        let config = AIConfigService.shared
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
            responseFormat: .json
        ))

        guard let data = response.content.data(using: .utf8) else {
            return CocreationResult(expandedText: response.content, suggestions: [], relatedItemIds: [])
        }

        struct Raw: Decodable {
            let expandedText: String?
            let expanded_text: String?
            let suggestions: [String]?
            let relatedItems: [String]?
            let related_items: [String]?
            let relatedItemIds: [String]?
            let related_item_ids: [String]?
        }

        if let raw = try? JSONDecoder().decode(Raw.self, from: data) {
            let text = raw.expandedText ?? raw.expanded_text ?? response.content
            let sugs = (raw.suggestions ?? []).map {
                CoCreationSuggestion(text: $0, category: .expansion, relatedItemIds: [])
            }
            let ids = (raw.relatedItems ?? raw.related_items ?? raw.relatedItemIds ?? raw.related_item_ids ?? [])
                .compactMap(UUID.init(uuidString:))
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
