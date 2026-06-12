import Foundation
import SwiftData

// MARK: - Internal VFS Path

enum VFSPath {
    case root
    case inbox
    case inboxItem(id: UUID)
    case inboxItemFile(id: UUID)
    case projects
    case project(slug: String, projectID: UUID)
    case projectItems(projectSlug: String, projectID: UUID)
    case projectItem(projectSlug: String, projectID: UUID, itemID: UUID)
    case projectItemContents(projectSlug: String, projectID: UUID, itemID: UUID)
    case projectTasks(projectSlug: String, projectID: UUID)
    case projectTask(projectSlug: String, projectID: UUID, taskID: UUID)
    case projectPeople(projectSlug: String, projectID: UUID)
    case projectEdges(projectSlug: String, projectID: UUID)
    case projectSignals(projectSlug: String, projectID: UUID)
    case projectAnalysis(projectSlug: String, projectID: UUID, itemID: UUID?)
    case projectExport(projectSlug: String, projectID: UUID)
    case agentPrompts
    case agentPrompt(name: String)
    case agentMemories
    case agentMemory(id: UUID)
    case agentChat
    case agentChatConversation(id: UUID)
    // Config project virtual paths
    case configProviders
    case configProvider(name: String)
    case configPrompts
    case configPrompt(name: String)
    case configSettings
    case configSetting(name: String)
    case configMemoriesDir
    case configMemory(id: UUID)
    case configSchemas(projectSlug: String, projectID: UUID)
    case configSchema(projectSlug: String, projectID: UUID, name: String)
    case unknown(String)
}

extension VFSPath {
    var isProjectLike: Bool {
        switch self {
        case .projectItems, .projectItem, .projectItemContents,
                .projectTasks, .projectTask: return true
        default: return false
        }
    }
}

// MARK: - VFS Service

/// Shared virtual filesystem resolution and CRUD.
/// Used by both ShellInterpreter (agent) and FileBrowserView (user UI).
/// All methods are static; the enum serves as a namespace.
@MainActor
enum VFSService {

    // MARK: - Path Resolution

    /// Resolves a raw path string into a VFSPath case.
    static func resolve(_ raw: String?, context: ToolContext) -> VFSPath {
        guard let raw, !raw.isEmpty else {
            if let slug = context.activeProjectSlug, let pid = context.activeProjectID {
                return .project(slug: slug, projectID: pid)
            }
            return .root
        }

        let path = raw.hasPrefix("/") ? raw : resolveRelative(raw, context: context)
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        if parts.isEmpty { return .root }

        switch parts[0] {
        case "inbox":
            if parts.count == 1 { return .inbox }
            let inboxItemStr = stripJSONSuffix(parts[1])
            let hasSubPath = parts.count > 2
            if let id = UUID(uuidString: inboxItemStr) {
                return hasSubPath ? .inboxItemFile(id: id) : .inboxItem(id: id)
            }
            let allItems = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
            if let matched = allItems.first(where: { $0.title.caseInsensitiveCompare(inboxItemStr) == .orderedSame }) {
                return hasSubPath ? .inboxItemFile(id: matched.id) : .inboxItem(id: matched.id)
            }
            let candidates = allItems.filter { $0.title.localizedCaseInsensitiveContains(inboxItemStr) }
            if candidates.count == 1 { return hasSubPath ? .inboxItemFile(id: candidates[0].id) : .inboxItem(id: candidates[0].id) }
            if let matched = allItems.first(where: { $0.id.uuidString.hasPrefix(inboxItemStr) }) {
                return hasSubPath ? .inboxItemFile(id: matched.id) : .inboxItem(id: matched.id)
            }
            return .unknown("inbox: '\(parts[1])' not found")

        case "projects":
            if parts.count == 1 { return .projects }
            let remaining = Array(parts.dropFirst())
            var matchedProject: Project?
            var consumedSegments = 0
            for i in 1...remaining.count {
                let candidate = remaining.prefix(i).joined(separator: "/")
                if let p = findProject(named: candidate, context: context) {
                    matchedProject = p
                    consumedSegments = i
                    break
                }
            }
            guard let project = matchedProject else {
                return .unknown("projects: '\(parts[1])' not found")
            }
            let pid = project.id
            let dirName = safeDirName(project)
            let subParts = Array(parts.dropFirst(1 + consumedSegments))
            if subParts.isEmpty { return .project(slug: dirName, projectID: pid) }

            switch subParts[0] {
            case "items":
                if subParts.count == 1 { return .projectItems(projectSlug: dirName, projectID: pid) }
                let itemIDStr = stripJSONSuffix(subParts[1])
                if let id = UUID(uuidString: itemIDStr) {
                    if subParts.count > 2 {
                        return .projectItemContents(projectSlug: dirName, projectID: pid, itemID: id)
                    }
                    return .projectItem(projectSlug: dirName, projectID: pid, itemID: id)
                }
                if let matched = fuzzyMatchUUID(prefix: itemIDStr, in: pid, context: context, type: .item) {
                    if subParts.count > 2 {
                        return .projectItemContents(projectSlug: dirName, projectID: pid, itemID: matched)
                    }
                    return .projectItem(projectSlug: dirName, projectID: pid, itemID: matched)
                }
                return .unknown("items: '\(subParts[1])' not found")
            case "tasks":
                if subParts.count == 1 { return .projectTasks(projectSlug: dirName, projectID: pid) }
                let taskIDStr = stripJSONSuffix(subParts[1])
                if let id = UUID(uuidString: taskIDStr) { return .projectTask(projectSlug: dirName, projectID: pid, taskID: id) }
                if let matched = fuzzyMatchUUID(prefix: taskIDStr, in: pid, context: context, type: .task) {
                    return .projectTask(projectSlug: dirName, projectID: pid, taskID: matched)
                }
                return .unknown("tasks: '\(subParts[1])' not found")
            case "people":
                return .projectPeople(projectSlug: dirName, projectID: pid)
            case "edges":
                return .projectEdges(projectSlug: dirName, projectID: pid)
            case "signals":
                return .projectSignals(projectSlug: dirName, projectID: pid)
            case "analysis":
                if subParts.count > 1 {
                    let idStr = stripJSONSuffix(subParts[1])
                    if let id = UUID(uuidString: idStr) { return .projectAnalysis(projectSlug: dirName, projectID: pid, itemID: id) }
                    if let matched = fuzzyMatchUUID(prefix: idStr, in: pid, context: context, type: .item) {
                        return .projectAnalysis(projectSlug: dirName, projectID: pid, itemID: matched)
                    }
                    return .unknown("analysis: '\(subParts[1])' not found")
                }
                return .projectAnalysis(projectSlug: dirName, projectID: pid, itemID: nil)
            case "config":
                if subParts.count > 1 {
                    switch subParts[1] {
                    case "schemas":
                        if subParts.count > 2 {
                            let schemaName = stripJSONSuffix(subParts[2])
                            return .configSchema(projectSlug: dirName, projectID: pid, name: schemaName)
                        }
                        return .configSchemas(projectSlug: dirName, projectID: pid)
                    default:
                        return .unknown("config: unknown '\(subParts[1])'")
                    }
                }
                return .unknown("config: specify 'schemas'")
            case "export":
                return .projectExport(projectSlug: dirName, projectID: pid)
            case "project.json":
                return .project(slug: dirName, projectID: pid)
            default:
                return .unknown("projects: unknown subpath '\(subParts[0])'")
            }
        case "agent":
            if parts.count < 2 { return .unknown("agent: specify 'prompts', 'memories', or 'chat'") }
            switch parts[1] {
            case "prompts":
                if parts.count > 2 { return .agentPrompt(name: String(parts[2])) }
                return .agentPrompts
            case "memories":
                if parts.count > 2, let id = UUID(uuidString: parts[2]) { return .agentMemory(id: id) }
                return .agentMemories
            case "chat":
                if parts.count > 2, let id = UUID(uuidString: parts[2]) { return .agentChatConversation(id: id) }
                return .agentChat
            default: return .unknown("agent: unknown '\(parts[1])'")
            }
        default:
            if let project = findProject(named: parts[0], context: context) {
                return .project(slug: safeDirName(project), projectID: project.id)
            }
            return .unknown("'\(parts[0])': No such file or directory")
        }
    }

