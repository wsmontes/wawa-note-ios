import Foundation
import SwiftData

@MainActor
final class TrashService {
    private let context: ModelContext
    private let fileStore: FileArtifactStore
    private let knowledgeService: KnowledgeItemService

    init(context: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.context = context
        self.fileStore = fileStore
        self.knowledgeService = KnowledgeItemService(context: context, fileStore: fileStore)
    }

    /// Returns the Trash folder, creating it if needed.
    /// Always sorts last with a high sortOrder.
    func trashFolder() throws -> Folder {
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.isTrashFolder == true })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        // Place trash at the very end
        let allFolders = try context.fetch(FetchDescriptor<Folder>())
        let maxOrder = allFolders.map(\.sortOrder).max() ?? 0

        let trash = Folder(name: "Trash", parentFolderID: nil, sortOrder: maxOrder + 1000, iconName: "trash", isTrashFolder: true)
        context.insert(trash)
        try context.save()
        return trash
    }

    func isTrash(_ folder: Folder) -> Bool {
        folder.isTrashFolder
    }

    func isItemInTrash(_ item: KnowledgeItem) -> Bool {
        guard let folderID = item.folderID else { return false }
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })
        descriptor.fetchLimit = 1
        guard let folder = try? context.fetch(descriptor).first else { return false }
        return isTrash(folder)
    }

    func moveToTrash(_ item: KnowledgeItem) throws {
        let trash = try trashFolder()
        item.folderID = trash.id
        item.updatedAt = Date()
        try context.save()
    }

    func restore(_ item: KnowledgeItem) throws {
        item.folderID = nil
        item.updatedAt = Date()
        try context.save()
    }

    func itemsInTrash() throws -> [KnowledgeItem] {
        let trash = try trashFolder()
        let trashID: UUID? = trash.id
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.folderID == trashID })
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func deleteAllInTrash() throws {
        let items = try itemsInTrash()
        for item in items {
            try knowledgeService.deleteItem(item)
        }
    }

    func emptyTrashItemCount() -> Int {
        (try? itemsInTrash().count) ?? 0
    }
}
