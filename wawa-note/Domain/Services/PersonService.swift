import Foundation
import SwiftData

@MainActor
final class PersonService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func findOrCreate(displayName: String, email: String? = nil, role: String? = nil) throws -> Person {
        let key = displayName.lowercased().trimmingCharacters(in: .whitespaces)
        var descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.canonicalKey == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            if let email { existing.email = email }
            if let role { existing.role = role }
            try context.save()
            return existing
        }
        let person = Person(displayName: displayName, email: email, role: role)
        context.insert(person)
        try context.save()
        return person
    }

    func fetch(id: UUID) throws -> Person? {
        var descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func all() throws -> [Person] {
        var descriptor = FetchDescriptor<Person>()
        descriptor.sortBy = [SortDescriptor(\.displayName)]
        return try context.fetch(descriptor)
    }

    func search(_ query: String) throws -> [Person] {
        let q = query.lowercased()
        let all = try self.all()
        return all.filter { $0.displayName.lowercased().contains(q) || ($0.email?.lowercased().contains(q) ?? false) }
    }
}
