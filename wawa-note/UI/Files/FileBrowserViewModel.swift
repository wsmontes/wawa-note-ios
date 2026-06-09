import SwiftUI
import SwiftData
import Combine

/// View model for the file browser. Manages VFS navigation state and file operations.
@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published var currentPath: String = "/"
    @Published var nodes: [VFSNode] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var pathHistory: [String] = ["/"]
    @Published var historyIndex: Int = 0

    private var modelContext: ModelContext?
    private let fileStore: FileArtifactStore
    private var toolContext: ToolContext? {
        guard let modelContext else { return nil }
        return ToolContext(modelContext: modelContext, fileStore: fileStore)
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < pathHistory.count - 1 }
    var parentPath: String {
        let parts = currentPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }
    var currentName: String {
        let parts = currentPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return parts.last ?? "Workspace"
    }

    init() {
        self.modelContext = nil
        self.fileStore = FileArtifactStore()
    }

    /// Configure with the real model context. Must be called before any data access.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        let cleanPath = normalizePath(path)
        guard cleanPath != currentPath else { return }

        // Trim forward history if we're not at the end
        if historyIndex < pathHistory.count - 1 {
            pathHistory = Array(pathHistory.prefix(historyIndex + 1))
        }

        currentPath = cleanPath
        pathHistory.append(cleanPath)
        historyIndex = pathHistory.count - 1
        refresh()
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = pathHistory[historyIndex]
        refresh()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = pathHistory[historyIndex]
        refresh()
    }

    func goToParent() {
        navigate(to: parentPath)
    }

    func refresh() {
        guard let ctx = toolContext else { return }
        isLoading = true
        error = nil
        let path = currentPath
        Task {
            let children = VFSService.listChildren(path, context: ctx)
            await MainActor.run {
                self.nodes = children
                self.isLoading = false
            }
        }
    }

    // MARK: - Operations

    func delete(_ node: VFSNode) {
        guard let ctx = toolContext else { return }
        do {
            try VFSService.delete(node.path, context: ctx)
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rename(_ node: VFSNode, to newName: String) {
        guard let ctx = toolContext else { return }
        let parentPath = node.path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = "/\(parentPath)/\(newName)"
        // For items, update the title via metadata write
        if node.path.contains("/items/") || node.path.contains("/inbox/"), let id = node.metadata.swiftDataID {
            let json = "{\"title\":\"\(newName.replacingOccurrences(of: "\"", with: "\\\""))\"}"
            try? VFSService.writeItemFile(node.path.replacingOccurrences(of: node.name, with: "metadata.json"), content: json, context: ctx)
        }
        refresh()
    }

    func move(_ node: VFSNode, to destinationPath: String) {
        guard let ctx = toolContext else { return }
        do {
            try VFSService.move(node.path, destinationPath, context: ctx)
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Resolve a VFS path like /projects/{slug}/items/{uuid}/audio.m4a to a real filesystem URL.
    func resolveAudioURL(for path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        // Try to find item UUID in the path
        for part in parts {
            let clean = part.hasSuffix(".m4a") || part.hasSuffix(".mp3") || part.hasSuffix(".wav")
                ? String(part.dropLast(4))
                : part
            if let id = UUID(uuidString: VFSService.stripJSONSuffix(clean)) {
                return fileStore.audioFileURL(for: id)
            }
        }
        // Fallback: try the item directory from the path
        if parts.count >= 4, parts[0] == "projects",
           let id = UUID(uuidString: VFSService.stripJSONSuffix(parts[3])) {
            return fileStore.audioFileURL(for: id)
        }
        return nil
    }

    func readFileContent(_ path: String) -> String? {
        guard let ctx = toolContext else { return nil }
        return try? VFSService.readFileAsString(path, context: ctx)
    }

    func writeFileContent(_ path: String, content: String) -> Bool {
        guard let ctx = toolContext else { return false }
        do {
            if let _ = VFSService.node(at: path, context: ctx) {
                try VFSService.writeFileString(path, content: content, context: ctx)
            } else {
                try VFSService.writeItemFile(path, content: content, context: ctx)
            }
            refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Breadcrumb segments

    func breadcrumbSegments() -> [(name: String, path: String)] {
        let parts = currentPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var segments: [(String, String)] = [("Workspace", "/")]
        var accumulated = ""
        for part in parts {
            accumulated += "/" + part
            segments.append((part, accumulated))
        }
        if parts.isEmpty {
            return [("Workspace", "/")]
        }
        return segments
    }

    // MARK: - Sorting

    func sortedNodes(by sort: FileSortOrder = .name) -> [VFSNode] {
        switch sort {
        case .name:
            let dirs = nodes.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let files = nodes.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return dirs + files
        case .date:
            let dirs = nodes.filter(\.isDirectory).sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            let files = nodes.filter { !$0.isDirectory }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return dirs + files
        case .kind:
            let dirs = nodes.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let files = nodes.filter { !$0.isDirectory }.sorted {
                if $0.nodeType == $1.nodeType { return $0.name < $1.name }
                return $0.nodeType.rawValue < $1.nodeType.rawValue
            }
            return dirs + files
        }
    }

    private func normalizePath(_ path: String) -> String {
        var p = path
        if p.hasSuffix("/") && p.count > 1 { p = String(p.dropLast()) }
        if !p.hasPrefix("/") { p = "/" + p }
        return p.isEmpty ? "/" : p
    }
}

enum FileSortOrder: String, CaseIterable {
    case name = "Name"
    case date = "Date"
    case kind = "Kind"
}
