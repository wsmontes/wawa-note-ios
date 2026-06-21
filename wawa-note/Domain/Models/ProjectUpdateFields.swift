import Foundation

// MARK: - ProjectUpdateFields

/// Batch of optional field changes for a project update.
/// Only non-nil fields are applied. Nil fields are skipped.
struct ProjectUpdateFields: Codable, Sendable {
    var name: String?
    var summary: String?
    var intention: String?
    var customInstructions: String?
    var colorHex: String?
    var iconName: String?
    var status: ProjectStatus?
    var frameworkId: String?
    var holdIngestionForDoubts: Bool?

    /// Returns true if at least one field is non-nil.
    var hasChanges: Bool {
        name != nil || summary != nil || intention != nil ||
        customInstructions != nil || colorHex != nil || iconName != nil ||
        status != nil || frameworkId != nil || holdIngestionForDoubts != nil
    }
}

// MARK: - ProjectTemplate

/// Lightweight template — maps to a built-in ProjectFramework.
enum ProjectTemplate: String, CaseIterable, Sendable {
    case meeting
    case research
    case brainstorm
    case journal
    case coaching
    case legal
    case product
    case blank

    var frameworkId: String { "builtin/\(rawValue)" }

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .research: return "Research"
        case .brainstorm: return "Brainstorm"
        case .journal: return "Journal"
        case .coaching: return "Coaching"
        case .legal: return "Legal"
        case .product: return "Product"
        case .blank: return "Blank (no preset)"
        }
    }
}
