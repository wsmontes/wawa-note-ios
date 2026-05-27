import SwiftUI
import SwiftData

struct ProjectGraphView: View {
    let projectID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var edges: [GraphEdge] = []
    @State private var nodes: [GraphNode] = []
    @State private var isLoading = true

    init(projectID: UUID) {
        self.projectID = projectID
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading graph...")
            } else if nodes.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "circle.hexagonpath")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No connections yet")
                        .font(.headline)
                    Text("Graph relationships will appear when tasks are created and entities are linked to this project.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                graphContent
            }
        }
        .task { await loadGraph() }
    }

    // MARK: - Graph visualization

    private var graphContent: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                // Project node (center)
                projectNode

                // Connected nodes by type
                connectedNodesSection("Tasks", icon: "checklist", color: .green, kind: .task)
                connectedNodesSection("Items", icon: "doc.text", color: .blue, kind: .item)
                connectedNodesSection("People", icon: "person", color: .purple, kind: .person)
                connectedNodesSection("Entities", icon: "cube", color: .orange, kind: .entity)
            }
            .padding(16)
        }
    }

    private var projectNode: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.blue)
                .frame(width: 12, height: 12)
            Text("Project")
                .font(.headline)
            Spacer()
            Text("\(edges.count) connections")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func connectedNodesSection(_ title: String, icon: String, color: Color, kind: NodeKind) -> some View {
        let filtered = nodes.filter { $0.kind == kind }
        guard !filtered.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.caption)
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text("\(filtered.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(filtered) { node in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(node.label)
                            .font(.subheadline)
                        Spacer()
                        Text(node.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        )
    }

    // MARK: - Load

    private func loadGraph() async {
        let svc = GraphEdgeService(context: modelContext)
        let edges = (try? svc.neighborhood(of: projectID, radius: 2)) ?? []
        var loadedNodes: [GraphNode] = []

        for edge in edges {
            // Look up connected items
            if let fromItem = findItem(edge.fromID) {
                loadedNodes.append(GraphNode(
                    id: edge.fromID, label: fromItem.title, subtitle: fromItem.type.label,
                    kind: fromItem.projectID == projectID ? .item : .related
                ))
            }
            if let toItem = findItem(edge.toID) {
                loadedNodes.append(GraphNode(
                    id: edge.toID, label: toItem.title, subtitle: toItem.type.label,
                    kind: toItem.projectID == projectID ? .item : .related
                ))
            }

            // Look up people
            let allPeople = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
            if let person = allPeople.first(where: { $0.id == edge.toID }) {
                loadedNodes.append(GraphNode(
                    id: person.id, label: person.displayName, subtitle: person.role ?? "Person",
                    kind: .person
                ))
            }

            // Look up tasks
            let allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
            if let task = allTasks.first(where: { $0.id == edge.toID }) {
                loadedNodes.append(GraphNode(
                    id: task.id, label: task.title, subtitle: task.status.rawValue.capitalized,
                    kind: .task
                ))
            }
        }

        // Deduplicate nodes by ID
        var seen: Set<UUID> = []
        var unique: [GraphNode] = []
        for node in loadedNodes {
            if !seen.contains(node.id) {
                seen.insert(node.id)
                unique.append(node)
            }
        }

        self.edges = edges
        self.nodes = unique
        self.isLoading = false
    }

    private func findItem(_ id: UUID) -> KnowledgeItem? {
        let all = (try? modelContext.fetch(FetchDescriptor<KnowledgeItem>())) ?? []
        return all.first { $0.id == id }
    }
}

// MARK: - Graph node model

enum NodeKind {
    case project
    case task
    case item
    case person
    case entity
    case related
}

struct GraphNode: Identifiable {
    let id: UUID
    let label: String
    let subtitle: String
    let kind: NodeKind
}

