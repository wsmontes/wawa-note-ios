import SwiftUI
import SwiftData

// MARK: - Enriched Timeline Models

enum TimelineEventKind: String, CaseIterable {
    case audio, note, journalEntry, webBookmark, image, task, decision, risk, question, done

    static func from(itemType: KnowledgeItemType) -> TimelineEventKind {
        switch itemType {
        case .audio: .audio
        case .note: .note
        case .journalEntry: .journalEntry
        case .webBookmark: .webBookmark
        case .image: .image
        }
    }

    var color: Color {
        switch self {
        case .audio: .blue; case .note: .orange; case .journalEntry: .purple
        case .webBookmark: .green; case .image: .pink; case .task: .teal
        case .decision: .indigo; case .risk: .red; case .question: .orange
        case .done: .gray
        }
    }
}

struct TimelineEvent: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let date: Date
    let kind: TimelineEventKind
    let sourceItemID: UUID?
    var decisionTitles: [String] = []
    var riskTitles: [String] = []
    var actionItems: [String] = []
    var connectedTo: [UUID] = []  // IDs of connected events via GraphEdges
}

struct TimelineCluster: Identifiable {
    let id = UUID()
    let weekStart: Date
    let label: String
    var events: [TimelineEvent]
    var decisionCount: Int { events.filter { $0.kind == .decision }.count }
    var riskCount: Int { events.filter { $0.kind == .risk }.count }
    var actionCount: Int { events.filter { !$0.actionItems.isEmpty }.count + events.filter { $0.kind == .task }.count }
    var recordingCount: Int { events.filter { $0.kind == .audio }.count }
}

struct TimelineConnector: Identifiable {
    let id = UUID()
    let fromEventID: UUID
    let toEventID: UUID
    let edgeType: EdgeType
    var fromY: CGFloat = 0
    var toY: CGFloat = 0
}

// MARK: - Timeline View

