import Foundation
import SwiftData

struct ToolContext: @unchecked Sendable {
    let modelContext: ModelContext
    let fileStore: FileArtifactStore
    var activeProjectID: UUID?
    var activeProjectName: String?
    var activeItemID: UUID?
    var contextKey: String?
    var contextDisplayName: String?

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore(),
         activeProjectID: UUID? = nil, activeProjectName: String? = nil,
         activeItemID: UUID? = nil, contextKey: String? = nil, contextDisplayName: String? = nil) {
        self.modelContext = modelContext
        self.fileStore = fileStore
        self.activeProjectID = activeProjectID
        self.activeProjectName = activeProjectName
        self.activeItemID = activeItemID
        self.contextKey = contextKey
        self.contextDisplayName = contextDisplayName
    }
}
