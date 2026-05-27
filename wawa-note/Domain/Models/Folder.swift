import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentFolderID: UUID?
    var createdAt: Date
    var sortOrder: Int
    var iconName: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        parentFolderID: UUID? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.iconName = iconName
    }
}
