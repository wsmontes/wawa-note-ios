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
    case repository
    case location
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

// MARK: - Dynamic Analysis (framework-driven, replaces MeetingAnalysis for non-meeting projects)

/// Analysis result with a flexible schema defined by the project's framework.
/// `MeetingAnalysis` remains the output of the builtin/meeting framework;
/// all other frameworks produce `DynamicAnalysis`.
struct DynamicAnalysis: Identifiable, Codable, Sendable {
    let id: UUID
    let itemId: UUID
    var createdAt: Date
    var providerId: String
    var model: String?
    var schemaId: String           // which framework generated this
    var results: AnalysisResults   // schema-free JSON blob

    init(
        id: UUID = UUID(),
        itemId: UUID,
        createdAt: Date = Date(),
        providerId: String,
        model: String? = nil,
        schemaId: String,
        results: AnalysisResults = .empty
    ) {
        self.id = id
        self.itemId = itemId
        self.createdAt = createdAt
        self.providerId = providerId
        self.model = model
        self.schemaId = schemaId
        self.results = results
    }
}

/// Type-erased JSON container for dynamic analysis results.
/// Decoded from whatever schema the framework defines.
struct AnalysisResults: Codable, Sendable {
    private var storage: [String: AnyCodable]

    static var empty: AnalysisResults { AnalysisResults(storage: [:]) }

    init(storage: [String: AnyCodable] = [:]) {
        self.storage = storage
    }

    subscript(_ key: String) -> AnyCodable? {
        storage[key]
    }

    func stringField(_ path: String) -> String? {
        storage[path]?.value as? String
    }

    func arrayField(_ path: String) -> [AnyCodable]? {
        storage[path]?.value as? [AnyCodable]
    }

    var allKeys: [String] { Array(storage.keys) }
    var isEmpty: Bool { storage.isEmpty }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: AnyCodable].self)
        self.storage = dict
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}

/// A codable wrapper for any JSON-compatible value.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any
    private let _encode: (Encoder) throws -> Void

    init(_ value: Any) {
        self.value = value
        self._encode = { encoder in
            var container = encoder.singleValueContainer()
            if let v = value as? String { try container.encode(v) }
            else if let v = value as? Int { try container.encode(v) }
            else if let v = value as? Double { try container.encode(v) }
            else if let v = value as? Float { try container.encode(Double(v)) }
            else if let v = value as? Int64 { try container.encode(v) }
            else if let v = value as? Bool { try container.encode(v) }
            else if let v = value as? [AnyCodable] { try container.encode(v) }
            else if let v = value as? [String: AnyCodable] { try container.encode(v) }
            else { try container.encodeNil() }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self.init(v) }
        else if let v = try? container.decode(Int.self) { self.init(v) }
        else if let v = try? container.decode(Int64.self) { self.init(v) }
        else if let v = try? container.decode(Double.self) { self.init(v) }
        else if let v = try? container.decode(Float.self) { self.init(Double(v)) }
        else if let v = try? container.decode(Bool.self) { self.init(v) }
        else if let v = try? container.decode([AnyCodable].self) { self.init(v) }
        else if let v = try? container.decode([String: AnyCodable].self) { self.init(v) }
        else { self = AnyCodable("") }
    }

    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}
