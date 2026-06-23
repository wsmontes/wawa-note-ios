import SwiftUI
import SwiftData

struct AttentionRequiredSection: View {
    let projectID: UUID

    @Query private var overdueTasks: [ProjectDerivedItem]
    @Query private var pendingDecisions: [ProjectDerivedItem]
    @Query private var newRisks: [ProjectDerivedItem]

    init(projectID: UUID) {
        self.projectID = projectID
        let pid = projectID
        let todoRaw = ProjectDerivedStatus.todo.rawValue
        let inProgressRaw = ProjectDerivedStatus.inProgress.rawValue
        let taskRaw = ProjectDerivedType.task.rawValue
        let decisionRaw = ProjectDerivedType.decision.rawValue
        let signalRaw = ProjectDerivedType.signal.rawValue
        let now = Date()

        _overdueTasks = Query(
            filter: #Predicate {
                $0.projectID == pid &&
                $0.typeRaw == taskRaw &&
                ($0.statusRaw == todoRaw || $0.statusRaw == inProgressRaw) &&
                $0.dueAt != nil &&
                $0.dueAt! < now
            },
            sort: \ProjectDerivedItem.dueAt, order: .forward
        )
        _pendingDecisions = Query(
            filter: #Predicate {
                $0.projectID == pid && $0.typeRaw == decisionRaw
            },
            sort: \ProjectDerivedItem.createdAt, order: .reverse
        )
        _newRisks = Query(
            filter: #Predicate {
                $0.projectID == pid && $0.typeRaw == signalRaw
            },
            sort: \ProjectDerivedItem.createdAt, order: .reverse
        )
    }

    var body: some View {
        let cards = buildAttentionCards()
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                    Text("Attention Required").font(.headline)
                    Spacer()
                    Text("\(cards.count)").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(Capsule())
                }

                ForEach(cards.prefix(3)) { card in
                    AttentionCard(card: card)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func buildAttentionCards() -> [AttentionCardData] {
        var cards: [AttentionCardData] = []

        for task in overdueTasks.prefix(2) {
            cards.append(AttentionCardData(
                id: "overdue-\(task.id)",
                title: task.title,
                subtitle: task.dueAt.map { "Overdue: \($0.formatted(.relative(presentation: .numeric)))" } ?? "Overdue",
                icon: "clock.badge.exclamationmark.fill",
                color: .red,
                priority: 0
            ))
        }

        for decision in pendingDecisions.prefix(2) {
            cards.append(AttentionCardData(
                id: "decision-\(decision.id)",
                title: decision.title,
                subtitle: "Decision pending · \(decision.createdAt.formatted(.relative(presentation: .numeric)))",
                icon: "hammer.fill",
                color: .orange,
                priority: 1
            ))
        }

        for risk in newRisks.prefix(1) {
            cards.append(AttentionCardData(
                id: "risk-\(risk.id)",
                title: risk.title,
                subtitle: "Risk detected · \(risk.createdAt.formatted(.relative(presentation: .numeric)))",
                icon: "exclamationmark.triangle.fill",
                color: .yellow,
                priority: 2
            ))
        }

        return cards.sorted { $0.priority < $1.priority }
    }
}

private struct AttentionCardData: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let priority: Int
}

private struct AttentionCard: View {
    let card: AttentionCardData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: card.icon)
                .font(.title3)
                .foregroundStyle(card.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.subheadline).fontWeight(.medium)
                Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
