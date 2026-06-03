import SwiftUI
import SwiftData

// MARK: - Project Overview Dashboard

struct ProjectOverviewCards: View {
    let project: Project
    let items: [KnowledgeItem]
    let tasks: [TaskItem]
    @ObservedObject var viewModel: ProjectDetailViewModel

    @State private var health: ProjectHealthEngine.HealthResult?
    @State private var healthTask: Task<Void, Never>?
    @State private var cachedRisks: [(String, String, Double)] = []
    @State private var cachedSuggestions: [AgentSuggestion] = []

    private func refreshHealth() {
        guard let ctx = viewModel.modelContext else { return }
        healthTask?.cancel()
        healthTask = Task { @MainActor in
            health = ProjectHealthEngine.compute(for: project.id, context: ctx)
            cachedRisks = computeRisks()
            cachedSuggestions = fetchPendingSuggestions(ctx)
        }
    }

    private func computeRisks() -> [(String, String, Double)] {
        let store = FileArtifactStore()
        return items.compactMap { item -> [(String, String, Double)]? in
            guard let analysis = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { return nil }
            return analysis.risks.filter { ($0.confidence ?? 0) > 0.7 }.map { ($0.risk, item.title, $0.confidence ?? 0) }
        }.flatMap { $0 }
    }

    private var overdueTasks: [TaskItem] {
        tasks.filter { t in
            (t.status == .todo || t.status == .inProgress) && t.dueAt.map { $0 < Date() } ?? false
        }
    }

    private var openRisks: [(String, String, Double)] { cachedRisks }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            if let h = health {
                pulseStrip(health: h)
            }

            if !overdueTasks.isEmpty || !openRisks.isEmpty {
                attentionSection
            }

            synthesisSection

            suggestionsSection

