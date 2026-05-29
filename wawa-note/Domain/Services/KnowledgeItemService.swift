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
        bodyText: String? = nil,
        folderID: UUID? = nil,
        durationSeconds: Double? = nil,
        languageCode: String? = nil,
        tags: [String] = [],
        inboxDate: Date? = Date()
    ) throws -> KnowledgeItem {
        let item = KnowledgeItem(
            type: type,
            title: title,
            status: type == .meeting ? .recording : .draft,
            tags: tags,
            folderID: folderID,
            bodyText: bodyText,
            durationSeconds: durationSeconds,
            languageCode: languageCode,
            inboxDate: inboxDate
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
        let itemId = item.id
        let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { $0.itemID == itemId })
        if let anns = try? context.fetch(annPred) {
            for ann in anns { context.delete(ann) }
        }
        try fileStore.deleteMeetingDirectory(for: item.id)
        context.delete(item)
        try context.save()
    }

    // MARK: - Update

    func updateItem(_ item: KnowledgeItem, title: String?, bodyText: String?, tags: [String]?) throws {
        if let title { item.title = title }
        item.bodyText = bodyText
        if let tags { item.tags = tags }
        item.updatedAt = Date()
        try context.save()
    }

    func updateTitle(_ item: KnowledgeItem, title: String) throws {
        item.title = title
        item.updatedAt = Date()
        try context.save()
    }

    // MARK: - Inbox

    func moveToFolder(_ item: KnowledgeItem, folderID: UUID?) throws {
        item.folderID = folderID
        item.inboxDate = nil
        item.updatedAt = Date()
        try context.save()
    }

    func removeFromInbox(_ item: KnowledgeItem) throws {
        item.inboxDate = nil
        item.updatedAt = Date()
        try context.save()
    }
}
