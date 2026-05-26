import SwiftUI
import SwiftData

struct ChatListView: View {
    @Query(sort: \ChatConversationModel.updatedAt, order: .reverse) private var conversations: [ChatConversationModel]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedConversation: ChatConversationModel?

    var body: some View {
        NavigationStack {
            if conversations.isEmpty {
                VStack(spacing: 16) {
                    EmptyStateView(
                        systemImage: "message",
                        title: "No conversations yet",
                        message: "Connect a provider to start chatting."
                    )

                    PrimaryActionButton(
                        title: "New Chat",
                        systemImage: "plus.message"
                    ) {
                        let conversation = ChatConversationModel()
                        conversation.title = "New Chat"
                        modelContext.insert(conversation)
                        try? modelContext.save()
                        selectedConversation = conversation
                    }
                    .padding(.horizontal, 32)
                }
                .navigationTitle("Chat")
            } else {
                List {
                    Section {
                        Button {
                            let conversation = ChatConversationModel()
                            conversation.title = "New Chat"
                            modelContext.insert(conversation)
                            try? modelContext.save()
                            selectedConversation = conversation
                        } label: {
                            Label("New Chat", systemImage: "plus.message")
                        }
                    }

                    Section {
                        ForEach(conversations) { conversation in
                            Button {
                                selectedConversation = conversation
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title.isEmpty ? "Chat" : conversation.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    if let model = conversation.model {
                                        Text(model)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(conversation.updatedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteConversations)
                    }
                }
                .navigationTitle("Chat")
                .navigationDestination(item: $selectedConversation) { conversation in
                    ChatView(conversation: conversation)
                }
            }
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(conversations[index])
        }
    }
}

#Preview {
    ChatListView()
}
