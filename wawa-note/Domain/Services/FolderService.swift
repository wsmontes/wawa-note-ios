import Foundation
import SwiftData

@MainActor
final class FolderService {
    private let context: ModelContext
    private let fileStore: FileArtifactStore

    init(context: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.context = context
        self.fileStore = fileStore
    }

    func childFolders(of parentID: UUID?) throws -> [Folder] {
        let predicate: Predicate<Folder>?
        if let parentID {
            predicate = #Predicate { $0.parentFolderID == parentID }
        } else {
            predicate = #Predicate { $0.parentFolderID == nil }
        }
        var descriptor = FetchDescriptor<Folder>(predicate: predicate!)
        descriptor.sortBy = [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        return try context.fetch(descriptor)
    }

    func items(in folderID: UUID?) throws -> [KnowledgeItem] {
        let predicate: Predicate<KnowledgeItem>?
        if let folderID {
            predicate = #Predicate { $0.folderID == folderID }
        } else {
            predicate = #Predicate { $0.folderID == nil }
        }
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: predicate!)
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func allFolders() throws -> [Folder] {
        try context.fetch(FetchDescriptor<Folder>())
    }

    func createFolder(name: String, parentID: UUID? = nil, iconName: String? = nil) throws -> Folder {
        let count = try childFolders(of: parentID).count
        let folder = Folder(name: name, parentFolderID: parentID, sortOrder: count, iconName: iconName)
        context.insert(folder)
        try context.save()
        return folder
    }

    func deleteFolder(_ folder: Folder) throws {
        // Recursively delete child folders
        let children = try childFolders(of: folder.id)
        for child in children {
            try deleteFolder(child)
        }
        // Delete items in this folder
        let folderItems = try items(in: folder.id)
        for item in folderItems {
            // Cascade: delete annotations for this item
            let itemId = item.id
            let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { $0.itemID == itemId })
            if let anns = try? context.fetch(annPred) {
                for ann in anns { context.delete(ann) }
            }
            try fileStore.deleteMeetingDirectory(for: item.id)
            context.delete(item)
        }
        context.delete(folder)
        try context.save()
    }
}
