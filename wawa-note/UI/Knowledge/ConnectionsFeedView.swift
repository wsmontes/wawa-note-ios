import SwiftUI
import SwiftData

struct ConnectionsFeedView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var edges: [GraphEdge] = []
    @State private var selectedEdgeType: EdgeType?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips
            if !isLoading {
                filterBar
            }

            if isLoading {
                Spacer()
                ProgressView("Loading connections...")
                Spacer()
            } else if edges.isEmpty {
                emptyState
            } else {
                edgesList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Connections")
        .task { loadEdges() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("All", isSelected: selectedEdgeType == nil) {
                    selectedEdgeType = nil
                    loadEdges()
                }
                ForEach(EdgeType.allCases, id: \.rawValue) { type in
                    filterChip(type.rawValue.capitalized, isSelected: selectedEdgeType == type) {
                        selectedEdgeType = type
                        loadEdges()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isSelected ? .white : .blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.blue : Color.blue.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            Image(systemName: "link")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No connections yet")
                .font(.headline)
            Text("Promote meetings to projects or ask questions to discover relationships between your knowledge items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Edges list

    private var edgesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(edges) { edge in
                    NavigationLink {
                        EvidenceInspectorView(edge: edge)
                    } label: {
                        edgeRow(edge)
                    }
                    .buttonStyle(.plain)

                    if edge.id != edges.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(16)
        }
    }

    private func edgeRow(_ edge: GraphEdge) -> some View {
        HStack(spacing: 12) {
            Image(systemName: edgeTypeIcon(edge.edgeType))
                .font(.title3)
                .foregroundStyle(edgeTypeColor(edge.edgeType))
                .frame(width: 32, height: 32)
                .background(edgeTypeColor(edge.edgeType).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(edgeDescription(edge))
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(edge.edgeType.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(edgeTypeColor(edge.edgeType))
                    if edge.provenanceItemID != nil {
                        Label("Evidence", systemImage: "checkmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text(edge.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Circle()
                .fill(edgeTypeColor(edge.edgeType).opacity(edge.weight))
                .frame(width: 10, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func loadEdges() {
        let service = GraphEdgeService(context: modelContext)
        edges = (try? service.recentEdges(limit: 50)) ?? []
        if let filter = selectedEdgeType {
            edges = edges.filter { $0.edgeType == filter }
        }
        isLoading = false
    }

    private func edgeDescription(_ edge: GraphEdge) -> String {
        switch edge.edgeType {
        case .mentions: return "Mentions"
        case .belongsTo: return "Belongs to project"
        case .produced: return "Produced a task"
        case .assignedTo: return "Assigned to person"
        case .supports: return "Supports decision"
        case .precedes: return "Precedes task"
        case .blockedBy: return "Blocked by"
        case .relatesTo: return "Relates to"
        case .references: return "References"
        case .contradicts: return "Contradicts"
        }
    }

    private func edgeTypeIcon(_ type: EdgeType) -> String {
        switch type {
        case .mentions: return "person.text.rectangle"
        case .belongsTo: return "folder"
        case .produced: return "checklist"
        case .assignedTo: return "person"
        case .supports: return "checkmark.shield"
        case .precedes: return "arrow.right"
        case .blockedBy: return "xmark.circle"
        case .relatesTo: return "link"
        case .references: return "quote.opening"
        case .contradicts: return "exclamationmark.triangle"
        }
    }

    private func edgeTypeColor(_ type: EdgeType) -> Color {
        switch type {
        case .mentions: return .purple
        case .belongsTo: return .blue
        case .produced: return .green
        case .assignedTo: return .orange
        case .supports: return .teal
        case .precedes: return .indigo
        case .blockedBy: return .red
        case .relatesTo: return .gray
        case .references: return .cyan
        case .contradicts: return .pink
        }
    }
}
