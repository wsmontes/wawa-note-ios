import Foundation
import SwiftData

// MARK: - SuggestionType

enum SuggestionType: String, Codable, CaseIterable, Sendable {
    case summaryUpdate
    case taskCreate
    case riskAlert
    case connectionProposal
    case projectCreation
}

// MARK: - SuggestionStatus

enum SuggestionStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case dismissed
}

// MARK: - ProjectSuggestion

@Model
final class ProjectSuggestion {
    var id: UUID
    var projectID: UUID
    var title: String
    var body: String
    var suggestionTypeRaw: String
    var proposedFieldsJSON: String?
    var statusRaw: String
    var createdAt: Date
    var resolvedAt: Date?

    var suggestionType: SuggestionType {
        get { SuggestionType(rawValue: suggestionTypeRaw) ?? .summaryUpdate }
        set { suggestionTypeRaw = newValue.rawValue }
    }

    var status: SuggestionStatus {
        get { SuggestionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        projectID: UUID,
        title: String,
        body: String,
        suggestionType: SuggestionType,
        proposedFields: ProjectUpdateFields? = nil,
        status: SuggestionStatus = .pending,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.projectID = projectID
        self.title = title
        self.body = body
        self.suggestionTypeRaw = suggestionType.rawValue
        self.proposedFieldsJSON = proposedFields.flatMap { fields in
            guard let data = try? JSONEncoder().encode(fields) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
    }
}
