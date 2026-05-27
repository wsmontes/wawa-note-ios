import Foundation
import OSLog

final class EmbeddingService: @unchecked Sendable {
    private let fileStore: FileArtifactStore
    private let embeddingModel: String

    init(fileStore: FileArtifactStore = FileArtifactStore(), embeddingModel: String = "text-embedding-3-small") {
        self.fileStore = fileStore
        self.embeddingModel = embeddingModel
    }

    func embeddingURL(for itemId: UUID) -> URL {
        fileStore.itemDirectoryURL(for: itemId).appendingPathComponent("embedding.json")
    }

    func generateAndStore(for itemId: UUID, text: String, using provider: any AIProvider) async throws -> [Float] {
        let vector = try await provider.embed(text, model: embeddingModel)
        let data = try JSONEncoder().encode(vector)
        try fileStore.createMeetingDirectory(for: itemId)
        try data.write(to: embeddingURL(for: itemId), options: .atomic)
        AppLog.general.info("Embedding stored for item \(itemId): \(vector.count) dims")
        return vector
    }

    func load(for itemId: UUID) -> [Float]? {
        let url = embeddingURL(for: itemId)
        guard let data = try? Data(contentsOf: url),
              let vector = try? JSONDecoder().decode([Float].self, from: data) else { return nil }
        return vector
    }

    func hasEmbedding(for itemId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: embeddingURL(for: itemId).path)
    }
}
