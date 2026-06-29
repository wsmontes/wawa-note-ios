import SwiftData
import SwiftUI

// MARK: - DEPRECATED: Subsumed by file browser with type filter (2026-06-18)
struct RiskItem: Identifiable {
    let id = UUID()
    let title: String
    let details: String?
    let sourceItemID: UUID
    let sourceItemTitle: String
    let sourceItemDate: Date
    let confidence: Double
}

struct ProjectRiskRegisterView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var risks: [RiskItem] = []
    @State private var isLoading = true
    @State private var showNewTask = false
    @State private var selectedRisk: RiskItem?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading risks...")
                Spacer()
            } else if risks.isEmpty {
                Spacer()
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "exclamationmark.shield").font(.title).foregroundStyle(.secondary)
                    Text("No risks identified").font(.headline)
                    Text("Risks are identified when items are analyzed.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    Section("\(risks.count) risks · avg confidence \(Int(avgConfidence * 100))%") {
                        ForEach(risks) { r in
                            riskRow(r)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        selectedRisk = r
                                        showNewTask = true
                                    } label: {
                                        Label("Create Task", systemImage: "checklist")
                                    }.tint(.teal)
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $showNewTask) {
            if let risk = selectedRisk {
                TaskEditorView(mode: .create(projectID: projectID))
            }
        }
        .task { await loadRisks() }
    }

    private var avgConfidence: Double {
        guard !risks.isEmpty else { return 0 }
        return risks.map(\.confidence).reduce(0, +) / Double(risks.count)
    }

    private func riskRow(_ r: RiskItem) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "exclamationmark.shield.fill").font(.caption).foregroundStyle(confidenceColor(r.confidence))
                Text(r.title).font(.subheadline).fontWeight(.medium)
                Spacer()
                ConfidenceBadge(value: r.confidence)
            }
            if let details = r.details, !details.isEmpty {
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: AppSpacing.sm) {
                Label(r.sourceItemTitle, systemImage: "doc.text").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Text(r.sourceItemDate.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func confidenceColor(_ c: Double) -> Color {
        c >= 0.8 ? .red : c >= 0.6 ? .orange : .yellow
    }

    private func loadRisks() async {
        let store = FileArtifactStore()
        let projSvc = ProjectService(context: modelContext)
        guard let items = try? projSvc.items(in: projectID) else {
            isLoading = false
            return
        }
        var result: [RiskItem] = []
        for item in items {
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            for risk in analysis.risks {
                result.append(
                    RiskItem(
                        title: risk.risk,
                        details: risk.details,
                        sourceItemID: item.id,
                        sourceItemTitle: item.title,
                        sourceItemDate: item.createdAt,
                        confidence: risk.confidence ?? 0.5
                    ))
            }
        }
        result.sort { $0.confidence > $1.confidence }
        risks = result
        isLoading = false
    }
}
