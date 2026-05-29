import SwiftUI
import Foundation
import SwiftData

enum KnowledgeItemType: String, Codable, CaseIterable, Hashable {
    case meeting
    case note
    case journalEntry
    case webBookmark
    case image
}

// MARK: - Display helpers

extension KnowledgeItemType {
    var icon: String {
        switch self {
        case .meeting: "recordingtape"
        case .note: "note.text"
        case .journalEntry: "book"
        case .webBookmark: "bookmark"
        case .image: "photo"
        }
    }

    var color: Color {
        switch self {
        case .meeting: .blue
        case .note: .orange
        case .journalEntry: .purple
        case .webBookmark: .green
        case .image: .pink
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
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var calendarEventIdentifier: String?
    var scheduledDate: Date?
    var isImported: Bool = false
    var importSourceURL: String?

    var type: KnowledgeItemType {
        get { KnowledgeItemType(rawValue: typeRaw) ?? .meeting }
        set { typeRaw = newValue.rawValue }
    }

    var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: KnowledgeItemType = .meeting,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: MeetingStatus = .draft,
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
    }
}
