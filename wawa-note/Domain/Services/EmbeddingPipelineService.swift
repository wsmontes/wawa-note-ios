import Foundation
import SwiftData
import OSLog

@MainActor
final class EmbeddingPipelineService {
    private let embeddingService: EmbeddingService
    private let fileStore: FileArtifactStore

    init(embeddingService: EmbeddingService = EmbeddingService(),
         fileStore: FileArtifactStore = FileArtifactStore()) {
        self.embeddingService = embeddingService
        self.fileStore = fileStore
    }

    /// Generate embedding for a knowledge item if one doesn't exist.
    /// Builds content from: transcript + analysis summary + body text.
    func ensureEmbedding(for item: KnowledgeItem, using provider: any AIProvider) async {
        guard !embeddingService.hasEmbedding(for: item.id) else { return }

        let content = buildContent(for: item)
        guard !content.isEmpty else {
            AppLog.general.info("No content to embed for item \(item.id)")
            return
        }

        do {
            _ = try await embeddingService.generateAndStore(for: item.id, text: content, using: provider)
            AppLog.general.info("Embedding generated for item \(item.id)")
        } catch {
            AppLog.general.error("Failed to generate embedding for \(item.id): \(error)")
        }
    }

    /// Backfill embeddings for all items that don't have one.
    func backfillAll(items: [KnowledgeItem], using provider: any AIProvider, onProgress: ((Int, Int) -> Void)? = nil) async {
        let missing = items.filter { !embeddingService.hasEmbedding(for: $0.id) }
        guard !missing.isEmpty else { return }

        AppLog.general.info("Backfilling embeddings for \(missing.count) items")

        for (idx, item) in missing.enumerated() {
            await ensureEmbedding(for: item, using: provider)
            onProgress?(idx + 1, missing.count)
        }
    }

    /// Count of items without embeddings
    func missingEmbeddingCount(items: [KnowledgeItem]) -> Int {
        items.filter { !embeddingService.hasEmbedding(for: $0.id) }.count
    }

    // MARK: - Content assembly

    private func buildContent(for item: KnowledgeItem) -> String {
        var parts: [String] = []

        if !item.title.isEmpty {
            parts.append(item.title)
        }

        if let body = item.bodyText, !body.isEmpty {
            parts.append(body)
        }

        // Transcript excerpt
        if let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
            let text = transcript.segments.prefix(30).map(\.text).joined(separator: " ")
            if !text.isEmpty { parts.append(text) }
        }

        // Analysis summary
        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            if !analysis.shortSummary.isEmpty { parts.append(analysis.shortSummary) }
            if !analysis.actionItems.isEmpty {
                parts.append(analysis.actionItems.map(\.task).joined(separator: "; "))
            }
            if !analysis.decisions.isEmpty {
                parts.append(analysis.decisions.map(\.title).joined(separator: "; "))
            }
        }

        return parts.joined(separator: "\n")
    }
}
