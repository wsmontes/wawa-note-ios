import Foundation
import SwiftData

// MARK: - Project

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var slug: String
    var summary: String?
    var synthesis: String?
    var customInstructions: String?
    var frameworkId: String?
    var frameworkJSON: String?
    var statusRaw: String
    var colorHex: String?
    var iconName: String?
    var createdAt: Date
    var updatedAt: Date
    // Health & activity (Phase A)
    var healthScore: Double?
    var healthStatus: String?
    var lastActivityAt: Date?
    var synthesisUpdatedAt: Date?
    var synthesisSourceItemID: UUID?

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        slug: String? = nil,
        summary: String? = nil,
        synthesis: String? = nil,
        customInstructions: String? = nil,
        frameworkId: String? = nil,
        frameworkJSON: String? = nil,
        status: ProjectStatus = .active,
        colorHex: String? = nil,
        iconName: String? = "folder.fill",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        healthScore: Double? = nil,
        healthStatus: String? = nil,
        lastActivityAt: Date? = nil,
        synthesisUpdatedAt: Date? = nil,
        synthesisSourceItemID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
        self.summary = summary
        self.synthesis = synthesis
        self.customInstructions = customInstructions
        self.frameworkId = frameworkId
        self.frameworkJSON = frameworkJSON
        self.statusRaw = status.rawValue
        self.colorHex = colorHex
        self.iconName = iconName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.healthScore = healthScore
        self.healthStatus = healthStatus
        self.lastActivityAt = lastActivityAt
        self.synthesisUpdatedAt = synthesisUpdatedAt
        self.synthesisSourceItemID = synthesisSourceItemID
    }
}

enum ProjectStatus: String, Codable, CaseIterable {
    case active
    case archived
    case completed
}

// MARK: - TaskItem

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var projectID: UUID?
    var title: String
    var statusRaw: String
    var priorityRaw: String
    var ownerName: String?
    var dueAt: Date?
    var sourceItemID: UUID?
    var sourceSegmentIDs: String?
    var confidence: Double?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set { statusRaw = newValue.rawValue }
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    var sourceSegmentIDList: [String] {
        guard let json = sourceSegmentIDs, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String,
        status: TaskStatus = .todo,
        priority: TaskPriority = .medium,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        sourceItemID: UUID? = nil,
        sourceSegmentIDs: [String] = [],
        confidence: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.statusRaw = status.rawValue
        self.priorityRaw = priority.rawValue
        self.ownerName = ownerName
        self.dueAt = dueAt
        self.sourceItemID = sourceItemID
        self.sourceSegmentIDs = sourceSegmentIDs.isEmpty ? nil : (try? JSONEncoder().encode(sourceSegmentIDs)).flatMap { String(data: $0, encoding: .utf8) }
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum TaskStatus: String, Codable, CaseIterable {
    case todo
    case inProgress
    case done
    case cancelled
}

enum TaskPriority: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

// MARK: - Person

@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var displayName: String
    @Attribute(.unique) var canonicalKey: String
    var email: String?
    var role: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        canonicalKey: String? = nil,
        email: String? = nil,
        role: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.canonicalKey = canonicalKey ?? displayName.lowercased().trimmingCharacters(in: .whitespaces)
        self.email = email
        self.role = role
        self.createdAt = createdAt
    }
}

// MARK: - GraphEdge

@Model
final class GraphEdge {
    @Attribute(.unique) var id: UUID
    var fromID: UUID
    var toID: UUID
    var edgeTypeRaw: String
    var weight: Double
    var provenanceItemID: UUID?
    var provenanceSegmentIDs: String?
    var createdAt: Date

    var edgeType: EdgeType {
        get { EdgeType(rawValue: edgeTypeRaw) ?? .relatesTo }
        set { edgeTypeRaw = newValue.rawValue }
    }

