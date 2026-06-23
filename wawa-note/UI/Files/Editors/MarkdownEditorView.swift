import SwiftUI
// Related JIRA: KAN-141, KAN-137


/// Markdown file editor with Edit and Preview modes.
struct MarkdownEditorView: View {
    let node: VFSNode
    let viewModel: FileBrowserViewModel

    @State private var content: String
    @State private var hasChanges = false
    @State private var mode: EditorMode = .edit
    @Environment(\.dismiss) private var dismiss

    enum EditorMode: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
    }

    init(node: VFSNode, viewModel: FileBrowserViewModel) {
        self.node = node
        self.viewModel = viewModel
        _content = State(initialValue: viewModel.readFileContent(node.path) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode picker
            Picker("Mode", selection: $mode) {
                ForEach(EditorMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .edit:
                TextEditor(text: $content)
                    .font(.body)
                    .padding(8)
                    .onChange(of: content) { _, _ in
                        hasChanges = content != (viewModel.readFileContent(node.path) ?? "")
                    }
            case .preview:
                ScrollView {
                    let md = (try? AttributedString(markdown: content,
                        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(content)
                    Text(md)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(node.name.replacingOccurrences(of: ".md", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasChanges {
                    Button("Save") {
                        if viewModel.writeFileContent(node.path, content: content) {
                            hasChanges = false
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if hasChanges {
                    Button("Cancel") {
                        content = viewModel.readFileContent(node.path) ?? ""
                        hasChanges = false
                    }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
    }
}
