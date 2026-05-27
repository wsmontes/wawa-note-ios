import Foundation

struct JSONExporter: Sendable {

    func export(
        item: KnowledgeItem,
        transcript: Transcript?,
        analysis: MeetingAnalysis?
    ) throws -> Data {
        let export = KnowledgeItemExport(
            version: "2.0",
            schema: "wawa-note/knowledge-item/v1",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            item: KnowledgeItemExport.ItemSummary(
                id: item.id.uuidString,
                type: item.type.rawValue,
                title: item.title,
                createdAt: ISO8601DateFormatter().string(from: item.createdAt),
                durationSeconds: item.durationSeconds,
                languageCode: item.languageCode,
                tags: item.tags,
                status: item.status.rawValue
            ),
            transcript: transcript,
            analysis: analysis
        )
        return try JSONEncoder().encode(export)
    }

}

// MARK: - KnowledgeItem export format (v2)

struct KnowledgeItemExport: Encodable {
    let version: String
    let schema: String
    let exportedAt: String
    let item: ItemSummary
    let transcript: Transcript?
    let analysis: MeetingAnalysis?

    struct ItemSummary: Encodable {
        let id: String
        let type: String
        let title: String
        let createdAt: String
        let durationSeconds: Double?
        let languageCode: String?
        let tags: [String]
        let status: String
    }
}