    /// Returns a VFSNode for a given path (single node, not children).
    static func node(at rawPath: String, context: ToolContext) -> VFSNode? {
        let vpath = resolve(rawPath, context: context)
        return node(for: vpath, context: context)
    }

    // MARK: - listChildren

    /// Lists all children at a VFS path. Returns [VFSNode] for UI rendering.
    static func listChildren(_ rawPath: String, context: ToolContext) -> [VFSNode] {
        let vpath = resolve(rawPath, context: context)
        return children(for: vpath, context: context)
    }

    // MARK: - File Read/Write

    /// Reads the content of a file at the given VFS path as Data.
    static func readFile(_ rawPath: String, context: ToolContext) throws -> Data {
        let vpath = resolve(rawPath, context: context)
        // Try main content resolver first
        if let text = fileContent(for: vpath, context: context) {
            return Data(text.utf8)
        }
        // Fallback: for item-level files (body.md, analysis.json, etc.)
        if let text = readItemFile(rawPath, context: context) {
            return Data(text.utf8)
        }
        throw VFSError.fileNotFound(path: rawPath)
    }

    /// Writes Data content to a file at the given VFS path.
    static func writeFile(_ rawPath: String, content: Data, context: ToolContext) throws {
        guard let text = String(data: content, encoding: .utf8) else {
            throw VFSError.invalidContent
        }
        let vpath = resolve(rawPath, context: context)
        // Try main content writer first; if it throws, fall back to item file writer
        do {
            try writeFileContent(text, to: vpath, context: context)
        } catch let error as VFSError {
            // Fallback: for item-level files (body.md, analysis.json, etc.)
            if case .fileNotFound = error {
                try writeItemFile(rawPath, content: text, context: context)
            } else {
                throw error
            }
        }
    }

    /// Convenience: read file as String.
    static func readFileAsString(_ rawPath: String, context: ToolContext) throws -> String {
        let data = try readFile(rawPath, context: context)
        guard let str = String(data: data, encoding: .utf8) else {
            throw VFSError.invalidContent
        }
        return str
    }

    /// Convenience: write String to file.
    static func writeFileString(_ rawPath: String, content: String, context: ToolContext) throws {
        try writeFile(rawPath, content: Data(content.utf8), context: context)
    }

    // MARK: - Operations

    static func delete(_ rawPath: String, context: ToolContext) throws {
        let vpath = resolve(rawPath, context: context)
        try deleteNode(vpath, context: context)
    }

    static func move(_ fromPath: String, _ toPath: String, context: ToolContext) throws {
        let src = resolve(fromPath, context: context)
        let dst = resolve(toPath, context: context)
        try moveNode(from: src, to: dst, context: context)
    }

    // MARK: - Helper: safe dir name

    static func safeDirName(_ project: Project) -> String {
        project.slug.replacingOccurrences(of: "/", with: "-")
    }

    static func stripJSONSuffix(_ s: String) -> String {
        s.hasSuffix(".json") ? String(s.dropLast(5)) : s
    }

    // MARK: - Helpers: project matching

    static func findProject(named: String, context: ToolContext) -> Project? {
        let all = (try? ProjectService(context: context.modelContext).allProjects()) ?? []
        return all.first { projectMatches($0, dirName: named) }
    }

    static func projectMatches(_ project: Project, dirName: String) -> Bool {
        let safe = project.slug.replacingOccurrences(of: "/", with: "-")
        return safe == dirName || project.slug == dirName || project.name.caseInsensitiveCompare(dirName) == .orderedSame
    }

    // MARK: - Private: Path resolution helpers

    private static func resolveRelative(_ raw: String, context: ToolContext) -> String {
        guard let slug = context.activeProjectSlug else {
            return "/\(raw)"
        }
        return "/projects/\(slug)/\(raw)"
    }

    // MARK: - Private: Node from VFSPath

    private static func node(for vpath: VFSPath, context: ToolContext) -> VFSNode? {
        switch vpath {
        case .root:
            let projects = (try? ProjectService(context: context.modelContext).allProjects()) ?? []
            let allItems = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
            return .directory(path: "/", name: "Workspace", childrenCount: 3,
                metadata: VFSNodeMetadata(taskCount: allItems.count, itemCount: allItems.count))
        case .inbox:
            let items = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
            return .directory(path: "/inbox", name: "Inbox", childrenCount: items.count)
        case .projects:
            let projects = (try? ProjectService(context: context.modelContext).allProjects()) ?? []
            return .directory(path: "/projects", name: "Projects", childrenCount: projects.count)
        case .project(_, let pid):
            guard let p = try? ProjectService(context: context.modelContext).fetch(id: pid) else { return nil }
            let tasks = (try? TaskService(context: context.modelContext).tasks(for: pid)) ?? []
            let items = (try? ProjectService(context: context.modelContext).items(in: pid)) ?? []
            return .directory(path: "/projects/\(safeDirName(p))", name: p.name,
                childrenCount: 7,
                metadata: VFSNodeMetadata(
                    projectStatus: p.statusRaw, healthStatus: p.healthStatus,
                    healthScore: p.healthScore, taskCount: tasks.count, itemCount: items.count,
                    swiftDataID: pid,
                    isConfigProject: ConfigProjectService.isConfigProject(p)
                ))
        default:
            return nil
        }
    }

    // MARK: - Private: Children listing

