import Foundation

enum CocreationPhase: String, Codable, Sendable {
    case humanDraft
    case aiExpanding
    case reviewExpansion
    case humanEdit
    case aiReanalyze
    case suggestionsReady
    case complete
}

struct CocreationState: Codable, Sendable {
    var phase: CocreationPhase
    var originalContent: String
    var currentContent: String
    var aiAdditions: String?
    var suggestions: [CoCreationSuggestion]
    var editHistory: [EditRecord]
    var itemId: UUID

    init(itemId: UUID, originalContent: String) {
        self.itemId = itemId
        self.originalContent = originalContent
        self.currentContent = originalContent
        self.phase = .humanDraft
        self.suggestions = []
        self.editHistory = []
    }
}

struct CoCreationSuggestion: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    let text: String
    let category: SuggestionCategory
    let relatedItemIds: [UUID]

    enum SuggestionCategory: String, Codable, Sendable {
        case connection
        case expansion
        case contradiction
        case nextStep
    }
}

struct EditRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    let timestamp: Date
    let author: EditAuthor
    let diff: String

    enum EditAuthor: String, Codable, Sendable {
        case human
        case ai
    }
}

struct CocreationResult: Codable, Sendable {
    let expandedText: String
    let suggestions: [CoCreationSuggestion]
    let relatedItemIds: [UUID]
}
