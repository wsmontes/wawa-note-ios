import Foundation
import SwiftData

enum ItemStatus: String, Codable, CaseIterable {
    case draft
    case recording
    case recorded
    case transcribing
    case transcribed
    /// Extraction/transcription is complete but user hasn't reviewed yet.
    /// Pipeline pauses here — user must approve before analysis proceeds.
    case pendingReview
    case analyzing
    case analyzed
    case failed
    case archived
}

enum KnowledgeItemType: String, Codable, CaseIterable, Hashable {
    case audio = "audio"
    case note
    case journalEntry
    case webBookmark
    case image
}

// MARK: - Display helpers

extension KnowledgeItemType {
    var icon: String {
        switch self {
        case .audio: "recordingtape"
        case .note: "note.text"
        case .journalEntry: "book"
        case .webBookmark: "bookmark"
        case .image: "photo"
        }
    }

    var label: String { rawValue.capitalized }
}

@Model
final class KnowledgeItem {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var statusRaw: String
    var tags: [String]

    // Cross-type queryable columns
    var durationSeconds: Double?
    var languageCode: String?
    var folderID: UUID?
    var projectID: UUID?
    var isFlagged: Bool

    // Content body (Markdown for notes, journal entries)
    var bodyText: String?

    // Inbox — non-nil means item is waiting to be processed
    var inboxDate: Date?

    // Context columns
    var contextCalendarEventTitle: String?
    var contextAudioRoute: String?
    var contextPlaceName: String?
    var contextLatitude: Double?
    var contextLongitude: Double?
    var contextFocusActive: Bool?
    var contextMotionActivity: String?
    var contextBatteryLevel: Double?

    // Legacy meeting fields
    var audioFileRelativePath: String?
    var imageFileRelativePath: String?
    var imagePageCount: Int?
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var calendarEventIdentifier: String?
    var scheduledDate: Date?
    var isImported: Bool = false
    var importSourceURL: String?
    // Field authority
    var fieldProvenanceJSON: String?
    // Anarlog compatibility: preserves original YAML frontmatter for round-trip fidelity
    var anarlogFrontmatterJSON: String?

    var type: KnowledgeItemType {
        get {
            // Migration: "meeting" was renamed to "audio"
            if typeRaw == "meeting" { return .audio }
            return KnowledgeItemType(rawValue: typeRaw) ?? .audio
        }
        set { typeRaw = newValue.rawValue }
    }

    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: KnowledgeItemType = .audio,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ItemStatus = .draft,
        tags: [String] = [],
        folderID: UUID? = nil,
        isFlagged: Bool = false,
        bodyText: String? = nil,
        durationSeconds: Double? = nil,
        languageCode: String? = nil,
        inboxDate: Date? = Date()
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRaw = status.rawValue
        self.tags = tags
        self.folderID = folderID
        self.projectID = nil
        self.isFlagged = isFlagged
        self.bodyText = bodyText
        self.durationSeconds = durationSeconds
        self.languageCode = languageCode
        self.inboxDate = inboxDate
        self.fieldProvenanceJSON = nil
    }
}

// MARK: - KnowledgeItem + FieldProvidence

extension KnowledgeItem: FieldProvidence {
    var provenance: FieldProvenance {
        get { FieldProvenance.decode(from: fieldProvenanceJSON) }
        set { fieldProvenanceJSON = newValue.encode() }
    }

    func writeProvenance() {
        fieldProvenanceJSON = provenance.encode()
    }
}
