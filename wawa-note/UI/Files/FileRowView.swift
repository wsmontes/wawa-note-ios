import SwiftUI

/// A single row in the file browser, representing a directory or file node.
struct FileRowView: View {
    let node: VFSNode
    let onOpen: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onRename: ((String) -> Void)?
    let onMove: (() -> Void)?
    let onDuplicate: (() -> Void)?
    let onExport: (() -> Void)?
    let onInfo: (() -> Void)?

    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: node.isDirectory ? "folder.fill" : node.nodeType.iconName)
                .font(.title3)
                .foregroundStyle(Color(hex: node.isDirectory ? folderColor : node.nodeType.tintColor))
                .frame(width: 28)

            // Name + metadata
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $newName, onCommit: {
                        if !newName.isEmpty, newName != node.name {
                            onRename?(newName)
                        }
                        isRenaming = false
                    })
                    .textFieldStyle(.plain)
                    .font(.body)
                } else {
                    Text(node.name)
                        .font(.body)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let count = node.childrenCount, node.isDirectory {
                        Text("\(count) item\(count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let size = node.size {
                        Text(formatBytes(size))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let date = node.modifiedAt {
                        Text(formatDate(date))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let status = node.metadata.itemStatus {
                        StatusBadge(status: status)
                    }
                    if let priority = node.metadata.priority {
                        FilePriorityBadge(priority: priority)
                    }
                    if node.metadata.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 8)).foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            // Chevron for directories
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuContent
        }
        .swipeActions(edge: .trailing) {
            if onDelete != nil {
                Button(role: .destructive) { onDelete?() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            if onMove != nil {
                Button { onMove?() } label: {
                    Label("Move", systemImage: "arrow.right.circle")
                }.tint(.orange)
            }
            if onRename != nil {
                Button {
                    newName = node.name
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }.tint(.blue)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if let onOpen {
            Button { onOpen() } label: {
                Label(node.isDirectory ? "Open Folder" : "Open File", systemImage: node.isDirectory ? "arrow.right.circle" : "doc.text.fill")
            }
        }

        if onEdit != nil, !node.isDirectory {
            Button { onEdit?() } label: {
                Label("Edit", systemImage: "pencil")
            }
        }

        if onOpen != nil || onEdit != nil { Divider() }

        if onRename != nil {
            Button {
                newName = node.name
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        if onDuplicate != nil {
            Button { onDuplicate?() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }

        if onMove != nil {
            Button { onMove?() } label: {
                Label("Move to...", systemImage: "arrow.right.circle")
            }
        }

        if onExport != nil {
            Button { onExport?() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }

        if onInfo != nil {
            Divider()
            Button { onInfo?() } label: {
                Label("Get Info", systemImage: "info.circle")
            }
        }

        if onDelete != nil {
            Divider()
            Button(role: .destructive) { onDelete?() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private var folderColor: String {
        node.metadata.isConfigProject ? "#64748B" : node.metadata.projectStatus == "archived" ? "#9CA3AF" : "#64748B"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func formatDate(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "done", "analyzed", "transcribed": .green
        case "inProgress", "processing", "analyzing", "transcribing": .blue
        case "todo", "recorded": .orange
        case "failed", "critical": .red
        case "draft", "recording": .gray
        case "edited": .purple
        default: .secondary
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Priority Badge

struct FilePriorityBadge: View {
    let priority: String

    private var color: Color {
        switch priority {
        case "critical": .red
        case "high": .orange
        case "medium": .blue
        case "low": .gray
        default: .secondary
        }
    }

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
    }
}
