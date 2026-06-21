import Foundation

// MARK: - ProjectUpdateFields

/// Batch of optional field changes for a project update.
/// Only non-nil fields are applied. Nil fields are skipped.
struct ProjectUpdateFields: Sendable {
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
