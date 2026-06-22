import SwiftUI
import SwiftData

// MARK: - DEPRECATED: Subsumed by file browser with type filter (2026-06-18)
struct DecisionItem: Identifiable {
    let id = UUID()
    let title: String
    let details: String?
    let sourceItemID: UUID
    let sourceItemTitle: String
    let sourceItemDate: Date
    let confidence: Double
}

struct ProjectDecisionsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: ServiceContainer
    @State private var decisions: [DecisionItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var minConfidence: Double = 0

    private var filteredDecisions: [DecisionItem] {
        decisions.filter { d in
            d.confidence >= minConfidence &&
            (searchText.isEmpty || d.title.localizedCaseInsensitiveContains(searchText) ||
             (d.details ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading decisions...")
                Spacer()
            } else if decisions.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "lightbulb").font(.title).foregroundStyle(.secondary)
                    Text("No decisions yet").font(.headline)
                    Text("Decisions are extracted when items are analyzed.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredDecisions) { d in
                        decisionRow(d)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $searchText, prompt: "Search decisions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([0.0, 0.5, 0.7, 0.9], id: \.self) { threshold in
                        Button { minConfidence = threshold } label: {
                            Label(threshold == 0 ? "All confidence" : "≥ \(Int(threshold * 100))%", systemImage: minConfidence == threshold ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task { await loadDecisions() }
    }

    private func decisionRow(_ d: DecisionItem) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.indigo)
                Text(d.title).font(.subheadline).fontWeight(.medium)
                Spacer()
                ConfidenceBadge(value: d.confidence)
            }
            if let details = d.details, !details.isEmpty {
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: AppSpacing.sm) {
                Label(d.sourceItemTitle, systemImage: "doc.text").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Text(d.sourceItemDate.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func loadDecisions() async {
        let store = FileArtifactStore()
        let projSvc = services.projects
        guard let items = try? projSvc.items(in: projectID) else {
            isLoading = false
            return
        }
        var result: [DecisionItem] = []
        for item in items {
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for d in analysis.decisions {
                result.append(DecisionItem(
                    title: d.title,
                    details: d.details,
                    sourceItemID: item.id,
                    sourceItemTitle: item.title,
                    sourceItemDate: item.createdAt,
                    confidence: d.confidence ?? 0.5
                ))
            }
        }
        result.sort { $0.confidence > $1.confidence }
        decisions = result
        isLoading = false
    }
}
