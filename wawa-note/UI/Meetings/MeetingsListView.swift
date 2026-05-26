import SwiftUI

struct MeetingsListView: View {
    var body: some View {
        NavigationStack {
            Text("No meetings yet")
                .navigationTitle("Meetings")
        }
    }
}

#Preview {
    MeetingsListView()
}
