import Foundation
import SwiftData

struct ToolContext: @unchecked Sendable {
    let modelContext: ModelContext
    let fileStore: FileArtifactStore
    var activeProjectID: UUID?
    var activeProjectName: String?

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore(),
         activeProjectID: UUID? = nil, activeProjectName: String? = nil) {
        self.modelContext = modelContext
        self.fileStore = fileStore
        self.activeProjectID = activeProjectID
        self.activeProjectName = activeProjectName
    }
}
