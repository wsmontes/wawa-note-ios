import SwiftUI

struct OnThisDayView: View {
    let entries: [TimelineEntry]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("On This Day")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries) { entry in
                            card(entry)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func card(_ entry: TimelineEntry) -> some View {
        NavigationLink {
            if let item = entry.wawaItem {
                KnowledgeDetailView(item: item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(String(Calendar.current.component(.year, from: entry.createdAt)))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Image(systemName: entry.typeIcon)
                        .font(.caption2)
                        .foregroundStyle(entry.typeColor)
                }
                Text(entry.title)
                    .font(.caption)
                    .lineLimit(2)
                if let snippet = entry.bodySnippet {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 130)
            .padding(10)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
