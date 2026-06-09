import Foundation
import OSLog

// MARK: - Embedding Container (versioned)

struct EmbeddingContainer: Codable {
    let version: Int
    let model: String
    let dimensions: Int
    let createdAt: Date
    let vector: [Float]
}

// MARK: - Embedding Service

final class EmbeddingService: @unchecked Sendable {
    private let fileStore: FileArtifactStore
    private let embeddingModel: String
    private let currentVersion = 1

    init(fileStore: FileArtifactStore = FileArtifactStore(), embeddingModel: String = "text-embedding-3-small") {
        self.fileStore = fileStore
        self.embeddingModel = embeddingModel
    }

    func embeddingURL(for itemId: UUID) -> URL {
        fileStore.itemDirectoryURL(for: itemId).appendingPathComponent("embedding.json")
    }

    func generateAndStore(for itemId: UUID, text: String, using provider: any AIProvider) async throws -> [Float] {
        let vector = try await provider.embed(text, model: embeddingModel)
        let container = EmbeddingContainer(
            version: self.currentVersion,
            model: self.embeddingModel,
            dimensions: vector.count,
            createdAt: Date(),
            vector: vector
        )
        let data = try JSONEncoder().encode(container)
        try fileStore.createMeetingDirectory(for: itemId)
        try data.write(to: embeddingURL(for: itemId), options: .atomic)
        let v = self.currentVersion; let m = self.embeddingModel
        AppLog.general.info("Embedding stored for item \(itemId): \(vector.count) dims (v\(v), model=\(m))")
        return vector
    }

    func load(for itemId: UUID) -> [Float]? {
        let url = embeddingURL(for: itemId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Try new format first, fall back to legacy plain array
        if let container = try? JSONDecoder().decode(EmbeddingContainer.self, from: data) {
            if container.model != self.embeddingModel {
                let m = self.embeddingModel
                AppLog.general.info("Embedding model mismatch for \(itemId): stored=\(container.model), current=\(m) — invalidating")
                return nil
            }
            return container.vector
        }
        // Legacy format: plain [Float] — invalidate on model change
        if let vector = try? JSONDecoder().decode([Float].self, from: data) {
            AppLog.general.info("Legacy embedding for \(itemId) — will be regenerated")
            return nil
        }
        return nil
    }

    func hasEmbedding(for itemId: UUID) -> Bool {
        guard FileManager.default.fileExists(atPath: embeddingURL(for: itemId).path) else { return false }
        // Validate it's current format
        return load(for: itemId) != nil
    }
}
