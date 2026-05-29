import Foundation
import SwiftData

struct ToolContext: @unchecked Sendable {
    let modelContext: ModelContext
    let fileStore: FileArtifactStore

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.modelContext = modelContext
        self.fileStore = fileStore
    }
}
