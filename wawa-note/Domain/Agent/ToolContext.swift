import Foundation
import SwiftData

/// Mutable context passed to every tool execution.
/// Reference type so that `cd` mutations persist across iterations of the agent loop.
///
/// All mutations are @MainActor-isolated. AgentLoop reads ToolContext via read-only
/// snapshotting (it does not mutate). ShellInterpreter and ChatViewModel are both
/// @MainActor-isolated and are the only mutators.
@MainActor
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

    /// When set, the agent is sandboxed to this item's folder.
    /// Commands (ls, find, grep, cat, touch, echo) are restricted to the
    /// item's own directory. Cross-item access is blocked.
    /// Nil = no sandbox (chat mode, project-level analysis).
    var sandboxedItemID: UUID?

    /// The project's framework for schema validation during write_analysis.
    /// When set, WriteAnalysisTool validates output against this schema and
    /// returns specific fix instructions to the agent on mismatch.
    var activeFramework: ProjectFramework?

    // Planning & agent iteration tracking
    var isPlanning: Bool = false
    var planTaskIDs: [UUID] = []
    var planCreatedAt: Date?

    func projectColorHex(for projectID: UUID) -> String? {
        projectColorHexes[projectID]
    }

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore(),
         activeProjectID: UUID? = nil, activeProjectName: String? = nil,
         activeProjectSlug: String? = nil,
         activeItemID: UUID? = nil, contextKey: String? = nil, contextDisplayName: String? = nil,
         activeProjectColorHex: String? = nil, projectColorHexes: [UUID: String] = [:],
         sandboxedItemID: UUID? = nil, activeFramework: ProjectFramework? = nil) {
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
        self.sandboxedItemID = sandboxedItemID
        self.activeFramework = activeFramework
    }
}
