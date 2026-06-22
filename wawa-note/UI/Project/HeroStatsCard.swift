import SwiftUI

struct HeroStatsCard: View {
    let project: Project
    let itemCount: Int
    let taskCount: Int
    let openTaskCount: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                statItem(value: "\(itemCount)", label: "Items", icon: "doc.text", color: .blue)
                statItem(value: "\(taskCount)", label: "Tasks", icon: "checklist", color: .green)
                statItem(value: "\(openTaskCount)", label: "Open", icon: "circle", color: .orange)
            }

            if project.lastActivityAt != nil || project.healthScore != nil {
                Divider()
                HStack {
                    if let lastActivity = project.lastActivityAt {
                        Label("Last activity: \(lastActivity.formatted(.relative(presentation: .numeric)))", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let score = project.healthScore {
                        Label("\(Int(score * 100))%", systemImage: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(healthColor(score))
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2).fontWeight(.bold)
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption2)
            }
            .foregroundStyle(color)
        }
    }

    private func healthColor(_ score: Double) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return .red
    }
}
