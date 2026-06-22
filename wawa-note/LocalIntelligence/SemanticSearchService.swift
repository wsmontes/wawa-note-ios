import Foundation
import OSLog
// Related JIRA: KAN-150


final class SemanticSearchService: @unchecked Sendable {
    private let embeddingService: EmbeddingService
    private let fileStore: FileArtifactStore

    init(embeddingService: EmbeddingService = EmbeddingService(), fileStore: FileArtifactStore = FileArtifactStore()) {
        self.embeddingService = embeddingService
        self.fileStore = fileStore
    }

    func findRelevant(
        query: String,
        itemIDs: [UUID],
        limit: Int = 10,
        using provider: any AIProvider
    ) async throws -> [(itemId: UUID, score: Float)] {
        guard !itemIDs.isEmpty else { return [] }

        // Embed the query using the same model configured in EmbeddingService.
        // Avoids model drift between stored vectors and query vectors.
        let queryVector = try await provider.embed(query, model: embeddingService.configuredModel)

        // Score all items with cached embeddings
        var scored: [(UUID, Float)] = []

        for itemId in itemIDs {
            guard let storedVector = embeddingService.load(for: itemId) else { continue }
            let similarity = cosineSimilarity(queryVector, storedVector)
            if similarity > 0.3 {
                scored.append((itemId, similarity))
            }
        }

        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