    var provenanceSegmentIDList: [String] {
        guard let json = provenanceSegmentIDs, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    init(
        id: UUID = UUID(),
        fromID: UUID,
        toID: UUID,
        edgeType: EdgeType,
        weight: Double = 1.0,
        provenanceItemID: UUID? = nil,
        provenanceSegmentIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.edgeTypeRaw = edgeType.rawValue
        self.weight = weight
        self.provenanceItemID = provenanceItemID
        self.provenanceSegmentIDs = provenanceSegmentIDs.isEmpty ? nil : (try? JSONEncoder().encode(provenanceSegmentIDs)).flatMap { String(data: $0, encoding: .utf8) }
        self.createdAt = createdAt
    }
}

enum EdgeType: String, Codable, CaseIterable {
    case relatesTo
    case mentions
    case supports
    case assignedTo
    case blockedBy
    case belongsTo
    case produced
    case precedes
    case references
    case contradicts
}

// MARK: - Entity

@Model
final class Entity {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var displayName: String
    @Attribute(.unique) var canonicalKey: String

    var kind: EntityKind {
        get { EntityKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: EntityKind,
        displayName: String,
        canonicalKey: String? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.canonicalKey = canonicalKey ?? "\(kind.rawValue):\(displayName.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}

enum EntityKind: String, Codable, CaseIterable {
    case person
    case organization
    case system
    case repository
    case ticket
    case location
    case other
}

// MARK: - Project Framework (stored as JSON in Project.frameworkJSON)

struct ProjectFramework: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let itemAnalysis: AnalysisConfig
    let projectSynthesis: SynthesisConfig
    let views: [ViewDefinition]
    let entityKinds: [String]
    let edgeTypes: [String]
}

struct AnalysisConfig: Codable, Sendable {
    let systemPrompt: String
    let outputSchema: AnalysisOutputSchema
    let renderAs: [FieldRenderer]
}

struct AnalysisOutputSchema: Codable, Sendable {
    let type: String          // "object"
    let properties: [String: SchemaProperty]
    let required: [String]?
}

struct SchemaProperty: Codable, Sendable {
    let type: String          // "string", "array", "object"
    let items: SchemaItems?   // for array types
    let properties: [String: SchemaProperty]? // for object types
    let description: String?
}

struct SchemaItems: Codable, Sendable {
    let type: String
    let properties: [String: SchemaProperty]?

    init(type: String, properties: [String: SchemaProperty]? = nil) {
        self.type = type
        self.properties = properties
    }
}

struct SynthesisConfig: Codable, Sendable {
    let systemPrompt: String
    let outputSchema: AnalysisOutputSchema
}

struct FieldRenderer: Codable, Sendable {
    let field: String
    let type: RenderType
    let title: String
    let icon: String?
}

enum RenderType: String, Codable, Sendable {
    case card
    case list
    case table
    case markdown
    case chips
    case timeline
}

struct ViewDefinition: Codable, Sendable {
    let id: String
    let title: String
    let type: ViewType
    let source: String
}

enum ViewType: String, Codable, Sendable {
    case list
    case kanban
    case timeline
    case graph
    case cards
    case table
    case markdown
    case chips
}

// MARK: - Agent Suggestion (Phase G)

@Model
final class AgentSuggestion {
    @Attribute(.unique) var id: UUID
    var projectID: UUID?
    var type: String       // "task", "edge", "annotation", "decision"
    var title: String
    var body: String?
    var status: String     // "pending", "approved", "rejected"
    var confidence: Double?
    var sourceItemID: UUID?
    var sourceSegmentIDs: String?  // JSON array
    var payloadJSON: String?       // JSON for the actual action (task fields, edge fields, etc)
    var createdAt: Date
    var resolvedAt: Date?

    init(id: UUID = UUID(), projectID: UUID? = nil, type: String, title: String,
         body: String? = nil, status: String = "pending", confidence: Double? = nil,
         sourceItemID: UUID? = nil, sourceSegmentIDs: [String]? = nil,
         payloadJSON: String? = nil, createdAt: Date = Date(), resolvedAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.type = type; self.title = title
        self.body = body; self.status = status; self.confidence = confidence
        self.sourceItemID = sourceItemID
        self.sourceSegmentIDs = sourceSegmentIDs.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.payloadJSON = payloadJSON; self.createdAt = createdAt; self.resolvedAt = resolvedAt
    }
}

