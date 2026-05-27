import Foundation
import OSLog

final class CrossReferenceService: @unchecked Sendable {
    private let semanticSearch: SemanticSearchService
    private let fileStore: FileArtifactStore

    init(semanticSearch: SemanticSearchService = SemanticSearchService(),
         fileStore: FileArtifactStore = FileArtifactStore()) {
        self.semanticSearch = semanticSearch
        self.fileStore = fileStore
    }

    func query(
        _ question: String,
        across allItemIDs: [UUID],
        using provider: any AIProvider,
        model: String
    ) async throws -> CrossReferenceResult {
        // Pass 1: Semantic search
        let relevant = try await semanticSearch.findRelevant(
            query: question,
            itemIDs: allItemIDs,
            limit: 8,
            using: provider
        )

        AppLog.general.info("CrossReference: found \(relevant.count) relevant items")

        // Pass 2: Build tiered context
        let context = buildContext(from: relevant.map(\.itemId))

        // Pass 3: AI synthesis
        let config = AIConfigService.shared
        let systemPrompt = config.systemPrompt(for: "cross_reference")
            ?? "You are analyzing a knowledge workspace. Identify connections, patterns, and contradictions."
        let userPrompt = config.renderPrompt(for: "cross_reference", variables: [
            "question": question,
            "context": context
        ])

        let response = try await provider.send(AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(userPrompt)])
            ],
            responseFormat: .json
        ))

        return try parse(response.content)
    }

    private func buildContext(from itemIDs: [UUID]) -> String {
        var ctx = ""
        for (i, itemId) in itemIDs.enumerated() {
            if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: itemId) {
                ctx += "[ITEM:\(itemId.uuidString.prefix(8))]\n"
                if !analysis.shortSummary.isEmpty {
                    ctx += "Summary: \(analysis.shortSummary)\n"
                }
                if !analysis.actionItems.isEmpty {
                    ctx += "Actions: \(analysis.actionItems.map(\.task).joined(separator: "; "))\n"
                }
                if !analysis.decisions.isEmpty {
                    ctx += "Decisions: \(analysis.decisions.map(\.title).joined(separator: "; "))\n"
                }
                ctx += "\n"
            } else if let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemId) {
                ctx += "[ITEM:\(itemId.uuidString.prefix(8))]\n"
                let text = transcript.segments.prefix(10).map(\.text).joined(separator: " ")
                ctx += "Transcript excerpt: \(text)\n\n"
            }
        }
        return ctx
    }

    private func parse(_ json: String) throws -> CrossReferenceResult {
        guard let data = json.data(using: .utf8) else {
            throw ProviderError.decodingFailed
        }
        return try JSONDecoder().decode(CrossReferenceResult.self, from: data)
    }
}
