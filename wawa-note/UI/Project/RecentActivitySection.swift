import SwiftData
import SwiftUI

struct RecentActivitySection: View {
    let projectID: UUID
    @Query private var recentItems: [KnowledgeItem]
    @Query private var recentDerived: [ProjectDerivedItem]

    init(projectID: UUID) {
        self.projectID = projectID
        let pid = projectID
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        _recentItems = Query(
            filter: #Predicate { $0.projectID == pid && $0.updatedAt > sevenDaysAgo },
            sort: \KnowledgeItem.updatedAt, order: .reverse
        )
        _recentDerived = Query(
            filter: #Predicate { $0.projectID == pid && $0.updatedAt > sevenDaysAgo },
            sort: \ProjectDerivedItem.updatedAt, order: .reverse
        )
    }

    var body: some View {
        let events = combinedEvents().prefix(5)
        if !Array(events).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Activity").font(.headline)

                ForEach(Array(events), id: \.id) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.icon)
                            .font(.caption)
                            .foregroundStyle(event.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline)
                            Text(event.time.formatted(.relative(presentation: .numeric)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func combinedEvents() -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for item in recentItems.prefix(5) {
            events.append(
                ActivityEvent(
                    id: item.id.uuidString,
                    title: item.title,
                    time: item.updatedAt,
                    icon: item.type == .audio ? "recordingtape" : "doc.text",
                    color: .blue
                ))
        }
        for derived in recentDerived.prefix(5) {
            let (icon, color): (String, Color) = {
                switch derived.type {
                case .task: return derived.status == .done ? ("checkmark.circle", .green) : ("circle", .orange)
                case .signal: return ("exclamationmark.triangle", .yellow)
                case .synthesis: return ("sparkles", .purple)
                case .connection: return ("link", .blue)
                case .decision: return ("hammer.fill", .orange)
                case .question: return ("questionmark.bubble.fill", .blue)
                }
            }()
            events.append(
                ActivityEvent(
                    id: derived.id.uuidString,
                    title: derived.title,
                    time: derived.updatedAt,
                    icon: icon, color: color
                ))
        }
        return events.sorted(by: { $0.time > $1.time })
    }
}

private struct ActivityEvent {
    let id: String
    let title: String
    let time: Date
    let icon: String
    let color: Color
}
