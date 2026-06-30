import Contacts
import Foundation
import SwiftData

// Related JIRA: KAN-8, KAN-29, KAN-40

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

    func findOrCreateFromContact(name: String, email: String? = nil) throws -> Person {
        let enriched = enrichFromContacts(name: name)
        return try findOrCreate(
            displayName: name,
            email: email ?? enriched.email,
            role: enriched.organization
        )
    }

    private func enrichFromContacts(name: String) -> (email: String?, organization: String?) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return (nil, nil) }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        guard let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first else {
            return (nil, nil)
        }
        return (
            email: contact.emailAddresses.first?.value as String?,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName
        )
    }
}
