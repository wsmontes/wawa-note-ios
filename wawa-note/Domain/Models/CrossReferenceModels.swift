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
    }

    struct Insight: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        let text: String
        let sourceItemIds: [UUID]
        let confidence: Double
    }

    struct Contradiction: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        let description: String
        let itemAId: UUID
        let itemBId: UUID
        let resolution: String?
    }
}
