import SwiftUI

struct MeetingsListView: View {
    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: "No meetings yet",
                message: "Start a short test recording to see how summaries work."
            )
            .navigationTitle("Meetings")
        }
    }
}

#Preview {
    MeetingsListView()
}
