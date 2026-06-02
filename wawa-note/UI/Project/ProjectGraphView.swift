import SwiftUI
import SwiftData

// MARK: - Graph Node

enum NodeKind: String, CaseIterable { case project, task, item, person, entity, related }

struct GraphNode: Identifiable {
    let id: UUID
    let label: String
    let subtitle: String
    let kind: NodeKind
    var x: CGFloat = 0; var y: CGFloat = 0
    var vx: CGFloat = 0; var vy: CGFloat = 0
    var degree: Int = 0

    var color: Color {
        switch kind { case .project: .blue; case .task: .teal; case .item: .gray; case .person: .purple; case .entity: .orange; case .related: .mint }
    }
    var radius: CGFloat { min(40, max(16, 14 + CGFloat(degree) * 3)) }
}

struct GraphEdgeItem: Identifiable {
    let id = UUID()
    let fromID: UUID; let toID: UUID
    let type: EdgeType; let weight: Double; let provenance: String?
}

// MARK: - Force-Directed Layout

enum ForceLayout {
    static let iterations = 80
    static let repulsion: CGFloat = 6000
    static let attraction: CGFloat = 0.01
    static let damping: CGFloat = 0.85
    static let centerGravity: CGFloat = 0.001

    static func compute(nodes: inout [GraphNode], edges: [GraphEdgeItem], size: CGSize) {
        let centerX = size.width / 2; let centerY = size.height / 2
        for _ in 0..<iterations {
            var forces: [(CGFloat, CGFloat)] = Array(repeating: (0, 0), count: nodes.count)
            // Repulsion between all pairs
            for i in 0..<nodes.count {
                for j in (i+1)..<nodes.count {
                    let dx = nodes[i].x - nodes[j].x; let dy = nodes[i].y - nodes[j].y
                    let dist = max(1, sqrt(dx*dx + dy*dy))
                    let force = repulsion / (dist * dist)
                    let fx = (dx / dist) * force; let fy = (dy / dist) * force
                    forces[i].0 += fx; forces[i].1 += fy
                    forces[j].0 -= fx; forces[j].1 -= fy
                }
            }
            // Attraction along edges
            for edge in edges {
                guard let i = nodes.firstIndex(where: { $0.id == edge.fromID }),
                      let j = nodes.firstIndex(where: { $0.id == edge.toID }) else { continue }
                let dx = nodes[j].x - nodes[i].x; let dy = nodes[j].y - nodes[i].y
                let dist = max(1, sqrt(dx*dx + dy*dy))
                let force = attraction * dist * Double(edge.weight)
                let fx = (dx / dist) * CGFloat(force); let fy = (dy / dist) * CGFloat(force)
                forces[i].0 += fx; forces[i].1 += fy
                forces[j].0 -= fx; forces[j].1 -= fy
            }
            // Center gravity + apply
            for i in 0..<nodes.count {
                forces[i].0 += (centerX - nodes[i].x) * centerGravity
                forces[i].1 += (centerY - nodes[i].y) * centerGravity
                nodes[i].vx = (nodes[i].vx + forces[i].0) * damping
                nodes[i].vy = (nodes[i].vy + forces[i].1) * damping
                nodes[i].x += nodes[i].vx
                nodes[i].y += nodes[i].vy
                nodes[i].x = nodes[i].x.clamped(to: 20...(size.width - 20))
                nodes[i].y = nodes[i].y.clamped(to: 20...(size.height - 20))
            }
        }
    }
}

extension CGFloat { func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) } }

// MARK: - Graph View

