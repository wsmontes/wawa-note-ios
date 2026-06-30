import Foundation
import SwiftData

// Related JIRA: KAN-11, KAN-55

@Model
final class Annotation {
    @Attribute(.unique) var id: UUID
    var source: String
    var key: String
    var value: String
    var itemID: UUID
    var createdAt: Date
    var confidence: Double?

    init(
        id: UUID = UUID(),
        source: String,
        key: String,
        value: String,
        itemID: UUID,
        createdAt: Date = Date(),
        confidence: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.value = value
        self.itemID = itemID
        self.createdAt = createdAt
        self.confidence = confidence
    }
}
