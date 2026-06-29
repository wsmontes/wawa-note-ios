import Foundation
import SwiftData

@MainActor
final class AnnotationService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func upsert(_ annotations: [CapturedAnnotation], itemID: UUID, source: String) throws {
        let existing = try context.fetch(
            FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.itemID == itemID && $0.source == source }
            )
        )
        for ann in existing { context.delete(ann) }
        for cap in annotations {
            context.insert(
                Annotation(
                    source: cap.source,
                    key: cap.key,
                    value: cap.value,
                    itemID: itemID,
                    confidence: cap.confidence
                ))
        }
        try context.save()
    }

    func annotations(for itemID: UUID) throws -> [Annotation] {
        try context.fetch(
            FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.itemID == itemID }
            )
        )
    }

    func annotations(for itemID: UUID, source: String) throws -> [Annotation] {
        try context.fetch(
            FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.itemID == itemID && $0.source == source }
            )
        )
    }

    func itemsWithKeyValue(key: String, value: String) throws -> [UUID] {
        let anns = try context.fetch(
            FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.key == key && $0.value == value }
            )
        )
        return Array(Set(anns.map(\.itemID)))
    }

    func compoundQuery(conditions: [(key: String, value: String)]) throws -> [UUID] {
        var resultIDs: Set<UUID>?
        for condition in conditions {
            let ids = try itemsWithKeyValue(key: condition.key, value: condition.value)
            if resultIDs == nil {
                resultIDs = Set(ids)
            } else {
                resultIDs = resultIDs?.intersection(ids)
            }
            if resultIDs?.isEmpty == true { break }
        }
        return Array(resultIDs ?? [])
    }

    func deleteAll(for itemID: UUID) throws {
        let existing = try annotations(for: itemID)
        for ann in existing { context.delete(ann) }
        try context.save()
    }
}
