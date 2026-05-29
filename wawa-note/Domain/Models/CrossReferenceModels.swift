import Foundation

struct CrossReferenceResult: Codable, Sendable {
    let answer: String
    let connections: [Connection]
    let insights: [Insight]
    let contradictions: [Contradiction]

    struct Connection: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        let fromItemId: UUID
        let toItemId: UUID
        let relationship: String
        let explanation: String
        let strength: Double
        enum CodingKeys: String, CodingKey {
            case fromItemId = "from_item_id"
            case toItemId = "to_item_id"
            case relationship, explanation, strength
        }
    }

    struct Insight: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        let text: String
        let sourceItemIds: [UUID]
        let confidence: Double
        enum CodingKeys: String, CodingKey {
            case sourceItemIds = "source_item_ids"
            case text, confidence
        }
    }

    struct Contradiction: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        let description: String
        let itemAId: UUID
        let itemBId: UUID
        let resolution: String?
        enum CodingKeys: String, CodingKey {
            case itemAId = "item_a_id"
            case itemBId = "item_b_id"
            case description, resolution
        }
    }
}
