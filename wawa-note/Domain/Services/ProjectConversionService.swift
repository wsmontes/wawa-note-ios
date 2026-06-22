import Foundation
import SwiftData

struct ConversionPreview: Codable, Sendable {
    let projectName: String
    let tasks: [ConversionTask]
    let people: [ConversionPerson]
    let entities: [ConversionEntity]
    let edges: [ConversionEdge]
    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case tasks, people, entities, edges
    }

    struct ConversionTask: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let title: String
        let ownerName: String?
        let priority: String?
        let sourceSegmentIDs: [String]
        enum CodingKeys: String, CodingKey {
            case title
            case ownerName = "owner_name"
            case priority
            case sourceSegmentIDs = "source_segment_ids"
        }
    }

    struct ConversionPerson: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let displayName: String
        let role: String?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case role
        }
    }

    struct ConversionEntity: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let kind: String
        let displayName: String
        enum CodingKeys: String, CodingKey {
            case kind
            case displayName = "display_name"
        }
    }

    struct ConversionEdge: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let fromRef: String
        let toRef: String
        let edgeType: String
        enum CodingKeys: String, CodingKey {
            case fromRef = "from_ref"
            case toRef = "to_ref"
            case edgeType = "edge_type"
        }
    }
}

@MainActor
final class ProjectConversionService {
    private let context: ModelContext
    private let projectService: ProjectService
    private let taskService: TaskService
    private let personService: PersonService
    private let entityService: EntityService
    private let edgeService: GraphEdgeService
    private let fileStore: FileArtifactStore

    init(context: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.context = context
        self.fileStore = fileStore
        self.projectService = ProjectService(context: context)
        self.taskService = TaskService(context: context)
        self.personService = PersonService(context: context)
        self.entityService = EntityService(context: context)
        self.edgeService = GraphEdgeService(context: context)
    }

    /// Generate a preview of what would be created from a knowledge item
    func generatePreview(from item: KnowledgeItem, using provider: any AIProvider, model: String) async throws -> ConversionPreview {
        let context = buildItemContext(item)
        let prompt = buildConversionPrompt(context: context)

        let params = AIConfigService.shared.requestParams(for: "project_conversion", model: model)
        let response = try await provider.send(AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(conversionSystemPrompt)]),
                AIMessage(role: .user, content: [.text(prompt)])
            ],
            temperature: params.temperature,
            maxTokens: params.maxTokens,
            responseFormat: .jsonObject
        ))

        return try ProviderAdapter.decode(ConversionPreview.self, from: response.content)
    }

    /// Execute the conversion: create Project, Tasks, People, Entities, and Edges
    func executeConversion(from item: KnowledgeItem, preview: ConversionPreview, template: ProjectTemplate? = nil) throws -> Project {
        let project = try projectService.create(name: preview.projectName, template: template, origin: .user)
        _ = try? projectService.update(
            id: project.id,
            fields: ProjectUpdateFields(summary: "Created from: \(item.title.isEmpty ? "Untitled" : item.title)"),
            origin: .user
        )

        // Link the source item to the project (preserve existing assignment)
        if item.projectID == nil {
            try? projectService.addItem(item.id, to: project.id)
        }

        // Create edge: item belongs to project
        try edgeService.create(
            fromID: item.id,
            toID: project.id,
            edgeType: .belongsTo,
            provenanceItemID: item.id
        )

        // Create tasks
        var taskRefs: [String: TaskItem] = [:]
        for (index, ct) in preview.tasks.enumerated() {
            let ownerName = ct.ownerName
            let priority = ct.priority.flatMap { TaskPriority(rawValue: $0) } ?? .medium
            let task = try taskService.create(
                title: ct.title,
                projectID: project.id,
                priority: priority,
                ownerName: ownerName,
                sourceItemID: item.id,
                sourceSegmentIDs: ct.sourceSegmentIDs,
                confidence: 1.0
            )
            taskRefs["task:\(index)"] = task
        }

        // Create people
        var personRefs: [String: Person] = [:]
        for (index, cp) in preview.people.enumerated() {
            let person = try personService.findOrCreate(
                displayName: cp.displayName,
                role: cp.role
            )
            personRefs["person:\(index)"] = person

            // Edge: item mentions person
            try edgeService.create(
                fromID: item.id,
                toID: person.id,
                edgeType: .mentions,
                provenanceItemID: item.id
            )
        }

        // Create entities
        var entityRefs: [String: Entity] = [:]
        for (index, ce) in preview.entities.enumerated() {
            let kind = EntityKind(rawValue: ce.kind) ?? .other
            let entity = try entityService.findOrCreate(kind: kind, displayName: ce.displayName)
            entityRefs["entity:\(index)"] = entity

            try edgeService.create(
                fromID: item.id,
                toID: entity.id,
                edgeType: .mentions,
                provenanceItemID: item.id
            )
        }

        // Create additional edges from the preview
        for ce in preview.edges {
            let fromID = resolveRef(ce.fromRef, item: item, project: project, tasks: taskRefs, people: personRefs, entities: entityRefs)
            let toID = resolveRef(ce.toRef, item: item, project: project, tasks: taskRefs, people: personRefs, entities: entityRefs)
            guard let fromID, let toID else { continue }
            let edgeType = EdgeType(rawValue: ce.edgeType) ?? .relatesTo
            try edgeService.create(fromID: fromID, toID: toID, edgeType: edgeType, provenanceItemID: item.id)
        }

        try context.save()
        return project
    }

    // MARK: - Helpers

    private func buildItemContext(_ item: KnowledgeItem) -> String {
        ItemContextBuilder.buildItemContext(item: item, fileStore: fileStore)
    }

    private func resolveRef(
        _ ref: String,
        item: KnowledgeItem,
        project: Project,
        tasks: [String: TaskItem],
        people: [String: Person],
        entities: [String: Entity]
    ) -> UUID? {
        if ref == "item" { return item.id }
        if ref == "project" { return project.id }
        if ref.hasPrefix("task:"), let t = tasks[ref] { return t.id }
        if ref.hasPrefix("person:"), let p = people[ref] { return p.id }
        if ref.hasPrefix("entity:"), let e = entities[ref] { return e.id }
        return nil
    }

    private var conversionSystemPrompt: String {
        """
        You are a project management AI that converts content into structured project plans.
        Extract: project name, tasks with owners and priorities, people mentioned, entities (organizations, systems, tools), and relationships between them.
        Output valid JSON matching this schema:
        {
          "project_name": "...",
          "tasks": [{"title": "...", "owner_name": "...", "priority": "low|medium|high|critical", "source_segment_ids": ["seg_1"]}],
          "people": [{"display_name": "...", "role": "..."}],
          "entities": [{"kind": "organization|system|repository|ticket|location|other", "display_name": "..."}],
          "edges": [{"from_ref": "task:0", "to_ref": "task:1", "edge_type": "blockedBy|precedes|relatesTo"}]
        }
        Use refs like "task:0", "person:0", "entity:0", "project", "item" for edge endpoints.
        Only include edges that have clear evidence in the transcript.
        """
    }

    private func buildConversionPrompt(context: String) -> String {
        """
        Analyze this content and create a project plan:

        \(context)

        Based on the above content, extract:
        1. A concise project name
        2. Action items as tasks with owners and priorities
        3. People mentioned (with roles if evident)
        4. Entities: organizations, systems, tools, repositories, locations
        5. Relationships between tasks (blockedBy, precedes), tasks assigned to people, etc.

        Output as JSON per the schema.
        """
    }
}