    private static func children(for vpath: VFSPath, context: ToolContext) -> [VFSNode] {
        switch vpath {
        case .root:
            let projects = (try? ProjectService(context: context.modelContext).allProjects()) ?? []
            let allItems = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
            return [
                .directory(path: "/inbox", name: "Inbox", childrenCount: allItems.count,
                    metadata: VFSNodeMetadata(itemCount: allItems.count)),
                .directory(path: "/projects", name: "Projects", childrenCount: projects.count,
                    metadata: VFSNodeMetadata(itemCount: projects.count)),
                .directory(path: "/agent", name: "Agent", childrenCount: 3)
            ]

        case .inbox:
            let allItems = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
            return allItems.map { item in
                let itemPath = "/inbox/\(item.id.uuidString)"
                return makeItemDirNode(item: item, path: itemPath, context: context)
            }

        case .inboxItem(let id):
            return itemFileChildren(slug: "inbox", itemID: id, context: context)

        case .projects:
            let projects = (try? ProjectService(context: context.modelContext).allProjects()) ?? []
            return projects.map { p in
                let tasks = (try? TaskService(context: context.modelContext).tasks(for: p.id)) ?? []
                let items = (try? ProjectService(context: context.modelContext).items(in: p.id)) ?? []
                return .directory(
                    path: "/projects/\(safeDirName(p))", name: p.name,
                    childrenCount: 7,
                    modifiedAt: p.updatedAt,
                    metadata: VFSNodeMetadata(
                        projectStatus: p.statusRaw, healthStatus: p.healthStatus,
                        healthScore: p.healthScore, taskCount: tasks.count,
                        itemCount: items.count, swiftDataID: p.id,
                        isConfigProject: ConfigProjectService.isConfigProject(p)
                    )
                )
            }

        case .project(let slug, let pid):
            guard let p = try? ProjectService(context: context.modelContext).fetch(id: pid) else { return [] }
            let tasks = (try? TaskService(context: context.modelContext).tasks(for: pid)) ?? []
            let items = (try? ProjectService(context: context.modelContext).items(in: pid)) ?? []
            let isConfig = ConfigProjectService.isConfigProject(p)
            let base = "/projects/\(slug)"

            var nodes: [VFSNode] = [
                .file(path: "\(base)/project.json", name: "project.json", nodeType: .projectFile,
                      modifiedAt: p.updatedAt,
                      metadata: VFSNodeMetadata(
                          projectStatus: p.statusRaw, healthStatus: p.healthStatus,
                          swiftDataID: pid, isConfigProject: isConfig
                      )),
                .directory(path: "\(base)/items", name: "Items", childrenCount: items.count,
                    metadata: VFSNodeMetadata(itemCount: items.count)),
                .directory(path: "\(base)/tasks", name: "Tasks", childrenCount: tasks.count,
                    metadata: VFSNodeMetadata(taskCount: tasks.count)),
            ]

            if !isConfig {
                nodes.append(contentsOf: [
                    .directory(path: "\(base)/people", name: "People"),
                    .directory(path: "\(base)/edges", name: "Edges"),
                    .directory(path: "\(base)/signals", name: "Signals"),
                    .directory(path: "\(base)/analysis", name: "Analysis"),
                ])
            } else {
                nodes.append(contentsOf: configProjectChildren(base: base, context: context))
            }

            return nodes

        case .projectItems(let slug, let pid):
            let items = (try? ProjectService(context: context.modelContext).items(in: pid)) ?? []
            let base = "/projects/\(slug)/items"
            return items.map { item in
                let itemPath = "\(base)/\(item.id.uuidString)"
                return makeItemDirNode(item: item, path: itemPath, context: context)
            }

        case .projectItem(let slug, _, let itemID):
            return itemFileChildren(slug: slug, itemID: itemID, context: context)

        case .projectItemContents(let slug, _, let itemID):
            return itemFileChildren(slug: slug, itemID: itemID, context: context)

        case .projectTasks(let slug, let pid):
            let tasks = (try? TaskService(context: context.modelContext).tasks(for: pid)) ?? []
            let base = "/projects/\(slug)/tasks"
            return tasks.map { t in
                .file(
                    path: "\(base)/\(t.id.uuidString).json", name: "\(sanitizeFileName(t.title)).json",
                    nodeType: .jsonFile, modifiedAt: t.updatedAt,
                    metadata: VFSNodeMetadata(
                        itemStatus: t.statusRaw, swiftDataID: t.id,
                        priority: t.priorityRaw,
                        owner: t.ownerName, dueAt: t.dueAt
                    )
                )
            }

        case .projectPeople(let slug, let pid):
            let gsvc = GraphEdgeService(context: context.modelContext)
            let edges = (try? gsvc.edges(from: pid)) ?? []
            let peopleEdges = edges.filter { $0.edgeTypeRaw == "person" }
            let base = "/projects/\(slug)/people"
            return peopleEdges.map { e in
                .file(
                    path: "\(base)/\(e.id.uuidString).json", name: "person-\(e.id.uuidString.prefix(8)).json",
                    nodeType: .jsonFile, modifiedAt: e.createdAt,
                    metadata: VFSNodeMetadata(swiftDataID: e.id, edgeType: e.edgeTypeRaw)
                )
            }

        case .projectEdges(let slug, let pid):
            let gsvc = GraphEdgeService(context: context.modelContext)
            let outgoing = (try? gsvc.edges(from: pid)) ?? []
            let incoming = (try? gsvc.edges(to: pid)) ?? []
            let all = outgoing + incoming
            let base = "/projects/\(slug)/edges"
            return all.map { e in
                .file(
                    path: "\(base)/\(e.id.uuidString).json", name: "\(e.edgeTypeRaw)-\(e.id.uuidString.prefix(8)).json",
                    nodeType: .jsonFile, modifiedAt: e.createdAt,
                    metadata: VFSNodeMetadata(swiftDataID: e.id, edgeType: e.edgeTypeRaw)
                )
            }

        case .projectSignals(let slug, let pid):
            let all = (try? context.modelContext.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
            let signals = all.filter { $0.projectID == pid && $0.isActive }
            let base = "/projects/\(slug)/signals"
            return signals.map { s in
                .file(
                    path: "\(base)/\(s.id.uuidString).json", name: "\(s.type)-\(s.id.uuidString.prefix(8)).json",
                    nodeType: .jsonFile,
                    metadata: VFSNodeMetadata(swiftDataID: s.id, signalType: s.type, isFlagged: s.isCritical)
                )
            }

        case .projectAnalysis(let slug, let pid, let itemID):
            if let iid = itemID {
                return analysisFilesForItem(slug: slug, itemID: iid, context: context)
            }
            let items = (try? ProjectService(context: context.modelContext).items(in: pid)) ?? []
            let base = "/projects/\(slug)/analysis"
            return items.compactMap { item in
                let dir = context.fileStore.itemDirectoryURL(for: item.id)
                let hasAnalysis = FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.json").path)
                    || FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.dynamic.json").path)
                let hasTranscript = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
                guard hasAnalysis || hasTranscript else { return nil }
                return .directory(
                    path: "\(base)/\(item.id.uuidString)", name: item.title,
                    childrenCount: (hasAnalysis ? 1 : 0) + (hasTranscript ? 1 : 0),
                    metadata: VFSNodeMetadata(itemType: item.typeRaw, swiftDataID: item.id)
                )
            }

        case .agentPrompts:
            let prompts = PromptStore.shared.prompts(in: nil)
            let base = "/agent/prompts"
            return prompts.map { p in
                .file(
                    path: "\(base)/\(p.name).md", name: "\(p.name).md",
                    nodeType: .markdownFile,
                    metadata: VFSNodeMetadata(itemStatus: p.isUserEdited ? "edited" : "default")
                )
            }

        case .agentMemories:
            let memories = AgentMemoryStore.shared.listAll()
            let base = "/agent/memories"
            return memories.map { m in
                .file(
                    path: "\(base)/\(m.id.uuidString).json", name: "memory-\(m.id.uuidString.prefix(8)).json",
                    nodeType: .jsonFile,
                    metadata: VFSNodeMetadata(
                        swiftDataID: m.id, isFlagged: m.isStale,
                        confidence: m.relevance
                    )
                )
            }

        case .agentChat:
            let chatSvc = ChatService(fileStore: context.fileStore)
            let conversations = (try? chatSvc.fetchConversations()) ?? []
            let base = "/agent/chat"
            return conversations.map { c in
                .file(
                    path: "\(base)/\(c.id.uuidString).json", name: "\(sanitizeFileName(c.title)).json",
                    nodeType: .jsonFile, modifiedAt: c.updatedAt,
                    metadata: VFSNodeMetadata(itemCount: c.messageCount, swiftDataID: c.id)
                )
            }

        case .configProviders:
            return configProviderNodes(context: context)

        case .configPrompts:
            return configPromptNodes()

        case .configSettings:
            return configSettingsNodes()

        case .configMemoriesDir:
            return configMemoryNodes()

        case .configSchemas(let slug, _):
            let base = "/projects/\(slug)/config/schemas"
            return FrameworkService.allBuiltInFrameworks.sorted(by: { $0.key < $1.key }).map { (name, fw) in
                .file(
                    path: "\(base)/\(name).json", name: "\(name).json",
                    nodeType: .jsonFile,
                    metadata: VFSNodeMetadata(
                        owner: fw.description,
                        edgeType: fw.id
                    )
                )
            }

        default:
            return []
        }
    }

    // MARK: - Item children (files inside an item directory)

    private static func itemFileChildren(slug: String, itemID: UUID, context: ToolContext) -> [VFSNode] {
        guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else { return [] }
        let base: String
        if slug == "inbox" {
            base = "/inbox/\(itemID.uuidString)"
        } else {
            base = "/projects/\(slug)/items/\(itemID.uuidString)"
        }
        let dir = context.fileStore.itemDirectoryURL(for: item.id)
        let fm = FileManager.default
        var nodes: [VFSNode] = []

        // metadata.json
        nodes.append(.file(
            path: "\(base)/metadata.json", name: "metadata.json",
            nodeType: .jsonFile, modifiedAt: item.updatedAt,
            metadata: VFSNodeMetadata(
                itemType: item.typeRaw, itemStatus: item.statusRaw,
                tags: item.tags, durationSeconds: item.durationSeconds,
                swiftDataID: itemID, isFlagged: item.isFlagged,
                languageCode: item.languageCode,
                calendarEventIdentifier: item.calendarEventIdentifier
            )
        ))

        // body.md (for notes, journals, or any item with body text)
        if item.bodyText != nil || item.typeRaw == "note" || item.typeRaw == "journalEntry" {
            let size = item.bodyText.map { Int64($0.utf8.count) }
            nodes.append(.file(
                path: "\(base)/body.md", name: "body.md",
                nodeType: .markdownFile, size: size, modifiedAt: item.updatedAt,
                metadata: VFSNodeMetadata(swiftDataID: itemID)
            ))
        }

        // audio.m4a
        let audioURL = context.fileStore.audioFileURL(for: item.id)
        if fm.fileExists(atPath: audioURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: audioURL.path)
            nodes.append(.file(
                path: "\(base)/audio.m4a", name: "audio.m4a",
                nodeType: .audioFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date,
                metadata: VFSNodeMetadata(durationSeconds: item.durationSeconds)
            ))
        }

        // recording.manifest.json (segmented recordings)
        let manifestURL = context.fileStore.recordingManifestURL(for: item.id)
        if fm.fileExists(atPath: manifestURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: manifestURL.path)
            nodes.append(.file(
                path: "\(base)/recording.manifest.json", name: "recording.manifest.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }

        // segments/ directory
        let segmentsDir = context.fileStore.segmentsDirectoryURL(for: item.id)
        if fm.fileExists(atPath: segmentsDir.path) {
            let segFiles = (try? fm.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            nodes.append(.directory(
                path: "\(base)/segments", name: "segments",
                childrenCount: segFiles.count,
                modifiedAt: item.updatedAt
            ))
        }

        // transcript.json
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        if fm.fileExists(atPath: transcriptURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: transcriptURL.path)
            nodes.append(.file(
                path: "\(base)/transcript.json", name: "transcript.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }

        // analysis.json
        let analysisURL = dir.appendingPathComponent("analysis.json")
        let dynamicURL = dir.appendingPathComponent("analysis.dynamic.json")
        if fm.fileExists(atPath: analysisURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: analysisURL.path)
            nodes.append(.file(
                path: "\(base)/analysis.json", name: "analysis.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }
        if fm.fileExists(atPath: dynamicURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: dynamicURL.path)
            nodes.append(.file(
                path: "\(base)/analysis.dynamic.json", name: "analysis.dynamic.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }

        // Scan images
        let scanPattern = "scan_"
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for url in contents {
                let name = url.lastPathComponent
                if name.hasPrefix(scanPattern) && (name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png")) {
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    nodes.append(.file(
                        path: "\(base)/\(name)", name: name,
                        nodeType: .imageFile,
                        size: attrs?[.size] as? Int64,
                        modifiedAt: attrs?[.modificationDate] as? Date
                    ))
                }
            }
        }

        // exports directory
        let exportsDir = dir.appendingPathComponent("exports")
        if fm.fileExists(atPath: exportsDir.path) {
            let exportContents = (try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil)) ?? []
            if !exportContents.isEmpty {
                nodes.append(.directory(
                    path: "\(base)/exports", name: "Exports",
                    childrenCount: exportContents.count
                ))
            }
        }

        return nodes
    }

    private static func makeItemDirNode(item: KnowledgeItem, path: String, context: ToolContext) -> VFSNode {
        let dir = context.fileStore.itemDirectoryURL(for: item.id)
        let fm = FileManager.default
        var fileCount = 1 // metadata.json
        if item.bodyText != nil || item.typeRaw == "note" || item.typeRaw == "journalEntry" { fileCount += 1 }
        if fm.fileExists(atPath: context.fileStore.audioFileURL(for: item.id).path) { fileCount += 1 }
        if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) { fileCount += 1 }
        if fm.fileExists(atPath: dir.appendingPathComponent("analysis.json").path) { fileCount += 1 }
        if fm.fileExists(atPath: dir.appendingPathComponent("analysis.dynamic.json").path) { fileCount += 1 }
        let scanCount = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("scan_") }.count ?? 0
        fileCount += scanCount

        let name = sanitizeFileName(item.title)
        return .directory(
            path: path, name: name,
            childrenCount: fileCount,
            modifiedAt: item.updatedAt,
            metadata: VFSNodeMetadata(
                itemType: item.typeRaw, itemStatus: item.statusRaw,
                tags: item.tags, durationSeconds: item.durationSeconds,
                swiftDataID: item.id, isFlagged: item.isFlagged
            )
        )
    }

    private static func analysisFilesForItem(slug: String, itemID: UUID, context: ToolContext) -> [VFSNode] {
        let dir = context.fileStore.itemDirectoryURL(for: itemID)
        let fm = FileManager.default
        let base = "/projects/\(slug)/analysis/\(itemID.uuidString)"
        var nodes: [VFSNode] = []

        let analysisURL = dir.appendingPathComponent("analysis.json")
        if fm.fileExists(atPath: analysisURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: analysisURL.path)
            nodes.append(.file(
                path: "\(base)/analysis.json", name: "analysis.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }
        let dynamicURL = dir.appendingPathComponent("analysis.dynamic.json")
        if fm.fileExists(atPath: dynamicURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: dynamicURL.path)
            nodes.append(.file(
                path: "\(base)/analysis.dynamic.json", name: "analysis.dynamic.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        if fm.fileExists(atPath: transcriptURL.path) {
            let attrs = try? fm.attributesOfItem(atPath: transcriptURL.path)
            nodes.append(.file(
                path: "\(base)/transcript.json", name: "transcript.json",
                nodeType: .jsonFile,
                size: attrs?[.size] as? Int64,
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }
        return nodes
    }

    // MARK: - File content read/write

    private static func fileContent(for vpath: VFSPath, context: ToolContext) -> String? {
        switch vpath {
        case .project(let slug, let pid):
            guard let p = try? ProjectService(context: context.modelContext).fetch(id: pid) else { return nil }
            return formatProjectJSON(p, context: context)

        case .projectItem(_, _, let itemID):
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else { return nil }
            return formatItemJSON(item, fileStore: context.fileStore)

        case .projectTask(_, _, let taskID):
            guard let t = try? TaskService(context: context.modelContext).fetch(id: taskID) else { return nil }
            return formatTaskJSON(t)

        case .inboxItem(let id):
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: id) else { return nil }
            return formatItemJSON(item, fileStore: context.fileStore)

        case .projectAnalysis(_, _, let itemID):
            guard let iid = itemID else { return nil }
            return readAnalysis(itemID: iid, fileStore: context.fileStore)

        case .agentPrompt(let name):
            return PromptStore.shared.prompt(named: name)?.content

        case .agentMemory(let id):
            let memories = AgentMemoryStore.shared.listAll()
            guard let m = memories.first(where: { $0.id == id }),
                  let data = try? JSONEncoder().encode(m) else { return nil }
            return String(data: data, encoding: .utf8)

        case .agentChatConversation(let id):
            let chatSvc = ChatService(fileStore: context.fileStore)
            let msgs = (try? chatSvc.messages(for: id)) ?? []
            guard let data = try? JSONEncoder().encode(msgs) else { return nil }
            return String(data: data, encoding: .utf8)

        case .configSchema(_, _, let name):
            guard let fw = FrameworkService.builtInFramework(named: name),
                  let data = try? JSONEncoder().encode(fw) else { return nil }
            return String(data: data, encoding: .utf8)

        default:
            // Check if it's an item contents file (body.md, metadata.json, etc.)
            return fileContentFromItemPath(vpath, context: context)
        }
    }

    /// Handles file reads for paths inside item directories.
    private static func fileContentFromItemPath(_ vpath: VFSPath, context: ToolContext) -> String? {
        // We need to extract the "leaf" path info from unknown paths or agent prompts
        // This is handled by ShellInterpreter's path-based dispatch for now
        return nil
    }

    /// Reads a specific file within an item directory given the VFS path.
    /// Called by readFile for paths like "/projects/{slug}/items/{id}/body.md".
    static func readItemFile(_ rawPath: String, context: ToolContext) -> String? {
        let parts = rawPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        // Determine if this is an inbox path or project path
        let isInbox = parts.first == "inbox"
        let isProject = parts.first == "projects"
        guard isInbox || isProject else { return nil }

        // Extract item ID and filename
        let itemID: UUID
        let file: String

        if isInbox {
            // /inbox/{id}/{filename}
            guard parts.count >= 3,
                  let id = UUID(uuidString: stripJSONSuffix(parts[1]))
            else { return nil }
            itemID = id
            file = parts.count > 2 ? parts[2] : ""
        } else {
            // /projects/{slug}/items/{id}/{filename} or /projects/{slug}/analysis/{id}/{filename}
            guard parts.count >= 5,
                  parts[2] == "items" || parts[2] == "analysis",
                  let id = resolveItemID(from: parts[3], context: context) ?? UUID(uuidString: stripJSONSuffix(parts[3]))
            else { return nil }
            itemID = id
            let filenameIdx = parts[2] == "analysis" ? 4 : 4
            file = parts.count > filenameIdx ? parts[filenameIdx] : (parts.last ?? "")
        }

        let itemDir = context.fileStore.itemDirectoryURL(for: itemID)
        let fileURL: URL

        switch file {
        case "body.md":
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else { return nil }
            return item.bodyText
        case "metadata.json":
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else { return nil }
            return formatItemJSON(item, fileStore: context.fileStore)
        case "audio.m4a":
            return nil // Binary, not readable as string
        case "transcript.json":
            return readTranscript(itemID: itemID, fileStore: context.fileStore)
        case "analysis.json":
            fileURL = itemDir.appendingPathComponent("analysis.json")
        case "analysis.dynamic.json":
            fileURL = itemDir.appendingPathComponent("analysis.dynamic.json")
        default:
            fileURL = itemDir.appendingPathComponent(file)
        }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func resolveItemID(from str: String, context: ToolContext) -> UUID? {
        let clean = stripJSONSuffix(str)
        if let id = UUID(uuidString: clean) { return id }
        // Fuzzy match
        let allItems = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
        if let matched = allItems.first(where: { $0.title.caseInsensitiveCompare(clean) == .orderedSame }) {
            return matched.id
        }
        if let matched = allItems.first(where: { $0.id.uuidString.hasPrefix(clean) }) {
            return matched.id
        }
        return nil
    }

    // MARK: - Write file content

    private static func writeFileContent(_ text: String, to vpath: VFSPath, context: ToolContext) throws {
        switch vpath {
        case .project(let slug, let pid):
            guard let project = try? ProjectService(context: context.modelContext).fetch(id: pid) else {
                throw VFSError.fileNotFound(path: "/projects/\(slug)/project.json")
            }
            try updateProjectFromJSON(project, jsonText: text, context: context)

        case .projectItem(_, _, let itemID):
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else {
                throw VFSError.fileNotFound(path: "item \(itemID)")
            }
            try updateItemFromJSON(item, jsonText: text, context: context)

        case .projectTask(_, _, let taskID):
            guard let task = try? TaskService(context: context.modelContext).fetch(id: taskID) else {
                throw VFSError.fileNotFound(path: "task \(taskID)")
            }
            try updateTaskFromJSON(task, jsonText: text, context: context)

        case .inboxItem(let id):
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: id) else {
                throw VFSError.fileNotFound(path: "/inbox/\(id)")
            }
            try updateItemFromJSON(item, jsonText: text, context: context)

        case .agentPrompt(let name):
            PromptStore.shared.updatePrompt(named: name, content: text)

        case .agentMemory:
            // Memory write via JSON: parse and apply pattern/strategy updates
            if let data = text.data(using: .utf8),
               let memJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let pattern = memJSON["pattern"] as? String ?? ""
                let strategy = memJSON["strategy"] as? String ?? ""
                let itemType = memJSON["itemType"] as? String
                let contentType = memJSON["contentType"] as? String
                let language = memJSON["language"] as? String
                _ = AgentMemoryStore.shared.write(
                    pattern: pattern, strategy: strategy,
                    itemType: itemType, contentType: contentType, language: language
                )
            }

        default:
            // Handle item file writes (body.md, metadata.json, etc.)
            try writeItemFile(vpath, text: text, context: context)
        }
    }

    private static func writeItemFile(_ vpath: VFSPath, text: String, context: ToolContext) throws {
        let pathDescription = "\(vpath)"
        // Extract item ID and filename from the path
        // Handled by the raw path variant below
        throw VFSError.fileNotFound(path: pathDescription)
    }

    /// Write to a specific file within an item, given the raw VFS path.
    static func writeItemFile(_ rawPath: String, content: String, context: ToolContext) throws {
        let parts = rawPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let isInbox = parts.first == "inbox"
        let isProject = parts.first == "projects"

        // Extract item ID and filename
        let itemID: UUID
        let filename: String

        if isInbox {
            // /inbox/{id}/{filename}
            guard parts.count >= 3,
                  let id = UUID(uuidString: stripJSONSuffix(parts[1]))
            else { throw VFSError.fileNotFound(path: rawPath) }
            itemID = id
            filename = parts[2]
        } else if isProject {
            guard parts.count >= 5,
                  let id = resolveItemID(from: parts[3], context: context) ?? UUID(uuidString: stripJSONSuffix(parts[3]))
            else { throw VFSError.fileNotFound(path: rawPath) }
            itemID = id
            filename = parts.last ?? ""
        } else {
            throw VFSError.fileNotFound(path: rawPath)
        }

        guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else {
            throw VFSError.fileNotFound(path: rawPath)
        }

        switch filename {
        case "body.md":
            item.bodyText = content
            item.updatedAt = Date()
            try context.modelContext.save()

        case "metadata.json":
            try updateItemFromJSON(item, jsonText: content, context: context)

        case "project.json":
            if let projectID = item.projectID,
               let project = try? ProjectService(context: context.modelContext).fetch(id: projectID) {
                try updateProjectFromJSON(project, jsonText: content, context: context)
            }

        case "transcript.json":
            let url = context.fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("transcript.json")
            try content.write(to: url, atomically: true, encoding: .utf8)

        case "analysis.json":
            let url = context.fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("analysis.json")
            try content.write(to: url, atomically: true, encoding: .utf8)

        case "analysis.dynamic.json":
            let url = context.fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("analysis.dynamic.json")
            try content.write(to: url, atomically: true, encoding: .utf8)

        default:
            throw VFSError.fileNotFound(path: rawPath)
        }
    }

    // MARK: - Delete & Move

    private static func deleteNode(_ vpath: VFSPath, context: ToolContext) throws {
        switch vpath {
        // Items → Trash
        case .projectItem(_, _, let itemID), .inboxItem(let itemID):
            guard let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) else {
                throw VFSError.fileNotFound(path: "item")
            }
            try TrashService(context: context.modelContext).moveToTrash(item)

        // Tasks → permanent
        case .projectTask(_, _, let taskID):
            guard let task = try? TaskService(context: context.modelContext).fetch(id: taskID) else {
                throw VFSError.fileNotFound(path: "task")
            }
            try TaskService(context: context.modelContext).deleteTask(task)

        // Individual files inside items
        case .projectItemContents(_, _, let itemID), .inboxItemFile(let itemID):
            // Files inside items are read-only artifacts; deleting them means removing the artifact file
            // The VFSService.delete() receives the raw path; deleteNode gets the resolved VFSPath.
            // For item contents, we throw a specific error since the path doesn't tell us which file.
            // Callers should use the raw path variant instead.
            throw VFSError.cannotDelete(path: "Individual item files must be deleted by overwriting with empty content, or by deleting the parent item.")

        // Graph edges → permanent
        case .projectEdges(_, let pid):
            // Edge deletion is handled via the raw path in ShellInterpreter.
            // For VFSService, throw informative error.
            throw VFSError.cannotDelete(path: "Use rm edges/{edge-id}.json to delete a specific edge.")

        // Agent prompts → reset to default
        case .agentPrompt(let name):
            PromptStore.shared.resetPrompt(named: name)

        // Agent memories → remove
        case .agentMemory(let id):
            var memories = AgentMemoryStore.shared.listAll()
            memories.removeAll { $0.id == id }
            // Note: AgentMemoryStore doesn't have a delete method, but resetting is the best we can do

        // Chat conversations
        case .agentChatConversation(let id):
            let chatSvc = ChatService(fileStore: context.fileStore)
            try chatSvc.deleteConversation(id: id)

        // Config files
        case .configProvider(let name):
            let configs = (try? context.modelContext.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []
            if let config = configs.first(where: { $0.name == name || sanitizeFileName($0.name) == name }) {
                context.modelContext.delete(config)
                try context.modelContext.save()
            }

        case .configPrompt(let name):
            PromptStore.shared.resetPrompt(named: name)

        case .configMemory(let id):
            var memories = AgentMemoryStore.shared.listAll()
            memories.removeAll { $0.id == id }

        default:
            throw VFSError.cannotDelete(path: "\(vpath)")
        }
    }

    private static func moveNode(from src: VFSPath, to dst: VFSPath, context: ToolContext) throws {
        switch (src, dst) {
        case (.inboxItem(let itemID), .projectItems(_, let pid)):
            try ProjectService(context: context.modelContext).addItem(itemID, to: pid)
            try KnowledgeItemService(context: context.modelContext).removeFromInbox(
                try! KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID)!
            )

        case (.projectItem(_, _, let itemID), .projectItems(_, let dpid)):
            try ProjectService(context: context.modelContext).addItem(itemID, to: dpid)

        case (.projectItem(_, _, let itemID), .inbox):
            try ProjectService(context: context.modelContext).removeItem(itemID)
            if let item = try? KnowledgeItemService(context: context.modelContext).fetchItem(id: itemID) {
                item.inboxDate = Date()
                try context.modelContext.save()
            }

        default:
            throw VFSError.cannotMove(from: "\(src)", to: "\(dst)")
        }
    }

    // MARK: - JSON Formatting for reads

    private static func formatProjectJSON(_ p: Project, context: ToolContext) -> String {
        let tasks = (try? TaskService(context: context.modelContext).tasks(for: p.id)) ?? []
        let items = (try? ProjectService(context: context.modelContext).items(in: p.id)) ?? []
        let dict: [String: Any] = [
            "name": p.name, "slug": p.slug, "dirName": safeDirName(p),
            "status": p.statusRaw, "healthScore": p.healthScore as Any,
            "healthStatus": p.healthStatus as Any, "summary": p.summary as Any,
            "intention": p.intention as Any, "taskCount": tasks.count,
            "itemCount": items.count, "createdAt": p.createdAt.ISO8601Format(),
            "updatedAt": p.updatedAt.ISO8601Format()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    private static func formatItemJSON(_ item: KnowledgeItem, fileStore: FileArtifactStore) -> String {
        var dict: [String: Any] = [
            "id": item.id.uuidString, "type": item.typeRaw, "title": item.title,
            "status": item.statusRaw, "createdAt": item.createdAt.ISO8601Format(),
            "updatedAt": item.updatedAt.ISO8601Format()
        ]
        if let proj = item.projectID { dict["projectID"] = proj.uuidString }
        if let body = item.bodyText { dict["body"] = body }
        if !item.tags.isEmpty { dict["tags"] = item.tags }
        if let dur = item.durationSeconds { dict["durationSeconds"] = dur }
        if let lang = item.languageCode { dict["languageCode"] = lang }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    private static func formatTaskJSON(_ t: TaskItem) -> String {
        var dict: [String: Any] = [
            "id": t.id.uuidString, "title": t.title,
            "status": t.statusRaw, "priority": t.priorityRaw
        ]
        if let owner = t.ownerName { dict["owner"] = owner }
        if let due = t.dueAt { dict["dueAt"] = due.ISO8601Format() }
        if let notes = t.notes { dict["notes"] = notes }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{}"
    }

    // MARK: - JSON Update helpers

    private static func updateProjectFromJSON(_ project: Project, jsonText: String, context: ToolContext) throws {
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VFSError.invalidJSON
        }
        if let v = json["name"] as? String { project.name = v; project.nameIsAutoGenerated = false }
        if let v = json["summary"] as? String { project.summary = v }
        if let v = json["intention"] as? String { project.intention = v; project.intentionIsAutoGenerated = false }
        if let v = json["synthesis"] as? String { project.synthesis = v }
        if let v = json["customInstructions"] as? String { project.customInstructions = v }
        if let v = json["colorHex"] as? String { project.colorHex = v }
        if let v = json["iconName"] as? String { project.iconName = v }
        if let v = json["slug"] as? String, !v.isEmpty { project.slug = v }
        if let v = json["status"] as? String, let status = ProjectStatus(rawValue: v) { project.status = status }
        if let v = json["healthStatus"] as? String { project.healthStatus = v }
        if let v = json["holdIngestionForDoubts"] as? Bool { project.holdIngestionForDoubts = v }
        project.updatedAt = Date()
        try context.modelContext.save()
    }

    static func updateItemFromJSON(_ item: KnowledgeItem, jsonText: String, context: ToolContext) throws {
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VFSError.invalidJSON
        }
        // Core fields
        let newTitle = json["title"] as? String
        let newBody = json["body"] as? String
        let newTags = json["tags"] as? [String]
        try? KnowledgeItemService(context: context.modelContext).updateItem(item, title: newTitle, bodyText: newBody, tags: newTags)

        // Status & flags
        if let v = json["isFlagged"] as? Bool { item.isFlagged = v }
        if let v = json["status"] as? String, let st = ItemStatus(rawValue: v) { item.status = st }

        // Assignment
        if let v = json["projectID"] as? String, let pid = UUID(uuidString: v) { item.projectID = pid }
        if let v = json["folderID"] as? String, let fid = UUID(uuidString: v) { item.folderID = fid }
        if json["inboxDate"] is NSNull || json["removeFromInbox"] as? Bool == true { item.inboxDate = nil }
        else if let v = json["inboxDate"] as? String { item.inboxDate = ISO8601DateFormatter().date(from: v) }

        // Metadata
        if let v = json["durationSeconds"] as? Double { item.durationSeconds = v }
        if let v = json["languageCode"] as? String { item.languageCode = v }
        if let v = json["transcriptionEngineId"] as? String { item.transcriptionEngineId = v }
        if let v = json["analysisProviderId"] as? String { item.analysisProviderId = v }
        if let v = json["calendarEventIdentifier"] as? String { item.calendarEventIdentifier = v }
        if let v = json["scheduledDate"] as? String { item.scheduledDate = ISO8601DateFormatter().date(from: v) }

        // Context fields
        if let v = json["contextCalendarEventTitle"] as? String { item.contextCalendarEventTitle = v }
        if let v = json["contextAudioRoute"] as? String { item.contextAudioRoute = v }
        if let v = json["contextPlaceName"] as? String { item.contextPlaceName = v }
        if let v = json["contextLatitude"] as? Double { item.contextLatitude = v }
        if let v = json["contextLongitude"] as? Double { item.contextLongitude = v }
        if let v = json["contextFocusActive"] as? Bool { item.contextFocusActive = v }
        if let v = json["contextMotionActivity"] as? String { item.contextMotionActivity = v }
        if let v = json["contextBatteryLevel"] as? Double { item.contextBatteryLevel = v }

        // Import metadata
        if let v = json["isImported"] as? Bool { item.isImported = v }
        if let v = json["importSourceURL"] as? String { item.importSourceURL = v }

        item.updatedAt = Date()
        try? context.modelContext.save()
    }

    static func updateTaskFromJSON(_ task: TaskItem, jsonText: String, context: ToolContext) throws {
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VFSError.invalidJSON
        }
        let svc = TaskService(context: context.modelContext)
        var newStatus: TaskStatus?
        if let s = json["status"] as? String {
            guard let status = TaskStatus(rawValue: s) else {
                throw VFSError.invalidField("status", s, TaskStatus.allCases.map(\.rawValue))
            }
            newStatus = status
        }
        var newPriority: TaskPriority?
        if let p = json["priority"] as? String {
            guard let priority = TaskPriority(rawValue: p) else {
                throw VFSError.invalidField("priority", p, TaskPriority.allCases.map(\.rawValue))
            }
            newPriority = priority
        }
        let newTitle = json["title"] as? String
        let newOwner = json["owner"] as? String
        if let v = json["notes"] as? String { task.notes = v }
        if let v = json["sourceItemID"] as? String, let sid = UUID(uuidString: v) { task.sourceItemID = sid }
        if let v = json["confidence"] as? Double { task.confidence = v }
        var newDue: Date?
        if let dueStr = json["due"] as? String ?? json["dueAt"] as? String {
            let fmts: [ISO8601DateFormatter] = {
                let a = ISO8601DateFormatter(); let b = ISO8601DateFormatter()
                b.formatOptions = [.withFullDate]; return [a, b]
            }()
            for f in fmts { if let d = f.date(from: dueStr) { newDue = d; break } }
            if newDue == nil {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                newDue = df.date(from: dueStr)
            }
        }
        if let newStatus { try? svc.updateStatus(task, to: newStatus) }
        try? svc.updateTask(task, title: newTitle, ownerName: newOwner, priority: newPriority, dueAt: newDue)
    }

    // MARK: - Config project children

    private static func configProjectChildren(base: String, context: ToolContext) -> [VFSNode] {
        let schemaCount = FrameworkService.allBuiltInFrameworks.count
        return [
            .directory(path: "\(base)/providers", name: "Providers",
                childrenCount: configProviderNodes(context: context).count),
            .directory(path: "\(base)/prompts", name: "Prompts",
                childrenCount: configPromptNodes().count),
            .directory(path: "\(base)/schemas", name: "Schemas",
                childrenCount: schemaCount),
            .directory(path: "\(base)/settings", name: "Settings",
                childrenCount: configSettingsNodes().count),
            .directory(path: "\(base)/memories", name: "Memories",
                childrenCount: configMemoryNodes().count),
        ]
    }

    private static func configProviderNodes(context: ToolContext) -> [VFSNode] {
        // Security: Provider configs contain sensitive data (API keys). Not exposed via VFS.
        return []
    }

    private static func configPromptNodes() -> [VFSNode] {
        let prompts = PromptStore.shared.prompts(in: nil)
        let base = "/projects/wawa-note-config/prompts"
        return prompts.map { p in
            .file(
                path: "\(base)/\(p.name).md", name: "\(p.name).md",
                nodeType: .markdownFile,
                metadata: VFSNodeMetadata(itemStatus: p.isUserEdited ? "edited" : "default")
            )
        }
    }

    private static func configSettingsNodes() -> [VFSNode] {
        let base = "/projects/wawa-note-config/settings"
        return [
            .file(path: "\(base)/general.json", name: "general.json", nodeType: .jsonFile),
            .file(path: "\(base)/models.json", name: "models.json", nodeType: .jsonFile),
            .file(path: "\(base)/features.json", name: "features.json", nodeType: .jsonFile),
        ]
    }

    private static func configMemoryNodes() -> [VFSNode] {
        let memories = AgentMemoryStore.shared.listAll()
        let base = "/projects/wawa-note-config/memories"
        return memories.map { m in
            .file(
                path: "\(base)/\(m.id.uuidString).json", name: "memory-\(m.id.uuidString.prefix(8)).json",
                nodeType: .jsonFile,
                metadata: VFSNodeMetadata(
                    swiftDataID: m.id, isFlagged: m.isStale,
                    confidence: m.relevance
                )
            )
        }
    }

    // MARK: - Shared helpers (moved from ShellInterpreter)

    static func readTranscript(itemID: UUID, fileStore: FileArtifactStore) -> String? {
        let url = fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > 15000 {
            return String(text.prefix(15000)) + "\n\n... [truncated]"
        }
        return text
    }

    static func readAnalysis(itemID: UUID, fileStore: FileArtifactStore) -> String? {
        let dir = fileStore.itemDirectoryURL(for: itemID)
        let urls = [
            dir.appendingPathComponent("analysis.json"),
            dir.appendingPathComponent("analysis.dynamic.json")
        ]
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) { return text }
        }
        return nil
    }

    // MARK: - Type icon (shared with ShellInterpreter)

    static func typeIcon(_ t: String) -> String {
        switch t { case "audio": "🎙️"; case "note": "📝"; case "image": "🖼️"; case "journalEntry": "📓"; case "webBookmark": "🔗"; default: "📄" }
    }

    // MARK: - Fuzzy UUID matching

    enum FuzzyEntityType { case item, task }

    static func fuzzyMatchUUID(prefix: String, in projectID: UUID, context: ToolContext, type: FuzzyEntityType) -> UUID? {
        let clean = prefix.hasSuffix(".json") ? String(prefix.dropLast(5)) : prefix
        guard clean.count >= 3 else { return nil }
        switch type {
        case .item: return matchItem(clean, in: projectID, context: context)
        case .task: return matchTask(clean, in: projectID, context: context)
        }
    }

    private static func matchTask(_ q: String, in pid: UUID, context: ToolContext) -> UUID? {
        let tasks = (try? TaskService(context: context.modelContext).tasks(for: pid)) ?? []
        if let m = tasks.first(where: { $0.title.caseInsensitiveCompare(q) == .orderedSame }) { return m.id }
        let c = tasks.filter { $0.title.localizedCaseInsensitiveContains(q) }
        if c.count == 1 { return c[0].id }
        if let m = tasks.first(where: { $0.id.uuidString.hasPrefix(q) }) { return m.id }
        return nil
    }

    private static func matchItem(_ q: String, in pid: UUID, context: ToolContext) -> UUID? {
        let items = (try? ProjectService(context: context.modelContext).items(in: pid)) ?? []
        if let m = items.first(where: { $0.title.caseInsensitiveCompare(q) == .orderedSame }) { return m.id }
        let c = items.filter { $0.title.localizedCaseInsensitiveContains(q) }
        if c.count == 1 { return c[0].id }
        if let m = items.first(where: { $0.id.uuidString.hasPrefix(q) }) { return m.id }
        return nil
    }

    // MARK: - Filename sanitization

    static func sanitizeFileName(_ title: String) -> String {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        if sanitized.count > 40 {
            return String(sanitized.prefix(40))
        }
        return sanitized.isEmpty ? "untitled" : sanitized
    }

    // MARK: - Item formatting (for ShellInterpreter output)

    static func formatItemLine(_ item: KnowledgeItem, index: Int, long: Bool) -> String {
        let icon = typeIcon(item.typeRaw)
        let title = item.title
        let status = item.statusRaw
        let date = item.updatedAt.formatted(date: .abbreviated, time: .omitted)
        if long {
            let tags = item.tags.isEmpty ? "" : "  tags=\(item.tags.joined(separator: ","))"
            return "  \(icon) \"\(title)\"  [\(status)]  \(date)\(tags)"
        }
        return "  \(icon) \"\(title)\"  (\(status))"
    }

    static func formatItemFull(_ item: KnowledgeItem, fileStore: FileArtifactStore) -> String {
        var lines = ["# \(item.title)", ""]
        lines.append("ID: \(item.id.uuidString)")
        lines.append("Type: \(item.typeRaw)  Status: \(item.statusRaw)")
        if let projectID = item.projectID { lines.append("Project: \(projectID.uuidString)") }
        lines.append("Created: \(item.createdAt.formatted(date: .complete, time: .shortened))")
        lines.append("Updated: \(item.updatedAt.formatted(date: .complete, time: .shortened))")
        if let dur = item.durationSeconds { lines.append("Duration: \(Int(dur))s") }
        if !item.tags.isEmpty { lines.append("Tags: \(item.tags.joined(separator: ", "))") }
        if let body = item.bodyText, !body.isEmpty {
            lines.append(""); lines.append("## Body"); lines.append(body)
        }
        let dir = fileStore.itemDirectoryURL(for: item.id)
        var artifacts: [String] = []
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
            artifacts.append("analysis/\(item.id.uuidString.prefix(8)).transcript.json")
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.json").path) ||
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis.dynamic.json").path) {
            artifacts.append("analysis/\(item.id.uuidString.prefix(8)).json")
        }
        if !artifacts.isEmpty {
            lines.append(""); lines.append("## Available Artifacts")
            for a in artifacts { lines.append("  \(a)") }
        }
        return lines.joined(separator: "\n")
    }

    static func itemToDict(_ item: KnowledgeItem, fileStore: FileArtifactStore, fields: [String]?) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id.uuidString, "type": item.typeRaw, "title": item.title,
            "status": item.statusRaw, "createdAt": item.createdAt.ISO8601Format(),
            "updatedAt": item.updatedAt.ISO8601Format()
        ]
        if let proj = item.projectID { dict["projectID"] = proj.uuidString }
        if let body = item.bodyText { dict["body"] = body }
        if !item.tags.isEmpty { dict["tags"] = item.tags }
        if let dur = item.durationSeconds { dict["durationSeconds"] = dur }
        if let fields { return dict.filter { fields.contains($0.key) } }
        return dict
    }
}

// MARK: - VFS Errors

enum VFSError: Error, LocalizedError {
    case fileNotFound(path: String)
    case invalidContent
    case invalidJSON
    case invalidField(String, String, [String])
    case cannotDelete(path: String)
    case cannotMove(from: String, to: String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .invalidContent: return "Invalid file content"
        case .invalidJSON: return "Invalid JSON content"
        case .invalidField(let field, let value, let valid): return "Invalid value '\(value)' for field '\(field)'. Valid: \(valid.joined(separator: ", "))"
        case .cannotDelete(let path): return "Cannot delete: \(path)"
        case .cannotMove(let from, let to): return "Cannot move \(from) to \(to)"
        case .notImplemented: return "Operation not implemented"
        }
    }
}
