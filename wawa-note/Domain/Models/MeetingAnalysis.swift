import Foundation

enum ActionItemStatus: String, Codable {
    case pending
    case inProgress
    case done
    case cancelled
}

struct ActionItem: Identifiable, Codable {
    let id: UUID
    var task: String
    var owner: String?
    var dueDate: Date?
    var status: ActionItemStatus
    var sourceSegmentIds: [UUID]
    var confidence: Double?

    init(
        id: UUID = UUID(),
        task: String,
        owner: String? = nil,
        dueDate: Date? = nil,
        status: ActionItemStatus = .pending,
        sourceSegmentIds: [UUID] = [],
        confidence: Double? = nil
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.status = status
        self.sourceSegmentIds = sourceSegmentIds
        self.confidence = confidence
    }
}

struct Decision: Identifiable, Codable {
    let id: UUID
    var title: String
    var details: String
    var sourceSegmentIds: [UUID]
    var confidence: Double?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        sourceSegmentIds: [UUID] = [],
        confidence: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.sourceSegmentIds = sourceSegmentIds
        self.confidence = confidence
    }
}

struct Risk: Identifiable, Codable {
    let id: UUID
    var risk: String
    var details: String
    var sourceSegmentIds: [UUID]
    var confidence: Double?

    init(
        id: UUID = UUID(),
        risk: String,
        details: String = "",
        sourceSegmentIds: [UUID] = [],
        confidence: Double? = nil
    ) {
        self.id = id
        self.risk = risk
        self.details = details
        self.sourceSegmentIds = sourceSegmentIds
        self.confidence = confidence
    }
}

struct OpenQuestion: Identifiable, Codable {
    let id: UUID
    var question: String
    var sourceSegmentIds: [UUID]
    var confidence: Double?

    init(
        id: UUID = UUID(),
        question: String,
        sourceSegmentIds: [UUID] = [],
        confidence: Double? = nil
    ) {
        self.id = id
        self.question = question
        self.sourceSegmentIds = sourceSegmentIds
        self.confidence = confidence
    }
}

struct ImportantDate: Identifiable, Codable {
    let id: UUID
    var date: String
    var meaning: String
    var sourceSegmentIds: [UUID]

    init(
        id: UUID = UUID(),
        date: String,
        meaning: String = "",
        sourceSegmentIds: [UUID] = []
    ) {
        self.id = id
        self.date = date
        self.meaning = meaning
        self.sourceSegmentIds = sourceSegmentIds
    }
}

struct EntityMention: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: EntityType
    var sourceSegmentIds: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        type: EntityType = .other,
        sourceSegmentIds: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sourceSegmentIds = sourceSegmentIds
    }
}

enum EntityType: String, Codable {
    case person
    case organization
    case system
    case tool
    case project
    case other
}

struct TopicBlock: Identifiable, Codable {
    let id: UUID
    var title: String
    var startTime: Double
    var endTime: Double
    var explanation: String
    var sourceSegmentIds: [UUID]

    init(
        id: UUID = UUID(),
        title: String,
        startTime: Double,
        endTime: Double,
        explanation: String = "",
        sourceSegmentIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.explanation = explanation
        self.sourceSegmentIds = sourceSegmentIds
    }
}

struct MeetingAnalysis: Identifiable, Codable {
    let id: UUID
    let meetingId: UUID
    var createdAt: Date
    var providerId: String
    var model: String?
    var shortSummary: String
    var detailedSummary: String
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var risks: [Risk]
    var openQuestions: [OpenQuestion]
    var importantDates: [ImportantDate]
    var entities: [EntityMention]
    var topicTimeline: [TopicBlock]
    var rawProviderResponsePath: String?

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        createdAt: Date = Date(),
        providerId: String,
        model: String? = nil,
        shortSummary: String = "",
        detailedSummary: String = "",
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        risks: [Risk] = [],
        openQuestions: [OpenQuestion] = [],
        importantDates: [ImportantDate] = [],
        entities: [EntityMention] = [],
        topicTimeline: [TopicBlock] = [],
        rawProviderResponsePath: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.createdAt = createdAt
        self.providerId = providerId
        self.model = model
        self.shortSummary = shortSummary
        self.detailedSummary = detailedSummary
        self.decisions = decisions
        self.actionItems = actionItems
        self.risks = risks
        self.openQuestions = openQuestions
        self.importantDates = importantDates
        self.entities = entities
        self.topicTimeline = topicTimeline
        self.rawProviderResponsePath = rawProviderResponsePath
    }
}
