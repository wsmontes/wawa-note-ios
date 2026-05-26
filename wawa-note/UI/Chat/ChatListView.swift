import SwiftUI

struct ChatListView: View {
    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "message",
                title: "No conversations yet",
                message: "Connect a provider to start chatting."
            )
            .navigationTitle("Chat")
        }
    }
}

#Preview {
    ChatListView()
}
