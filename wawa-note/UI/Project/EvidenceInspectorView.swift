import SwiftUI
import SwiftData

struct EvidenceInspectorView: View {
    let edge: GraphEdge

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]

    @State private var sourceItem: KnowledgeItem?
    @State private var targetItem: KnowledgeItem?
    @State private var transcriptSegments: [TranscriptSegment] = []
    @State private var analysis: MeetingAnalysis?

    private let fileStore = FileArtifactStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Edge info header
                edgeHeader

                // Source item (provenance)
                if let source = sourceItem {
                    itemCard(source, label: "Source Evidence")
                }

                // Connected items
                if let from = findItem(edge.fromID) {
                    itemCard(from, label: "From")
                }
                if let to = findItem(edge.toID) {
                    itemCard(to, label: "To")
                }

                // Transcript evidence
                if !transcriptSegments.isEmpty {
                    evidenceSegments
                }

                // Edge metadata
                edgeMetadata
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Evidence")
        .task { loadEvidence() }
    }

    // MARK: - Header

    private var edgeHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: edgeIcon)
                    .font(.title2)
                    .foregroundStyle(edgeColor)
                Text(edge.edgeType.rawValue.capitalized)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(edge.weight * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
            }

            if edge.provenanceItemID != nil {
                Label("Evidence-backed connection", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Item cards

    private func itemCard(_ item: KnowledgeItem, label: String) -> some View {
        NavigationLink {
            KnowledgeDetailView(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(spacing: 8) {
                    Image(systemName: item.type.icon)
                        .foregroundStyle(item.type.color)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Evidence segments

    private var evidenceSegments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript Evidence")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(transcriptSegments) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("[\(formatTime(segment.startTime))]")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .fontWeight(.medium)
                        Spacer()
                        if let conf = segment.confidence {
                            Text("\(Int(conf * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(segment.text)
                        .font(.body)
                }
                .padding(10)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Edge metadata

    private var edgeMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connection Details")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                metadataRow("Type", edge.edgeType.rawValue.capitalized)
                Divider().padding(.leading, 12)
                metadataRow("Weight", String(format: "%.2f", edge.weight))
                Divider().padding(.leading, 12)
                metadataRow("Created", edge.createdAt.formatted())
                if let provenance = edge.provenanceItemID {
                    Divider().padding(.leading, 12)
                    metadataRow("Provenance", provenance.uuidString.prefix(8).capitalized)
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func metadataRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private var edgeIcon: String {
        switch edge.edgeType {
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

    private var edgeColor: Color {
        switch edge.edgeType {
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

    private func findItem(_ id: UUID) -> KnowledgeItem? {
        allItems.first { $0.id == id }
    }

    private func loadEvidence() {
        // Load source item
        if let sourceID = edge.provenanceItemID {
            sourceItem = findItem(sourceID)
            let segments = edge.segmentIDs
            if !segments.isEmpty, let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: sourceID) {
                transcriptSegments = transcript.segments.filter { seg in segments.contains(seg.id.uuidString) }
            }
            analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: sourceID)
        }
        targetItem = findItem(edge.toID)
    }

    private func formatTime(_ s: Double) -> String {
        let m = Int(s)/60; let sec = Int(s)%60; return String(format: "%02d:%02d", m, sec)
    }
}

extension GraphEdge {
    var segmentIDs: [String] {
        provenanceSegmentIDList
    }
}
