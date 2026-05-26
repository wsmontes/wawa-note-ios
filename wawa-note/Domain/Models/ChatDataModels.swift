import Foundation
import SwiftData

@Model
final class ChatConversationModel {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var providerId: UUID?
    var model: String?

    @Relationship(deleteRule: .cascade) var messages: [ChatMessageModel]?

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerId: UUID? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerId = providerId
        self.model = model
    }
}

@Model
final class ChatMessageModel {
    var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date

    @Relationship(inverse: \ChatConversationModel.messages) var conversation: ChatConversationModel?

    var role: AIRole {
        get { AIRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        role: AIRole = .user,
        content: String = "",
        createdAt: Date = Date(),
        conversation: ChatConversationModel? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.conversation = conversation
    }
}
