import Foundation
import SwiftData

@MainActor
final class KnowledgeItemService {
    private let context: ModelContext
    private let fileStore: FileArtifactStore

    init(context: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.context = context
        self.fileStore = fileStore
    }

    func createItem(
        type: KnowledgeItemType,
        title: String,
        folderID: UUID? = nil,
        durationSeconds: Double? = nil,
        languageCode: String? = nil,
        tags: [String] = []
    ) throws -> KnowledgeItem {
        let item = KnowledgeItem(
            type: type,
            title: title,
            status: type == .meeting ? .recording : .draft,
            tags: tags,
            folderID: folderID,
            durationSeconds: durationSeconds,
            languageCode: languageCode
        )
        context.insert(item)
        try context.save()
        return item
    }

    func fetchItem(id: UUID) throws -> KnowledgeItem? {
        var descriptor = FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func allItems() throws -> [KnowledgeItem] {
        var descriptor = FetchDescriptor<KnowledgeItem>()
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func items(ofType type: KnowledgeItemType) throws -> [KnowledgeItem] {
        let typeRaw = type.rawValue
        var descriptor = FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func recentItems(limit: Int = 20) throws -> [KnowledgeItem] {
        var descriptor = FetchDescriptor<KnowledgeItem>()
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func deleteItem(_ item: KnowledgeItem) throws {
        // Cascade: delete annotations
        let itemId = item.id
        let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { $0.itemID == itemId })
        if let anns = try? context.fetch(annPred) {
            for ann in anns { context.delete(ann) }
        }
        try fileStore.deleteMeetingDirectory(for: item.id)
        context.delete(item)
        try context.save()
    }

    func updateItem(_ item: KnowledgeItem) throws {
        item.updatedAt = Date()
        try context.save()
    }
}
