import Foundation
// Related JIRA: KAN-9, KAN-43


// MARK: - VFS Node Type

enum VFSNodeType: String, Codable, Sendable, Hashable {
    case directory
    case markdownFile     // .md
    case jsonFile         // .json
    case audioFile        // .m4a
    case imageFile        // .jpg, .png
    case projectFile      // project.json (special)
    case unknown
}

// MARK: - VFS Node Metadata

struct VFSNodeMetadata: Sendable, Codable, Hashable {
    var itemType: String?           // KnowledgeItemType: audio, note, image, journalEntry, webBookmark
    var itemStatus: String?         // ItemStatus: draft, recording, analyzed, etc.
    var projectStatus: String?      // ProjectStatus: active, archived, completed
    var healthStatus: String?
    var healthScore: Double?
    var taskCount: Int?
    var itemCount: Int?
    var tags: [String]?
    var durationSeconds: Double?
    var swiftDataID: UUID?          // Backing model UUID for write operations
    var isConfigProject: Bool = false
    var priority: String?           // TaskPriority
    var owner: String?              // Task owner
    var dueAt: Date?                // Task due date
    var edgeType: String?           // GraphEdge type
    var signalType: String?         // AgentSuggestion type
    var isFlagged: Bool = false
    var confidence: Double?         // Annotation/Edge confidence
    var languageCode: String?
    var calendarEventIdentifier: String?

    init(
        itemType: String? = nil,
        itemStatus: String? = nil,
        projectStatus: String? = nil,
        healthStatus: String? = nil,
        healthScore: Double? = nil,
        taskCount: Int? = nil,
        itemCount: Int? = nil,
        tags: [String]? = nil,
        durationSeconds: Double? = nil,
        swiftDataID: UUID? = nil,
        isConfigProject: Bool = false,
        priority: String? = nil,
        owner: String? = nil,
        dueAt: Date? = nil,
        edgeType: String? = nil,
        signalType: String? = nil,
        isFlagged: Bool = false,
        confidence: Double? = nil,
        languageCode: String? = nil,
        calendarEventIdentifier: String? = nil
    ) {
        self.itemType = itemType
        self.itemStatus = itemStatus
        self.projectStatus = projectStatus
        self.healthStatus = healthStatus
        self.healthScore = healthScore
        self.taskCount = taskCount
        self.itemCount = itemCount
        self.tags = tags
        self.durationSeconds = durationSeconds
        self.swiftDataID = swiftDataID
        self.isConfigProject = isConfigProject
        self.priority = priority
        self.owner = owner
        self.dueAt = dueAt
        self.edgeType = edgeType
        self.signalType = signalType
        self.isFlagged = isFlagged
        self.confidence = confidence
        self.languageCode = languageCode
        self.calendarEventIdentifier = calendarEventIdentifier
    }
}

// MARK: - VFS Node

/// Represents a single node (file or directory) in the virtual filesystem.
/// This is the UI-facing model used by FileBrowserView and FileEditorRouter.
struct VFSNode: Identifiable, Sendable, Hashable {
    /// Full VFS path, e.g. "/projects/wawa-note/items/abc123"
    let id: String
    /// Display name, e.g. "abc123" or "project.json" or "meeting-notes"
    let name: String
    /// Full VFS path (same as id for files/dirs; used for navigation)
    let path: String
    /// File type classification
    let nodeType: VFSNodeType
    /// Whether this is a directory (can contain children)
    let isDirectory: Bool
    /// File size in bytes (nil for directories)
    let size: Int64?
    /// Last modification date
    let modifiedAt: Date?
    /// Number of children for directories (nil for files)
    let childrenCount: Int?
    /// Type-specific metadata
    let metadata: VFSNodeMetadata

    init(
        id: String,
        name: String,
        path: String,
        nodeType: VFSNodeType,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        childrenCount: Int? = nil,
        metadata: VFSNodeMetadata = VFSNodeMetadata()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.nodeType = nodeType
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.childrenCount = childrenCount
        self.metadata = metadata
    }

    // MARK: - Convenience initializers

    /// Creates a directory node.
    static func directory(
        path: String,
        name: String,
        childrenCount: Int? = nil,
        modifiedAt: Date? = nil,
        metadata: VFSNodeMetadata = VFSNodeMetadata()
    ) -> VFSNode {
        VFSNode(
            id: path, name: name, path: path,
            nodeType: .directory, isDirectory: true,
            size: nil, modifiedAt: modifiedAt,
            childrenCount: childrenCount, metadata: metadata
        )
    }

    /// Creates a file node.
    static func file(
        path: String,
        name: String,
        nodeType: VFSNodeType,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        metadata: VFSNodeMetadata = VFSNodeMetadata()
    ) -> VFSNode {
        VFSNode(
            id: path, name: name, path: path,
            nodeType: nodeType, isDirectory: false,
            size: size, modifiedAt: modifiedAt,
            childrenCount: nil, metadata: metadata
        )
    }
}

// MARK: - VFS Node Type Detection

extension VFSNodeType {
    /// Detects the VFSNodeType from a filename.
    static func from(filename: String) -> VFSNodeType {
        let lower = filename.lowercased()
        if lower == "project.json" { return .projectFile }
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return .markdownFile }
        if lower.hasSuffix(".json") { return .jsonFile }
        if lower.hasSuffix(".m4a") || lower.hasSuffix(".mp3") || lower.hasSuffix(".wav") { return .audioFile }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".heic") { return .imageFile }
        return .unknown
    }

    /// SF Symbol icon name for this file type.
    var iconName: String {
        switch self {
        case .directory:     "folder.fill"
        case .markdownFile:  "doc.richtext.fill"
        case .jsonFile:      "curlybraces"
        case .audioFile:     "waveform"
        case .imageFile:     "photo.fill"
        case .projectFile:   "doc.text.fill"
        case .unknown:       "doc.fill"
        }
    }

    /// Color tint for this file type.
    var tintColor: String {
        switch self {
        case .directory:    "#64748B"   // slate gray
        case .markdownFile: "#2563EB"   // blue
        case .jsonFile:     "#0D9488"   // teal
        case .audioFile:    "#7C3AED"   // purple
        case .imageFile:    "#DB2777"   // pink
        case .projectFile:  "#B45309"   // amber
        case .unknown:      "#6B7280"   // gray
        }
    }
}
