import Foundation
import SwiftData

struct ConversionPreview: Codable, Sendable {
    let projectName: String
    let tasks: [ConversionTask]
    let people: [ConversionPerson]
    let entities: [ConversionEntity]
    let edges: [ConversionEdge]

    struct ConversionTask: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let title: String
        let ownerName: String?
        let priority: String?
        let sourceSegmentIDs: [String]
    }

    struct ConversionPerson: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let displayName: String
        let role: String?
    }

    struct ConversionEntity: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let kind: String
        let displayName: String
    }

    struct ConversionEdge: Codable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        let fromRef: String        // "task:0", "entity:0", "person:0"
        let toRef: String          // "project", "task:1", etc.
        let edgeType: String
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

        let response = try await provider.send(AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(conversionSystemPrompt)]),
                AIMessage(role: .user, content: [.text(prompt)])
            ],
            responseFormat: .json
        ))

        guard let data = response.content.data(using: .utf8) else {
            throw ProviderError.decodingFailed
        }
        return try JSONDecoder().decode(ConversionPreview.self, from: data)
    }

    /// Execute the conversion: create Project, Tasks, People, Entities, and Edges
    func executeConversion(from item: KnowledgeItem, preview: ConversionPreview) throws -> Project {
        let project = try projectService.create(
            name: preview.projectName,
            summary: "Created from: \(item.title.isEmpty ? "Untitled" : item.title)",
            iconName: "folder.fill"
        )

        // Link the source item to the project
        item.projectID = project.id
        item.updatedAt = Date()

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
        var ctx = "Item Title: \(item.title)\n"
        ctx += "Type: \(item.type.rawValue)\n"
        ctx += "ID: \(item.id.uuidString)\n"

        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            if !analysis.shortSummary.isEmpty {
                ctx += "Summary: \(analysis.shortSummary)\n"
            }
            if !analysis.actionItems.isEmpty {
                ctx += "Action Items:\n"
                for a in analysis.actionItems {
                    ctx += "- \(a.task)"
                    if let owner = a.owner { ctx += " (owner: \(owner))" }
                    ctx += "\n"
                }
            }
            if !analysis.decisions.isEmpty {
                ctx += "Decisions:\n"
                for d in analysis.decisions { ctx += "- \(d.title)\n" }
            }
            if !analysis.entities.isEmpty {
                ctx += "Entities:\n"
                for e in analysis.entities { ctx += "- \(e.name) [\(e.type.rawValue)]\n" }
            }
        }

        if let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
            ctx += "Transcript excerpt:\n"
            for seg in transcript.segments.prefix(20) {
                ctx += "[\(seg.id)] \(seg.text)\n"
            }
        }

        return ctx
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
        You are a project management AI that converts meeting transcripts into structured project plans.
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
        Analyze this meeting and create a project plan:

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
