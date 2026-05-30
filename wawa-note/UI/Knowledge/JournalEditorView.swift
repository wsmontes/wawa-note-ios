import SwiftUI

struct JournalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum Mode {
        case create(folderID: UUID?)
        case edit(item: KnowledgeItem)
    }

    let mode: Mode

    @State private var title: String
    @State private var bodyText: String
    @State private var selectedMood: JournalMood?
    @FocusState private var isBodyFocused: Bool

    enum JournalMood: String, CaseIterable {
        case great = "Great"
        case good = "Good"
        case neutral = "Neutral"
        case bad = "Bad"
        case awful = "Awful"

        var emoji: String {
            switch self {
            case .great: return "😄"
            case .good: return "🙂"
            case .neutral: return "😐"
            case .bad: return "😔"
            case .awful: return "😞"
            }
        }

        var tag: String { "mood/\(rawValue.lowercased())" }
    }

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _bodyText = State(initialValue: "")
            _selectedMood = State(initialValue: nil)
        case .edit(let item):
            _title = State(initialValue: item.title)
            _bodyText = State(initialValue: item.bodyText ?? "")
            let moodTag = item.tags.first { $0.hasPrefix("mood/") }
            if let moodTag, let mood = JournalMood.allCases.first(where: { moodTag == $0.tag }) {
                _selectedMood = State(initialValue: mood)
            } else {
                _selectedMood = State(initialValue: nil)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dateHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                moodPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                TextField("Title", text: $title)
                    .font(.title2.bold())
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Divider().padding(.vertical, 8)

                ZStack(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text("What's on your mind today?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    TextEditor(text: $bodyText)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .focused($isBodyFocused, equals: true)
                        .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack(spacing: 16) {
                        Button { surroundSelection(with: "**") } label: {
                            Image(systemName: "bold")
                        }
                        Button { surroundSelection(with: "*") } label: {
                            Image(systemName: "italic")
                        }
                        Button { insertPrefixForSelectedLine("- ") } label: {
                            Image(systemName: "list.bullet")
                        }
                        Spacer()
                        Button("Done") { isBodyFocused = false }
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onAppear { isBodyFocused = true }
        }
    }

    private var dateHeader: some View {
        HStack {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text(displayDate.formatted(date: .complete, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var displayDate: Date {
        switch mode {
        case .create: Date()
        case .edit(let item): item.createdAt
        }
    }

    private var moodPicker: some View {
        HStack(spacing: 16) {
            Text("Mood").font(.subheadline).foregroundStyle(.secondary)
            ForEach(JournalMood.allCases, id: \.self) { mood in
                Button {
                    selectedMood = (selectedMood == mood) ? nil : mood
                } label: {
                    Text(mood.emoji)
                        .font(.title2)
                        .opacity(selectedMood == mood ? 1.0 : 0.35)
                }
            }
        }
    }

    // MARK: - Formatting helpers

    private func surroundSelection(with wrapper: String) {
        let marker = wrapper + wrapper
        bodyText += marker + "text" + marker
    }

    private func insertPrefixForSelectedLine(_ prefix: String) {
        if bodyText.isEmpty || bodyText.hasSuffix("\n") {
            bodyText += prefix
        } else {
            bodyText += "\n" + prefix
        }
    }

    private func save() {
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Date().formatted(date: .abbreviated, time: .omitted)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let service = KnowledgeItemService(context: modelContext)

        switch mode {
        case .create(let folderID):
            var tags: [String] = []
            if let mood = selectedMood { tags.append(mood.tag) }

            if let item = try? service.createItem(
                type: .journalEntry,
                title: finalTitle,
                bodyText: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bodyText,
                folderID: folderID,
                tags: tags
            ), let body = item.bodyText, !body.isEmpty {
                ContentPipelineService.shared.process( item.id, using: modelContext)
            }

        case .edit(let item):
            var tags = item.tags.filter { !$0.hasPrefix("mood/") }
            if let mood = selectedMood { tags.append(mood.tag) }

            try? service.updateItem(
                item,
                title: finalTitle,
                bodyText: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bodyText,
                tags: tags
            )
        }

        dismiss()
    }
}
