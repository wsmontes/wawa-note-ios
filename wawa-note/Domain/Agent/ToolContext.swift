import Foundation
import SwiftData

/// Mutable context passed to every tool execution.
/// Reference type so that `cd` mutations persist across iterations of the agent loop.
final class ToolContext: @unchecked Sendable {
    let modelContext: ModelContext
    let fileStore: FileArtifactStore
    var activeProjectID: UUID?
    var activeProjectName: String?
    var activeProjectSlug: String?
    var activeItemID: UUID?
    var contextKey: String?
    var contextDisplayName: String?
    var activeProjectColorHex: String?
    var projectColorHexes: [UUID: String] = [:]

    func projectColorHex(for projectID: UUID) -> String? {
        projectColorHexes[projectID]
    }

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore(),
         activeProjectID: UUID? = nil, activeProjectName: String? = nil,
         activeProjectSlug: String? = nil,
         activeItemID: UUID? = nil, contextKey: String? = nil, contextDisplayName: String? = nil,
         activeProjectColorHex: String? = nil, projectColorHexes: [UUID: String] = [:]) {
        self.modelContext = modelContext
        self.fileStore = fileStore
        self.activeProjectID = activeProjectID
        self.activeProjectName = activeProjectName
        self.activeProjectSlug = activeProjectSlug
        self.activeItemID = activeItemID
        self.contextKey = contextKey
        self.contextDisplayName = contextDisplayName
        self.activeProjectColorHex = activeProjectColorHex
        self.projectColorHexes = projectColorHexes
    }
}
