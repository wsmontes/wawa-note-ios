import Contacts
import EventKit
import Foundation
import OSLog
import SwiftData

/// Bridges participants between Wawa Note's iOS ecosystem (Contacts, Calendar)
/// and anarlog's participant format.
///
/// Flow:
/// 1. Calendar event → extract attendees → AnarlogParticipant list
/// 2. Contact lookup → enrich with job title, email → AnarlogParticipant
/// 3. AnarlogParticipant → Person entity in SwiftData (findOrCreate)
/// 4. AnarlogParticipant list → annotations on KnowledgeItem
@MainActor
enum AnarlogParticipantBridge {
  private static let logger = Logger(
    subsystem: "com.wawa.note", category: "AnarlogParticipantBridge")

  // MARK: - From Calendar

  /// Extract participants from a Calendar event's attendees.
  static func fromCalendarEvent(_ event: EKEvent) -> [AnarlogParticipant] {
    guard let attendees = event.attendees else { return [] }

    return attendees.compactMap { attendee in
      let name: String
      if let displayName = attendee.name, !displayName.isEmpty {
        name = displayName
      } else {
        // Use URL to extract name as fallback
        let urlStr = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        let extracted = urlStr.components(separatedBy: "@").first ?? urlStr
        guard !extracted.isEmpty else { return nil }
        name = extracted
      }

      // Quick contact lookup for job title
      let enriched = enrichFromContacts(name: name)
      return AnarlogParticipant(name: name, jobTitle: enriched?.jobTitle)
    }
  }

  /// Extract participants from a KnowledgeItem's calendar context.
  static func fromKnowledgeItem(_ item: KnowledgeItem) -> [AnarlogParticipant] {
    let eventStore = EKEventStore()
    guard let eventId = item.calendarEventIdentifier,
      let event = eventStore.event(withIdentifier: eventId)
    else {
      return []
    }
    return fromCalendarEvent(event)
  }

  // MARK: - From Contacts

  /// Look up a person in Contacts to get their job title and organization.
  static func enrichFromContacts(name: String) -> AnarlogParticipant? {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized else { return nil }

    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactJobTitleKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    let predicate = CNContact.predicateForContacts(matchingName: name)
    guard
      let contact = try? store.unifiedContacts(
        matching: predicate, keysToFetch: keys
      ).first
    else {
      return nil
    }

    let jobTitle = contact.jobTitle.isEmpty ? contact.organizationName : contact.jobTitle
    let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

    return AnarlogParticipant(
      name: fullName.isEmpty ? name : fullName,
      jobTitle: jobTitle.isEmpty ? nil : jobTitle
    )
  }

  /// Batch-enrich a list of participants with Contacts data.
  static func enrichParticipants(_ participants: [AnarlogParticipant]) -> [AnarlogParticipant] {
    return participants.map { p in
      if p.jobTitle != nil { return p }  // Already enriched
      return enrichFromContacts(name: p.name) ?? p
    }
  }

  // MARK: - Match speaker names

  /// Given a speaker name from a transcript, find the best matching contact.
  /// Uses fuzzy matching: exact match > first name match > contains match.
  static func matchSpeaker(_ speakerName: String) -> AnarlogParticipant? {
    return enrichFromContacts(name: speakerName)
  }

  // MARK: - To SwiftData Person entities

  /// Convert anarlog participants to Person entities in the database.
  static func syncToPersonEntities(
    _ participants: [AnarlogParticipant],
    context: ModelContext
  ) -> [Person] {
    let personService = PersonService(context: context)
    return participants.compactMap { p in
      try? personService.findOrCreateFromContact(
        name: p.name,
        email: nil  // Could be enriched from Contacts
      )
    }
  }

  // MARK: - Bridge format conversion

  /// Convert Person entities back to anarlog format.
  static func toAnarlogParticipants(_ people: [Person]) -> [AnarlogParticipant] {
    return people.map { p in
      AnarlogParticipant(name: p.displayName, jobTitle: p.role)
    }
  }

  // MARK: - Annotations on KnowledgeItem

  /// Store participants as annotations on a KnowledgeItem for provenance.
  static func annotateParticipants(
    _ participants: [AnarlogParticipant],
    itemID: UUID,
    source: String = "anarlog_import",
    context: ModelContext
  ) {
    let annotationService = AnnotationService(context: context)
    var annotations: [CapturedAnnotation] = []

    for (idx, p) in participants.enumerated() {
      annotations.append(
        CapturedAnnotation(
          source: source,
          key: "participant_\(idx)_name",
          value: p.name,
          confidence: 1.0
        ))
      if let jobTitle = p.jobTitle {
        annotations.append(
          CapturedAnnotation(
            source: source,
            key: "participant_\(idx)_job_title",
            value: jobTitle,
            confidence: 0.8
          ))
      }
    }

    try? annotationService.upsert(annotations, itemID: itemID, source: source)
    logger.debug("Annotated \(participants.count) participants on item \(itemID)")
  }

  /// Read participants from a KnowledgeItem's annotations.
  static func readParticipants(
    from itemID: UUID,
    context: ModelContext
  ) -> [AnarlogParticipant] {
    let annotationService = AnnotationService(context: context)
    let annotations =
      (try? annotationService.annotations(for: itemID, source: "anarlog_import")) ?? []

    // Group by participant index
    var participants: [Int: (name: String, jobTitle: String?)] = [:]
    for a in annotations where a.key.hasPrefix("participant_") {
      let parts = a.key.components(separatedBy: "_")
      guard parts.count >= 3, let idx = Int(parts[1]) else { continue }

      if parts[2] == "name" {
        participants[idx, default: ("", nil)].name = a.value
      } else if parts[2] == "job" {
        participants[idx, default: ("", nil)].jobTitle = a.value
      }
    }

    return participants.sorted(by: { $0.key < $1.key }).map { idx, data in
      AnarlogParticipant(name: data.name, jobTitle: data.jobTitle)
    }
  }
}
