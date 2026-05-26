import SwiftUI

struct ChatListView: View {
    var body: some View {
        NavigationStack {
            Text("No conversations yet")
                .navigationTitle("Chat")
        }
    }
}

#Preview {
    ChatListView()
}
