import SwiftUI

/// JSON file editor with Raw, Pretty, and Form modes.
/// Form mode provides a user-friendly, adaptive interface for any JSON structure.
struct JSONEditorView: View {
    let node: VFSNode
    let viewModel: FileBrowserViewModel

    @State private var content: String
    @State private var hasChanges = false
    @State private var jsonError: String?
    @State private var mode: EditorMode = .form
    @State private var parsedJSON: JSONValue?
    @Environment(\.dismiss) private var dismiss

    enum EditorMode: String, CaseIterable {
        case form = "Form"
        case pretty = "Pretty"
        case raw = "Raw"
    }

    init(node: VFSNode, viewModel: FileBrowserViewModel) {
        self.node = node
        self.viewModel = viewModel
        let raw = viewModel.readFileContent(node.path) ?? ""
        _content = State(initialValue: raw)
        _parsedJSON = State(initialValue: JSONValue.parse(raw))
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

            // Content area
            switch mode {
            case .form:
                if let json = parsedJSON {
                    JSONFormView(root: json) { updatedValue in
                        let newContent = updatedValue.toJSON()
                        content = newContent
                        parsedJSON = updatedValue
                        hasChanges = true
                        jsonError = nil
                    }
                } else {
                    invalidJSONView
                }

            case .pretty:
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .onChange(of: content) { _, _ in
                        hasChanges = true
                        jsonError = nil
                    }

            case .raw:
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .onChange(of: content) { _, _ in
                        hasChanges = true
                        jsonError = nil
                    }
            }

            // Error banner
            if let error = jsonError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasChanges {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if hasChanges {
                    Button("Cancel") {
                        content = viewModel.readFileContent(node.path) ?? ""
                        parsedJSON = JSONValue.parse(content)
                        hasChanges = false
                        jsonError = nil
                    }
                }
            }
            if mode != .form {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { prettyPrint() } label: {
                            Label("Pretty Print", systemImage: "text.alignleft")
                        }
                        Button { validateOnly() } label: {
                            Label("Validate", systemImage: "checkmark.shield")
                        }
                        Button { switchToForm() } label: {
                            Label("Open in Form", systemImage: "rectangle.3.group")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
    }

    // MARK: - Invalid JSON

    private var invalidJSONView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text("Invalid JSON")
                .font(.headline)
            Text("This file doesn't contain valid JSON.\nSwitch to Raw mode to edit the content.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Edit in Raw Mode") {
                mode = .raw
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func save() {
        guard validateJSON() else { return }
        if viewModel.writeFileContent(node.path, content: content) {
            hasChanges = false
        }
    }

    private func prettyPrint() {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            jsonError = "Invalid JSON — cannot pretty-print"
            return
        }
        content = pretty
        jsonError = nil
        parsedJSON = JSONValue.parse(content)
    }

    private func validateOnly() {
        if validateJSON() { jsonError = nil }
    }

    private func switchToForm() {
        if validateJSON() {
            mode = .form
            parsedJSON = JSONValue.parse(content)
        }
    }

    @discardableResult
    private func validateJSON() -> Bool {
        guard let data = content.data(using: .utf8) else {
            jsonError = "Invalid UTF-8 encoding"
            return false
        }
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
        jsonError = "Invalid JSON syntax"
        return false
    }
}
