import SwiftData
import SwiftUI

struct NoteEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var contentPipeline: ContentPipelineService
  @EnvironmentObject private var processingQueue: ProcessingQueueService

  enum Mode {
    case create(type: KnowledgeItemType, folderID: UUID?, initialTag: String?)
    case edit(item: KnowledgeItem)
  }

  let mode: Mode

  @State private var title: String
  @State private var bodyText: String
  @FocusState private var isBodyFocused: Bool

  init(mode: Mode) {
    self.mode = mode
    switch mode {
    case .create(let type, _, _):
      _title = State(initialValue: "")
      _bodyText = State(initialValue: "")
    case .edit(let item):
      _title = State(initialValue: item.title)
      _bodyText = State(initialValue: item.bodyText ?? "")
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        TextField("Title", text: $title)
          .font(.title2.bold())
          .padding(.horizontal, 16)
          .padding(.top, 12)
          .focused($isBodyFocused, equals: false)

        Divider().padding(.vertical, 8)

        ZStack(alignment: .topLeading) {
          if bodyText.isEmpty {
            Text("Write here...")
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
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save", action: save)
            .fontWeight(.semibold)
            .disabled(
              title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ToolbarItem(placement: .keyboard) {
          HStack(spacing: 16) {
            Button {
              surroundSelection(with: "**")
            } label: {
              Image(systemName: "bold")
            }
            Button {
              surroundSelection(with: "*")
            } label: {
              Image(systemName: "italic")
            }
            Button {
              insertPrefixForSelectedLine("- ")
            } label: {
              Image(systemName: "list.bullet")
            }
            Spacer()
            Button {
              dismissKeyboard()
            } label: {
              Text("Done")
                .fontWeight(.semibold)
            }
          }
          .padding(.vertical, 4)
        }
      }
      .onAppear {
        isBodyFocused = true
      }
    }
  }

  private var navigationTitle: String {
    switch mode {
    case .create(let type, _, _):
      switch type {
      case .note: "New Note"
      case .journalEntry: "New Journal"
      default: "New"
      }
    case .edit: "Edit"
    }
  }

  private func save() {
    switch mode {
    case .create(let type, let folderID, let initialTag):
      var tags: [String] = []
      if let tag = initialTag { tags.append(tag) }

      let service = KnowledgeItemService(context: modelContext)
      guard
        let item = try? service.createItem(
          type: type,
          title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled" : title.trimmingCharacters(in: .whitespacesAndNewlines),
          bodyText: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : bodyText,
          folderID: folderID,
          tags: tags
        )
      else { return }

      // Mark as user-created
      var prov = item.provenance
      prov.mark(field: "title", origin: .user)
      if item.bodyText != nil { prov.mark(field: "bodyText", origin: .user) }
      item.fieldProvenanceJSON = prov.encode()

      // If journal, add mood tag if present
      if type == .journalEntry, let moodTag = initialTag {
        item.tags = [moodTag]
        try? modelContext.save()
      }

      // Trigger pipeline for analysis if there's content
      if let body = item.bodyText, !body.isEmpty {
        processingQueue.enqueue(itemID: item.id, trigger: .newCapture)
      }

    case .edit(let item):
      let service = KnowledgeItemService(context: modelContext)
      try? service.updateItem(
        item,
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        bodyText: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bodyText,
        tags: nil
      )
      // Mark fields as user-edited
      var prov = item.provenance
      prov.mark(field: "title", origin: .user)
      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        prov.mark(field: "bodyText", origin: .user)
      }
      item.fieldProvenanceJSON = prov.encode()
      try? modelContext.save()
    }

    dismiss()
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

  private func dismissKeyboard() {
    isBodyFocused = false
  }
}
