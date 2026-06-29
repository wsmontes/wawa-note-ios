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
            status: .draft,
            tags: tags,
            folderID: folderID,
            bodyText: bodyText,
            durationSeconds: durationSeconds,
            languageCode: languageCode,
            inboxDate: inboxDate
        )
        context.insert(item)
        try context.save()
        // Write body.md for text-based items (notes, journals) — defense in depth
        if let body = bodyText, !body.isEmpty,
            type == .note || type == .journalEntry
        {
            let dir = FileArtifactStore().itemDirectoryURL(for: item.id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: dir.appendingPathComponent("body.md"), atomically: true, encoding: .utf8)
        }
        // Index in Spotlight
        SpotlightIndexService().indexItem(item)
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
        // Include legacy "meeting" items when querying for audio type
        let predicate: Predicate<KnowledgeItem>
        if typeRaw == "audio" {
            predicate = #Predicate { $0.typeRaw == "audio" || $0.typeRaw == "meeting" }
        } else {
            predicate = #Predicate { $0.typeRaw == typeRaw }
        }
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// One-time migration: rewrite legacy "meeting" typeRaw to "audio"
    static func migrateMeetingToAudio(context: ModelContext) {
        let key = "migration_meeting_to_audio_done"
        if UserDefaults.standard.bool(forKey: key) { return }
        var descriptor = FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { $0.typeRaw == "meeting" }
        )
        descriptor.fetchLimit = 1000
        if let items = try? context.fetch(descriptor), !items.isEmpty {
            for item in items { item.typeRaw = "audio" }
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: key)
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
        let tid = item.id
        let outgoing = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == tid }))
        for edge in outgoing { context.delete(edge) }
        let incoming = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == tid }))
        for edge in incoming { context.delete(edge) }
        try fileStore.deleteMeetingDirectory(for: item.id)
        context.delete(item)
        try context.save()
        // Remove from Spotlight
        SpotlightIndexService().deleteItem(itemId)
    }

    /// Batch delete multiple items efficiently (single save).
    /// Files are deleted FIRST for each item. If any file deletion fails, the item
    /// is skipped and remains in SwiftData — no orphaned files are created.
    /// Returns the count of successfully deleted items and a list of UUIDs that failed.
    @discardableResult
    func deleteItems(_ items: [KnowledgeItem]) throws -> (deleted: Int, failed: [UUID]) {
        var failedIDs: [UUID] = []
        var deletedIDs: [UUID] = []
        var deletedCount = 0
        for item in items {
            // Delete files first — if this fails, the item stays in SwiftData
            do {
                try fileStore.deleteMeetingDirectory(for: item.id)
            } catch {
                AppLog.storage.error("KnowledgeItemService: batch delete file removal failed — \(item.id.uuidString): \(error.localizedDescription)")
                failedIDs.append(item.id)
                continue
            }
            context.delete(item)
            deletedIDs.append(item.id)
            deletedCount += 1
        }

        // Clean up annotations and graph edges ONLY for successfully deleted items.
        // Doing this before file deletion would leave orphan records if any file
        // deletion fails — the item stays in SwiftData but its relationships are gone.
        let successIDs = Set(deletedIDs)
        if !successIDs.isEmpty {
            let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { successIDs.contains($0.itemID) })
            if let anns = try? context.fetch(annPred) { for ann in anns { context.delete(ann) } }
            let edges = try context.fetch(
                FetchDescriptor<GraphEdge>(
                    predicate: #Predicate {
                        successIDs.contains($0.fromID) || successIDs.contains($0.toID)
                    }))
            for edge in edges { context.delete(edge) }
        }

        try context.save()
        for id in deletedIDs { SpotlightIndexService().deleteItem(id) }

        if !failedIDs.isEmpty {
            AppLog.storage.warning(
                "KnowledgeItemService: batch delete — \(deletedCount) deleted, \(failedIDs.count) failed: \(failedIDs.map(\.uuidString).joined(separator: ", "))"
            )
        } else {
            AppLog.event("batch", "Batch deleted \(deletedCount) items")
        }
        return (deletedCount, failedIDs)
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
