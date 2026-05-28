import Foundation
import OSLog

final class LensAnalysisService: @unchecked Sendable {

    func allLenses() -> [LensConfig] {
        guard let json = AIConfigService.shared.config.lenses else { return [] }
        return json.map { LensConfig(
            id: $0.key,
            name: $0.value.name ?? $0.key,
            description: $0.value.description ?? "",
            icon: $0.value.icon,
            systemPrompt: $0.value.systemPrompt,
            userPrompt: $0.value.userPrompt ?? "",
            temperature: $0.value.temperature,
            model: $0.value.model
        )}
    }

    func lens(by id: String) -> LensConfig? {
        allLenses().first { $0.id == id }
    }

    func analyze(
        content: String,
        lensId: String,
        using provider: any AIProvider,
        defaultModel: String,
        variables: [String: String] = [:]
    ) async throws -> LensResult {
        guard let lens = lens(by: lensId) else {
            throw ProviderError.providerNotFound
        }

        let model = lens.model ?? defaultModel

        // Render user prompt
        var userPrompt = lens.userPrompt
        userPrompt = userPrompt.replacingOccurrences(of: "{content}", with: content)
        for (key, value) in variables {
            userPrompt = userPrompt.replacingOccurrences(of: "{\(key)}", with: value)
        }

        let messages: [AIMessage] = [
            AIMessage(role: .system, content: [.text(lens.systemPrompt ?? "You are a helpful analyst.")]),
            AIMessage(role: .user, content: [.text(userPrompt)])
        ]

        let request = AIRequest(
            model: model,
            messages: messages,
            temperature: lens.temperature,
            responseFormat: .jsonObject
        )

        let response = try await provider.send(request)

        let cleaned = ProviderAdapter.normalizeJSON(response.content)
        let rawData = cleaned.data(using: .utf8)

        return LensResult(lensId: lensId, lensName: lens.name, content: cleaned, parsed: rawData)
    }

    func compare(
        content: String,
        lensIds: [String],
        using provider: any AIProvider,
        defaultModel: String
    ) async -> [LensResult] {
        await withTaskGroup(of: LensResult?.self) { group in
            for lid in lensIds {
                group.addTask {
                    try? await self.analyze(content: content, lensId: lid, using: provider, defaultModel: defaultModel)
                }
            }
            var results: [LensResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }
}