            activityFeed
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
        .onAppear { refreshHealth() }
        .onDisappear { healthTask?.cancel() }
        .onChange(of: viewModel.projectItems.count) { _ in refreshHealth() }
    }

    // MARK: Pulse Strip

    private func pulseStrip(health: ProjectHealthEngine.HealthResult) -> some View {
        HStack(spacing: AppSpacing.sm) {
            HealthRingView(score: health.score, status: health.status)
            Spacer()
            MetricTile(icon: "checkmark.seal", value: String(format: "%.0f", health.decisionVelocity * 4),
                       label: "Decisions", subtitle: "this month")
            MetricTile(icon: "exclamationmark.shield", value: "\(Int(health.riskExposure * 100))%",
                       label: "Exposure", subtitle: health.anomalies.isEmpty ? "Clear" : "Watch")
            MetricTile(icon: "circle.dotted", value: "\(items.count)",
                       label: "Items", subtitle: health.evidenceFreshnessDays < 7 ? "Active" : "\(Int(health.evidenceFreshnessDays))d old")
        }
        .padding(AppSpacing.md)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: Attention Section

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text("Needs attention").font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                Spacer()
                Text("\(overdueTasks.count + openRisks.count) items").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(overdueTasks.prefix(3)) { task in
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.red)
                    Text(task.title).font(.caption).lineLimit(1)
                    Spacer()
                    if let due = task.dueAt {
                        Text(due.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(AppSpacing.sm).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            ForEach(Array(openRisks.enumerated()).prefix(2), id: \.offset) { _, riskData in
                let (risk, _, conf) = riskData
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    Text(risk).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int(conf * 100))%").font(.caption2).foregroundStyle(.orange)
                }
                .padding(AppSpacing.sm).background(Color.orange.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }

    // MARK: Synthesis

    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "text.alignleft").font(.caption).foregroundStyle(.blue)
                Text("Synthesis").font(.caption).fontWeight(.semibold)
                AIGeneratedBadge(confidence: nil, source: "Agent")
                Spacer()
                if let updated = project.synthesisUpdatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .numeric)))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(project.synthesis ?? project.summary ?? "Add items to this project to generate insights.")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
            if let sourceID = project.synthesisSourceItemID {
                let snippet = project.summary.map { String($0.prefix(120)) } ?? "No summary"
                EvidenceCardView(itemTitle: "Generated from item", itemID: sourceID, snippet: snippet, segmentID: nil, confidence: nil, edgeType: nil)
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }

    // MARK: Suggestions

    private var pendingSuggestions: [AgentSuggestion] { cachedSuggestions }

    private func fetchPendingSuggestions(_ ctx: ModelContext) -> [AgentSuggestion] {
        let all = (try? ctx.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        return all.filter { $0.projectID == project.id && $0.status == "pending" }
    }

    private var suggestionsSection: some View {
        let pending = pendingSuggestions
        guard !pending.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                    Text("Suggestions to review").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(pending.count) pending").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(pending.prefix(3)) { sug in
                    suggestionCard(sug)
                }
                if pending.count > 3 {
                    Text("+\(pending.count - 3) more suggestions").font(.caption2).foregroundStyle(.blue).padding(.top, 2)
                }
            }
            .padding(AppSpacing.md)
            .projectCard()
        )
    }

    private func suggestionCard(_ sug: AgentSuggestion) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: sug.type == "task" ? "checklist" : sug.type == "edge" ? "arrow.triangle.branch" : "doc.text")
                    .font(.caption2).foregroundStyle(sug.type == "task" ? .teal : .blue)
                Text(sug.title).font(.caption).lineLimit(2)
                Spacer()
                if let conf = sug.confidence { ConfidenceBadge(value: conf) }
            }
            if let body = sug.body, !body.isEmpty {
                Text(body).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let sourceID = sug.sourceItemID {
                EvidenceCardView(itemTitle: "Source", itemID: sourceID, snippet: sug.title, segmentID: nil, confidence: sug.confidence, edgeType: nil)
            }
            HStack(spacing: AppSpacing.sm) {
                Button { approveSuggestion(sug) } label: {
                    Label("Approve", systemImage: "checkmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, AppSpacing.xs)
                        .background(Color.green.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Button { rejectSuggestion(sug) } label: {
                    Label("Reject", systemImage: "xmark").font(.caption2)
                        .padding(.horizontal, 10).padding(.vertical, AppSpacing.xs)
                        .background(Color.red.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain)
                Spacer()
                AIGeneratedBadge(confidence: sug.confidence, source: "AI suggestion")
            }
        }
        .padding(AppSpacing.sm).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func approveSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        switch sug.type {
        case "task":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let title = dict["title"] as? String ?? sug.title
                let task = TaskItem(projectID: project.id, title: title, ownerName: dict["owner"] as? String)
                ctx.insert(task)
            }
        case "edge":
            if let json = sug.payloadJSON, let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fromStr = dict["fromID"] as? String, let fromID = UUID(uuidString: fromStr),
               let toStr = dict["toID"] as? String, let toID = UUID(uuidString: toStr),
               let typeStr = dict["type"] as? String, let edgeType = EdgeType(rawValue: typeStr) {
                let edge = GraphEdge(fromID: fromID, toID: toID, edgeType: edgeType, weight: sug.confidence ?? 0.7)
                edge.provenanceItemID = sug.sourceItemID
                if let segJSON = sug.sourceSegmentIDs, let segData = segJSON.data(using: .utf8),
                   let segs = try? JSONDecoder().decode([String].self, from: segData) {
                    edge.provenanceSegmentIDs = segs.isEmpty ? nil : (try? JSONEncoder().encode(segs)).flatMap { String(data: $0, encoding: .utf8) }
                }
                ctx.insert(edge)
            }
        default: break
        }
        sug.status = "approved"; sug.resolvedAt = Date()
        try? ctx.save()
    }

    private func rejectSuggestion(_ sug: AgentSuggestion) {
        guard let ctx = viewModel.modelContext else { return }
        sug.status = "rejected"; sug.resolvedAt = Date()
        try? ctx.save()
        AgentMemoryStore.shared.write(pattern: "rejected_\(sug.type)", strategy: "User rejected: \(sug.title.prefix(60))",
            itemType: sug.type, contentType: nil, language: nil)
    }

    // MARK: Activity Feed

    private var activityFeed: some View {
        var entries: [(icon: String, color: Color, text: String, date: Date)] = []
        for item in items.prefix(5) {
            entries.append((item.type == .audio ? "mic.fill" : item.type == .image ? "photo" : "doc.text.fill",
                item.type.color, item.title, item.createdAt))
        }
        for task in tasks.filter({ $0.status == .done }).prefix(3) {
            entries.append(("checkmark.circle.fill", .green, "Completed: \(task.title)", task.updatedAt))
        }
        entries.sort { $0.date > $1.date }
        let recent = Array(entries.prefix(5))

        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath").font(.caption).foregroundStyle(.green)
                Text("Recent activity").font(.caption).fontWeight(.semibold)
            }
            if recent.isEmpty {
                Text("No activity yet").font(.caption2).foregroundStyle(.tertiary).padding(.vertical, AppSpacing.xs)
            } else {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: entry.icon).font(.caption2).foregroundStyle(entry.color)
                        Text(entry.text).font(.caption).lineLimit(1)
                        Spacer()
                        Text(entry.date.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(AppSpacing.xs)
                }
            }
        }
        .padding(AppSpacing.md)
        .projectCard()
    }
}

// MARK: - Health Ring

struct HealthRingView: View {
    let score: Int
    let status: String

    private var ringColor: Color {
        switch status {
        case "healthy": return .mint
        case "stale": return .orange
        case "atRisk": return .red
        default: return .gray
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.15), lineWidth: 6).frame(width: 52, height: 52)
            Circle().trim(from: 0, to: CGFloat(score) / 100).stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 52, height: 52).rotationEffect(.degrees(-90)).animation(.spring(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 16, weight: .bold, design: .rounded))
            }
        }
    }
}

// MARK: - Metric Tile

struct MetricTile: View {
    let icon: String; let value: String; let label: String; let subtitle: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .rounded)).fontWeight(.bold)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
