import Foundation
import EventKit
import Contacts
import CoreLocation
import SwiftData

// MARK: - Device Context Enrichment

enum DeviceEnrichment {
    case calendarEvent(CalendarMatch)
    case contact(ContactMatch)
    case location(String) // Location name
}

struct CalendarMatch {
    let eventID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let attendees: [String]
    let location: String?
}

struct ContactMatch {
    let contactID: String
    let displayName: String
    let email: String?
    let phone: String?
    let organization: String?
    let hasRecentCalls: Bool
}

@MainActor
final class DeviceContextService {
    private let eventStore: EKEventStore
    private let contactStore = CNContactStore()
    private let fileStore = FileArtifactStore()

    init(eventStore: EKEventStore = .shared) {
        self.eventStore = eventStore
    }

    /// Cross-references an item with device context sources.
    /// Returns enrichments for calendar events, contacts, and location.
    func crossReference(item: KnowledgeItem) async -> [DeviceEnrichment] {
        var enrichments: [DeviceEnrichment] = []

        // 1. Calendar matching by date/time
        if let calMatch = await matchCalendarEvent(item: item) {
            enrichments.append(.calendarEvent(calMatch))
        }

        // 2. Contact matching from transcript/analysis text
        let contactMatches = await matchContacts(from: item)
        enrichments.append(contentsOf: contactMatches.map { .contact($0) })

        // 3. Location matching (passive from context sensors)
        if let location = await matchLocation(item: item) {
            enrichments.append(.location(location))
        }

        return enrichments
    }

    // MARK: - Calendar matching

    private func matchCalendarEvent(item: KnowledgeItem) async -> CalendarMatch? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .writeOnly else { return nil }

        let itemDate = item.createdAt
        let windowStart = itemDate.addingTimeInterval(-3600) // 1h before
        let windowEnd = itemDate.addingTimeInterval(3600)    // 1h after

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        // Find closest event by time proximity
        guard let closest = events.min(by: { abs($0.startDate.timeIntervalSince(itemDate)) < abs($1.startDate.timeIntervalSince(itemDate)) }),
              abs(closest.startDate.timeIntervalSince(itemDate)) < 1800 // Within 30 min
        else { return nil }

        let attendees = (closest.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString }

        return CalendarMatch(
            eventID: closest.eventIdentifier,
            title: closest.title,
            startDate: closest.startDate,
            endDate: closest.endDate,
            attendees: attendees,
            location: closest.location
        )
    }

    // MARK: - Contact matching

    private func matchContacts(from item: KnowledgeItem) async -> [ContactMatch] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return [] }

        // Build search text from item title, body text, and transcript (if available)
        var searchText = item.title
        if let body = item.bodyText, !body.isEmpty {
            searchText += " " + body
        }
        if let transcript = try? fileStore.readArtifact(
            Transcript.self,
            fileName: AppFileConstants.transcriptFileName,
            meetingId: item.id
        ) {
            let transcriptText = transcript.segments.map { $0.text }.joined(separator: " ")
            searchText += " " + transcriptText
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var matches: [ContactMatch] = []

        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                guard !fullName.isEmpty else { return }
                // Check if contact name appears in item content
                if searchText.localizedCaseInsensitiveContains(contact.givenName) ||
                   searchText.localizedCaseInsensitiveContains(contact.familyName) ||
                   searchText.localizedCaseInsensitiveContains(fullName) {
                    matches.append(ContactMatch(
                        contactID: contact.identifier,
                        displayName: fullName,
                        email: contact.emailAddresses.first?.value as String?,
                        phone: contact.phoneNumbers.first?.value.stringValue,
                        organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                        hasRecentCalls: false // Call history requires CallKit, deferred
                    ))
                }
            }
        } catch {
            AppLog.general.error("DeviceContext: contact search failed: \(error)")
        }

        return matches
    }

    // MARK: - Location matching

    private func matchLocation(item: KnowledgeItem) async -> String? {
        // Location context is captured by context sensors during recording.
        // Check if item has associated location metadata in its context fields.
        if let placeName = item.contextPlaceName, !placeName.isEmpty {
            return placeName
        }
        return nil
    }
}

// MARK: - Person resolution helper

/// Ensures a Person record exists in SwiftData for a matched contact.
/// Returns the Person's UUID (existing or newly created).
func ensurePersonExists(_ contact: ContactMatch, context: ModelContext) throws -> UUID {
    let key = contact.displayName.lowercased().trimmingCharacters(in: .whitespaces)
    var descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.canonicalKey == key })
    descriptor.fetchLimit = 1

    if let existing = try context.fetch(descriptor).first {
        return existing.id
    }

    let person = Person(
        displayName: contact.displayName,
        canonicalKey: key,
        email: contact.email,
        role: contact.organization
    )
    context.insert(person)
    try context.save()
    return person.id
}