struct ProjectTimelineView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: ServiceContainer
    @State private var clusters: [TimelineCluster] = []
    @State private var connectors: [TimelineConnector] = []
    @State private var isLoading = true
    @State private var selectedKinds: Set<TimelineEventKind> = [.audio, .decision, .risk, .task]
    @State private var zoomLevel: TimelineZoom = .week

    enum TimelineZoom: String, CaseIterable { case week, month, quarter }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if isLoading {
                Spacer(); ProgressView("Building timeline..."); Spacer()
            } else if clusters.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
                    Text("No events yet").font(.headline)
                }
                Spacer()
            } else {
                timelineScroll
            }
        }
        .task { loadTimeline() }
        .onChange(of: zoomLevel) { _ in loadTimeline() }
    }

    // MARK: Filter Bar

    private var filterBar: some View {
        VStack(spacing: AppSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    ForEach(TimelineEventKind.allCases, id: \.rawValue) { kind in
                        Button {
                            if selectedKinds.contains(kind) { selectedKinds.remove(kind) }
                            else { selectedKinds.insert(kind) }
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: iconFor(kind)).font(.system(size: 10))
                                Text(kind.rawValue.capitalized).font(.caption2)
                            }
                            .padding(.horizontal, AppSpacing.sm).padding(.vertical, AppSpacing.xs)
                            .background(selectedKinds.contains(kind) ? kind.color.opacity(0.15) : Color(.tertiarySystemFill))
                            .foregroundStyle(selectedKinds.contains(kind) ? kind.color : .secondary)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.md)
            }

            Picker("Zoom", selection: $zoomLevel) {
                ForEach(TimelineZoom.allCases, id: \.rawValue) { z in Text(zoomLabel(z)).tag(z) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func zoomLabel(_ zoom: TimelineZoom) -> String {
        switch zoom {
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        }
    }

    // MARK: Timeline Scroll

    private var timelineScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredClusters.enumerated()), id: \.element.id) { cIdx, cluster in
                    weekSection(cluster: cluster, index: cIdx)
                }
            }
            .padding(.top, 8).padding(.bottom, 32)
        }
    }

    private var filteredClusters: [TimelineCluster] {
        clusters.map { c in
            TimelineCluster(weekStart: c.weekStart, label: c.label,
                            events: c.events.filter { selectedKinds.contains($0.kind) })
        }.filter { !$0.events.isEmpty }
    }

    // MARK: Week Section

    private func weekSection(cluster: TimelineCluster, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Week header with summary bar
            HStack(spacing: 8) {
                Text(cluster.label).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if cluster.decisionCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 8)); Text("\(cluster.decisionCount)").font(.system(size: 9))
                    }.foregroundStyle(.indigo)
                }
                if cluster.riskCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.shield.fill").font(.system(size: 8)); Text("\(cluster.riskCount)").font(.system(size: 9))
                    }.foregroundStyle(.red)
                }
                if cluster.actionCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checklist").font(.system(size: 8)); Text("\(cluster.actionCount)").font(.system(size: 9))
                    }.foregroundStyle(.teal)
                }
                Spacer()
                Text("\(cluster.events.count) events").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))

            // Events in this week
            ForEach(Array(cluster.events.enumerated()), id: \.element.id) { eIdx, event in
                eventRow(event: event, isLast: eIdx == cluster.events.count - 1)
            }
        }
    }

    // MARK: Event Row

    private func eventRow(event: TimelineEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline rail
            VStack(spacing: 0) {
                Circle().fill(event.kind.color).frame(width: 10, height: 10)
                if !isLast { Rectangle().fill(Color(.separator)).frame(width: 2) }
            }.frame(width: 14)

            // Event card
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: iconFor(event.kind)).font(.caption2).foregroundStyle(event.kind.color)
                    Text(event.title).font(.subheadline).lineLimit(2)
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
                if let sub = event.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                // Decision/risk/action pills
                if !event.decisionTitles.isEmpty || !event.riskTitles.isEmpty || !event.actionItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(event.decisionTitles, id: \.self) { d in
                                Text(d).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.indigo.opacity(0.1)).clipShape(Capsule())
                            }
                            ForEach(event.riskTitles, id: \.self) { r in
                                Text(r).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.red.opacity(0.1)).clipShape(Capsule())
                            }
                            ForEach(event.actionItems.prefix(2), id: \.self) { a in
                                Text(a).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.teal.opacity(0.1)).clipShape(Capsule())
                            }
                        }
                    }
                }
                // Connection indicator
                if !event.connectedTo.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(.blue)
                        Text("\(event.connectedTo.count) connection\(event.connectedTo.count > 1 ? "s" : "")").font(.system(size: 9)).foregroundStyle(.blue)
                    }
                }
            }
            .padding(10)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.bottom, 4)
    }

    // MARK: Load

    private func loadTimeline() {
        isLoading = true
        let pid = projectID
        let zoom = zoomLevel
        let ctx = modelContext

        var allEvents: [TimelineEvent] = []
        let calendar = Calendar.current

        let itemDescriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.projectID == pid })
        if let items = try? ctx.fetch(itemDescriptor) {
            for item in items {
                var event = TimelineEvent(id: item.id, title: item.title.isEmpty ? "Untitled" : item.title,
                    subtitle: item.type.label, date: item.createdAt, kind: .from(itemType: item.type), sourceItemID: item.id)

                if let analysis = try? FileArtifactStore().readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
                    event.decisionTitles = analysis.decisions.map { $0.title }
                    event.riskTitles = analysis.risks.map { $0.risk }
                    event.actionItems = analysis.actionItems.map { $0.task }
                    for d in analysis.decisions {
                        allEvents.append(TimelineEvent(id: UUID(), title: d.title, subtitle: "Decision · \(item.title)",
                            date: item.createdAt, kind: .decision, sourceItemID: item.id))
                    }
                    for r in analysis.risks {
                        allEvents.append(TimelineEvent(id: UUID(), title: r.risk, subtitle: "Risk · \(item.title)",
                            date: item.createdAt, kind: .risk, sourceItemID: item.id))
                    }
                    for q in analysis.openQuestions {
                        allEvents.append(TimelineEvent(id: UUID(), title: q.question, subtitle: "Question · \(item.title)",
                            date: item.createdAt, kind: .question, sourceItemID: item.id))
                    }
                }
                allEvents.append(event)
            }
        }

        let taskDescriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.projectID == pid })
        if let tasks = try? ctx.fetch(taskDescriptor) {
            for task in tasks {
                allEvents.append(TimelineEvent(id: task.id, title: task.title,
                    subtitle: "Task · \(task.status.rawValue.capitalized)", date: task.createdAt, kind: .task, sourceItemID: task.sourceItemID))
                if task.status == .done {
                    allEvents.append(TimelineEvent(id: UUID(), title: "Completed: \(task.title)",
                        subtitle: "Task done", date: task.updatedAt, kind: .done, sourceItemID: task.sourceItemID))
                }
            }
        }

        allEvents.sort { $0.date > $1.date }
        let grouped: [Date: [TimelineEvent]]
        switch zoom {
        case .week:
            grouped = Dictionary(grouping: allEvents) { calendar.startOfWeek(for: $0.date) }
        case .month:
            grouped = Dictionary(grouping: allEvents) { calendar.startOfMonth(for: $0.date) }
        case .quarter:
            grouped = Dictionary(grouping: allEvents) { calendar.startOfQuarter(for: $0.date) }
        }
        self.clusters = grouped.map { start, evts in
            let label: String
            let formatter = DateFormatter()
            switch zoom {
            case .week:
                formatter.dateFormat = "MMM d"
                label = "Week of \(formatter.string(from: start))"
            case .month:
                formatter.dateFormat = "MMMM yyyy"
                label = formatter.string(from: start)
            case .quarter:
                let q = calendar.component(.quarter, from: start)
                let y = calendar.component(.year, from: start)
                label = "Q\(q) \(y)"
            }
            return TimelineCluster(weekStart: start, label: label, events: evts.sorted { $0.date > $1.date })
        }.sorted { $0.weekStart > $1.weekStart }

        let edgeSvc = services.edges
        let eventIDs = Set(allEvents.map(\.id))
        if let allEdges = try? edgeSvc.recentEdges(limit: 500) {
            self.connectors = allEdges.compactMap { edge in
                guard eventIDs.contains(edge.fromID) && eventIDs.contains(edge.toID) else { return nil }
                return TimelineConnector(fromEventID: edge.fromID, toEventID: edge.toID, edgeType: edge.edgeType)
            }
        }
        self.isLoading = false
    }

    private func iconFor(_ kind: TimelineEventKind) -> String {
        switch kind {
        case .audio: "mic.fill"; case .note: "note.text"; case .journalEntry: "book.fill"
        case .webBookmark: "bookmark.fill"; case .image: "photo.fill"; case .task: "checklist"
        case .decision: "lightbulb.fill"; case .risk: "exclamationmark.shield.fill"
        case .question: "questionmark.circle.fill"; case .done: "checkmark.circle.fill"
        }
    }
}

extension Calendar {
    func startOfWeek(for date: Date) -> Date {
        let components = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: components) ?? date
    }

    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? date
    }

    func startOfQuarter(for date: Date) -> Date {
        let month = component(.month, from: date)
        let quarterMonth = ((month - 1) / 3) * 3 + 1
        let components = DateComponents(year: component(.year, from: date), month: quarterMonth, day: 1)
        return self.date(from: components) ?? date
    }
}