struct ProjectGraphView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdgeItem] = []
    @State private var isLoading = true
    @State private var selectedNode: GraphNode?
    @State private var visibleEdgeTypes: Set<String> = []
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            filterChips
            Divider()
            if isLoading {
                Spacer(); ProgressView("Building graph..."); Spacer()
            } else if nodes.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "circle.hexagonpath").font(.title).foregroundStyle(.secondary)
                    Text("No connections yet").font(.headline)
                }
                Spacer()
            } else {
                graphCanvas
            }
        }
        .task { await loadGraph() }
        .sheet(item: $selectedNode) { nodeDetailSheet($0) }
    }

    // MARK: Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(EdgeType.allCases), id: \.rawValue) { et in
                    let selected = visibleEdgeTypes.contains(et.rawValue)
                    Button {
                        if selected { visibleEdgeTypes.remove(et.rawValue) }
                        else { visibleEdgeTypes.insert(et.rawValue) }
                    } label: {
                        Text(et.rawValue.replacingOccurrences(of: "_", with: " ")).font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(selected ? edgeColor(et).opacity(0.15) : Color(.tertiarySystemFill))
                            .foregroundStyle(selected ? edgeColor(et) : .secondary)
                            .clipShape(Capsule())
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: Canvas

    private var graphCanvas: some View {
        let filteredEdges = visibleEdgeTypes.isEmpty ? edges : edges.filter { visibleEdgeTypes.contains($0.type.rawValue) }

        return GeometryReader { geo in
            Canvas { ctx, size in
                // Edges
                for edge in filteredEdges {
                    guard let from = nodes.first(where: { $0.id == edge.fromID }),
                          let to = nodes.first(where: { $0.id == edge.toID }) else { continue }
                    var path = Path(); path.move(to: CGPoint(x: from.x, y: from.y))
                    path.addLine(to: CGPoint(x: to.x, y: to.y))
                    ctx.stroke(path, with: .color(edgeColor(edge.type).opacity(0.4)), lineWidth: max(1, CGFloat(edge.weight) * 2))
                }
                // Nodes
                for node in nodes {
                    let rect = CGRect(x: node.x - node.radius, y: node.y - node.radius, width: node.radius * 2, height: node.radius * 2)
                    ctx.fill(Circle().path(in: rect), with: .color(node.color.opacity(0.8)))
                    if node.degree >= 3 {
                        ctx.stroke(Circle().path(in: rect.insetBy(dx: -2, dy: -2)), with: .color(.white.opacity(0.6)), lineWidth: 2)
                    }
                    // Label
                    ctx.draw(Text(node.label.prefix(12)).font(.system(size: 9)).foregroundColor(.primary), at: CGPoint(x: node.x, y: node.y + node.radius + 10))
                }
            }
            .scaleEffect(scale).offset(offset)
            .gesture(MagnificationGesture().onChanged { scale = $0 }.onEnded { _ in if scale < 0.3 { scale = 0.3 }; if scale > 3 { scale = 3 } })
            .simultaneousGesture(DragGesture().onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }.onEnded { _ in lastOffset = offset })
            .onTapGesture(count: 2) { withAnimation(.spring) { scale = 1.0; offset = .zero; lastOffset = .zero } }
            .onAppear {
                canvasSize = geo.size
                let capturedNodes = nodes; let capturedEdges = edges; let gSize = geo.size
                Task { @GraphLayoutActor in
                    var mutable = capturedNodes
                    ForceLayout.compute(nodes: &mutable, edges: capturedEdges, size: gSize)
                    await MainActor.run { nodes = mutable }
                }
            }
            .onTapGesture { location in handleTap(location) }
        }
    }

    private func handleTap(_ location: CGPoint) {
        let adjusted = CGPoint(x: (location.x - offset.width) / scale, y: (location.y - offset.height) / scale)
        if let tapped = nodes.first(where: { sqrt(pow($0.x - adjusted.x, 2) + pow($0.y - adjusted.y, 2)) < $0.radius + 10 }) {
            selectedNode = tapped
        }
    }

    // MARK: Node detail sheet

    private func nodeDetailSheet(_ node: GraphNode) -> some View {
        NavigationStack {
            List {
                Section("Node") {
                    HStack { Circle().fill(node.color).frame(width: 12, height: 12); Text(node.label).font(.headline) }
                    Text(node.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(node.degree) connections").font(.caption)
                }
                Section("Connected to") {
                    let connectedEdges = edges.filter { $0.fromID == node.id || $0.toID == node.id }
                    ForEach(connectedEdges) { edge in
                        let otherID = edge.fromID == node.id ? edge.toID : edge.fromID
                        if let other = nodes.first(where: { $0.id == otherID }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle().fill(other.color).frame(width: 8, height: 8)
                                    Text(other.label).font(.subheadline)
                                    Spacer()
                                    Text(edge.type.rawValue).font(.caption2).foregroundStyle(edgeColor(edge.type))
                                    ConfidenceBadge(value: edge.weight)
                                }
                                if let prov = edge.provenance, let provID = UUID(uuidString: prov) {
                                    EvidenceCardView(itemTitle: "Source item", itemID: provID, snippet: "Edge derived from analysis", segmentID: nil, confidence: edge.weight, edgeType: edge.type.rawValue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Node Details").navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Load

    private func loadGraph() async {
        let edgeSvc = GraphEdgeService(context: modelContext)
        let loadedEdges = (try? edgeSvc.neighborhood(of: projectID, radius: 2)) ?? []
        var nodeMap: [UUID: GraphNode] = [:]

        for edge in loadedEdges {
            for nid in [edge.fromID, edge.toID] {
                guard nodeMap[nid] == nil else { continue }
                if let item = findItem(nid) {
                    nodeMap[nid] = GraphNode(id: nid, label: item.title, subtitle: item.type.label, kind: .item, degree: 1)
                } else if let task = findTask(nid) {
                    nodeMap[nid] = GraphNode(id: nid, label: task.title, subtitle: task.status.rawValue.capitalized, kind: .task, degree: 1)
                } else if let person = findPerson(nid) {
                    nodeMap[nid] = GraphNode(id: nid, label: person.displayName, subtitle: person.role ?? "Person", kind: .person, degree: 1)
                }
            }
        }
        // Compute degree
        for edge in loadedEdges {
            nodeMap[edge.fromID]?.degree += 1
            nodeMap[edge.toID]?.degree += 1
        }
        // Add project root
        if let proj = try? ProjectService(context: modelContext).fetch(id: projectID) {
            nodeMap[projectID] = GraphNode(id: projectID, label: proj.name, subtitle: "Project", kind: .project, degree: nodeMap.count)
        }

        self.edges = loadedEdges.map { GraphEdgeItem(fromID: $0.fromID, toID: $0.toID, type: $0.edgeType, weight: $0.weight, provenance: $0.provenanceItemID?.uuidString) }
        self.nodes = Array(nodeMap.values)
        self.isLoading = false
    }

    private func findItem(_ id: UUID) -> KnowledgeItem? {
        let all = (try? modelContext.fetch(FetchDescriptor<KnowledgeItem>())) ?? []
        return all.first { $0.id == id }
    }
    private func findTask(_ id: UUID) -> TaskItem? {
        let all = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        return all.first { $0.id == id }
    }
    private func findPerson(_ id: UUID) -> Person? {
        let all = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        return all.first { $0.id == id }
    }

    private func edgeColor(_ type: EdgeType) -> Color {
        switch type {
        case .supports: .blue; case .contradicts: .red; case .references: .gray
        case .precedes: .orange; case .mentions: .purple; case .assignedTo: .teal
        case .blockedBy: .pink; case .belongsTo: .mint; case .produced: .indigo; case .relatesTo: .secondary
        }
    }
}

// MARK: - Background layout actor
@globalActor actor GraphLayoutActor {
    static let shared = GraphLayoutActor()
}
