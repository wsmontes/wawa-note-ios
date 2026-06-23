import SwiftUI
import SwiftData
// Related JIRA: KAN-8, KAN-38


/// Represents either a KnowledgeItem or a ProjectDerivedItem in the unified file browser.
enum UnifiedItem: Identifiable {
    case knowledge(KnowledgeItem)
    case derived(ProjectDerivedItem)

    var id: UUID {
        switch self {
        case .knowledge(let item): item.id
        case .derived(let item): item.id
        }
    }

    var title: String {
        switch self {
        case .knowledge(let item): item.title
        case .derived(let item): item.title
        }
    }

    var displayIcon: String {
        switch self {
        case .knowledge(let item): item.type.icon
        case .derived(let item): item.displayIcon
        }
    }

    var displayColor: Color {
        switch self {
        case .knowledge(let item): item.type.color
        case .derived(let item):
            switch item.type {
            case .synthesis: .purple
            case .task: .teal
            case .signal: .orange
            case .connection: .blue
            case .decision: .yellow
            case .question: .mint
            }
        }
    }

    var subtitle: String {
        switch self {
        case .knowledge(let item): item.type.label
        case .derived(let item):
            switch item.type {
            case .synthesis: "Synthesis"
            case .task: "Task · \(item.statusRaw ?? "todo")"
            case .signal: "Signal · \(item.statusRaw ?? "visible")"
            case .connection: "Connection"
            case .decision: "Decision"
            case .question: "Question"
            }
        }
    }

    var createdAt: Date {
        switch self {
        case .knowledge(let item): item.createdAt
        case .derived(let item): item.createdAt
        }
    }

    var isSource: Bool {
        if case .knowledge = self { return true }
        return false
    }

    var isDerived: Bool {
        if case .derived = self { return true }
        return false
    }
}
