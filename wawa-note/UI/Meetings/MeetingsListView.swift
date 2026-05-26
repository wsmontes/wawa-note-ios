import SwiftUI
import SwiftData

struct MeetingsListView: View {
    @Query(sort: \MeetingModel.createdAt, order: .reverse) private var meetings: [MeetingModel]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            if meetings.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: "No meetings yet",
                    message: "Start a short test recording to see how summaries work."
                )
                .navigationTitle("Meetings")
            } else {
                List {
                    ForEach(meetings) { meeting in
                        NavigationLink {
                            MeetingDetailView(meeting: meeting)
                        } label: {
                            meetingRow(meeting)
                        }
                    }
                    .onDelete(perform: deleteMeetings)
                }
                .navigationTitle("Meetings")
            }
        }
    }

    private func meetingRow(_ meeting: MeetingModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                .font(.headline)

            HStack(spacing: 8) {
                Text(meeting.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(meeting.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let duration = meeting.durationSeconds {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                AppStatusBadge(
                    title: meeting.status.rawValue.capitalized,
                    tone: statusTone(for: meeting.status)
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func statusTone(for status: MeetingStatus) -> BadgeTone {
        switch status {
        case .transcribed, .analyzed: .success
        case .failed: .error
        case .recording, .transcribing, .analyzing: .warning
        default: .neutral
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 {
            return "\(m / 60)h \(m % 60)m"
        }
        return "\(m)m"
    }

    private let fileStore = FileArtifactStore()

    private func deleteMeetings(at offsets: IndexSet) {
        for index in offsets {
            let meeting = meetings[index]
            try? fileStore.deleteMeetingDirectory(for: meeting.id)
            modelContext.delete(meeting)
        }
    }
}

#Preview {
    MeetingsListView()
}
