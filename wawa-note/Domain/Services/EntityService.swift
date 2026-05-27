import Foundation
import SwiftData

@MainActor
final class EntityService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func findOrCreate(kind: EntityKind, displayName: String) throws -> Entity {
        let key = "\(kind.rawValue):\(displayName.lowercased().trimmingCharacters(in: .whitespaces))"
        var descriptor = FetchDescriptor<Entity>(predicate: #Predicate { $0.canonicalKey == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let entity = Entity(kind: kind, displayName: displayName, canonicalKey: key)
        context.insert(entity)
        try context.save()
        return entity
    }

    func fetch(id: UUID) throws -> Entity? {
        var descriptor = FetchDescriptor<Entity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func all(kind: EntityKind? = nil) throws -> [Entity] {
        var descriptor: FetchDescriptor<Entity>
        if let kind {
            let raw = kind.rawValue
            descriptor = FetchDescriptor<Entity>(predicate: #Predicate { $0.kindRaw == raw })
        } else {
            descriptor = FetchDescriptor<Entity>()
        }
        descriptor.sortBy = [SortDescriptor(\.displayName)]
        return try context.fetch(descriptor)
    }

    func search(_ query: String) throws -> [Entity] {
        let q = query.lowercased()
        let allEntities = try self.all()
        return allEntities.filter { $0.displayName.lowercased().contains(q) }
    }
}
