import SwiftUI
// Related JIRA: KAN-141


// MARK: - JSON Form View

/// Renders any JSON as an interactive, editable form with collapsible sections.
/// Adapts automatically to any JSON structure — strings, numbers, booleans,
/// nested objects, and arrays.
/// Uses NavigationLink for nested navigation instead of a nested NavigationStack
/// to avoid conflicts with the parent navigation context.
struct JSONFormView: View {
    let root: JSONValue
    let onUpdate: (JSONValue) -> Void

    @State private var editedRoot: JSONValue
    @State private var expandedKeys: Set<String> = []

    init(root: JSONValue, onUpdate: @escaping (JSONValue) -> Void) {
        self.root = root
        self.onUpdate = onUpdate
        _editedRoot = State(initialValue: root)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch editedRoot {
                case .object(let fields):
                    ForEach(fields) { field in
                        JSONFieldRow(
                            key: field.key,
                            value: binding(for: field.id, in: fields),
                            isExpanded: isExpanded(field.key),
                            onToggle: { toggleExpanded(field.key) },
                            onNavigate: nil
                        )
                    }
                    addFieldButton(for: fields)
                case .array(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        JSONFieldRow(
                            key: "[\(idx)]",
                            value: binding(forArrayIndex: idx),
                            isExpanded: isExpanded("[\(idx)]"),
                            onToggle: { toggleExpanded("[\(idx)]") },
                            onNavigate: nil
                        )
                    }
                    addArrayItemButton(for: items)
                default:
                    JSONPrimitiveRow(
                        key: "value",
                        value: bindingForPrimitiveRoot(),
                        onUpdate: { saveRoot() }
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { saveRoot() }
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Bindings

    private func binding(for fieldID: UUID, in fields: [JSONField]) -> Binding<JSONValue> {
        Binding(
            get: {
                fields.first(where: { $0.id == fieldID })?.value ?? .null
            },
            set: { newValue in
                guard case .object(var newFields) = editedRoot else { return }
                if let idx = newFields.firstIndex(where: { $0.id == fieldID }) {
                    newFields[idx] = JSONField(key: newFields[idx].key, value: newValue)
                    editedRoot = .object(newFields)
                }
            }
        )
    }

    private func binding(forArrayIndex index: Int) -> Binding<JSONValue> {
        Binding(
            get: {
                guard case .array(let items) = editedRoot, index < items.count else { return .null }
                return items[index]
            },
            set: { newValue in
                guard case .array(var items) = editedRoot, index < items.count else { return }
                items[index] = newValue
                editedRoot = .array(items)
            }
        )
    }

    private func bindingForPrimitiveRoot() -> Binding<JSONValue> {
        Binding(
            get: { editedRoot },
            set: { editedRoot = $0 }
        )
    }

    // MARK: - Actions

    private func saveRoot() {
        onUpdate(editedRoot)
    }

    private func toggleExpanded(_ key: String) {
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
        } else {
            expandedKeys.insert(key)
        }
    }

    private func isExpanded(_ key: String) -> Bool {
        expandedKeys.contains(key)
    }

    private func updateNestedValue(at path: String, with newValue: JSONValue) {
        let keys = path.components(separatedBy: ".")
        guard !keys.isEmpty, case .object(var fields) = editedRoot else { return }
        updateFields(&fields, keys: keys, newValue: newValue)
        editedRoot = .object(fields)
    }

    private func updateFields(_ fields: inout [JSONField], keys: [String], newValue: JSONValue) {
        guard let first = keys.first else { return }
        guard let idx = fields.firstIndex(where: { $0.key == first }) else { return }
        if keys.count == 1 {
            fields[idx].value = newValue
        } else if case .object(var nested) = fields[idx].value {
            updateFields(&nested, keys: Array(keys.dropFirst()), newValue: newValue)
            fields[idx].value = .object(nested)
        }
    }

    // MARK: - Add Buttons

    private func addFieldButton(for fields: [JSONField]) -> some View {
        Button {
            guard case .object(var newFields) = editedRoot else { return }
            newFields.append(JSONField(key: "newKey", value: .string(""), isNew: true))
            editedRoot = .object(newFields)
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text("Add Field").font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func addArrayItemButton(for items: [JSONValue]) -> some View {
        Button {
            guard case .array(var newItems) = editedRoot else { return }
            // Add an empty string as default
            newItems.append(.string(""))
            editedRoot = .array(newItems)
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text("Add Item").font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - JSON Field Row

/// Renders a single JSON field based on its value type.
struct JSONFieldRow: View {
    let key: String
    @Binding var value: JSONValue
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNavigate: ((JSONFormSection) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            switch value {
            case .string, .number, .bool, .null:
                JSONPrimitiveRow(key: key, value: $value, onUpdate: {})
                    .padding(.horizontal, 16)

            case .object(let fields):
                NavigationLink {
                    JSONFormView(root: value) { updatedValue in
                        value = updatedValue
                    }
                    .navigationTitle(key)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    JSONObjectRow(
                        key: key, fields: fields,
                        value: $value, isExpanded: isExpanded,
                        onToggle: onToggle
                    )
                }
                .buttonStyle(.plain)

            case .array(let items):
                NavigationLink {
                    JSONFormView(root: value) { updatedValue in
                        value = updatedValue
                    }
                    .navigationTitle(key)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    JSONArrayRow(
                        key: key, items: items,
                        value: $value, isExpanded: isExpanded,
                        onToggle: onToggle
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.leading, 16)
        }
    }
}

// MARK: - Primitive Row (String, Number, Bool, Null)

struct JSONPrimitiveRow: View {
    let key: String
    @Binding var value: JSONValue
    let onUpdate: () -> Void

    @State private var textValue: String
    @State private var boolValue: Bool
    @State private var selectedType: String

    init(key: String, value: Binding<JSONValue>, onUpdate: @escaping () -> Void) {
        self.key = key
        _value = value
        self.onUpdate = onUpdate
        switch value.wrappedValue {
        case .string(let s): _textValue = State(initialValue: s); _boolValue = State(initialValue: false); _selectedType = State(initialValue: "string")
        case .number(let s): _textValue = State(initialValue: s); _boolValue = State(initialValue: false); _selectedType = State(initialValue: "number")
        case .bool(let b): _textValue = State(initialValue: ""); _boolValue = State(initialValue: b); _selectedType = State(initialValue: "bool")
        case .null: _textValue = State(initialValue: ""); _boolValue = State(initialValue: false); _selectedType = State(initialValue: "null")
        default: _textValue = State(initialValue: ""); _boolValue = State(initialValue: false); _selectedType = State(initialValue: "string")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Key label
            HStack(spacing: 6) {
                Text(key)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                // Type picker
                Picker("", selection: $selectedType) {
                    Text("Text").tag("string")
                    Text("Number").tag("number")
                    Text("Bool").tag("bool")
                    Text("Null").tag("null")
                }
                .pickerStyle(.menu)
                .font(.caption2)
                .onChange(of: selectedType) { _, newType in
                    switch newType {
                    case "string": value = .string(textValue)
                    case "number": value = .number(textValue)
                    case "bool":   value = .bool(boolValue)
                    case "null":   value = .null
                    default: break
                    }
                    onUpdate()
                }
            }

            // Value editor
            switch selectedType {
            case "string":
                TextField("value", text: $textValue, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: textValue) { _, v in
                        value = .string(v)
                        onUpdate()
                    }
            case "number":
                TextField("0", text: $textValue)
                    .font(.body).keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: textValue) { _, v in
                        value = .number(v)
                        onUpdate()
                    }
            case "bool":
                Toggle(isOn: $boolValue) {
                    Text(boolValue ? "true" : "false").font(.body).foregroundStyle(.secondary)
                }
                .onChange(of: boolValue) { _, v in
                    value = .bool(v)
                    onUpdate()
                }
            case "null":
                Text("null")
                    .font(.body).foregroundStyle(.tertiary).italic()
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Object Row

struct JSONObjectRow: View {
    let key: String
    let fields: [JSONField]
    @Binding var value: JSONValue
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 16)
            Image(systemName: "curlybraces")
                .font(.caption).foregroundStyle(.teal)
            Text(key)
                .font(.subheadline).fontWeight(.medium)
            Spacer()
            Text("{ \(fields.count) }")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.teal.opacity(0.1)).clipShape(Capsule())
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Array Row

struct JSONArrayRow: View {
    let key: String
    let items: [JSONValue]
    @Binding var value: JSONValue
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 16)
            Image(systemName: "list.bullet.rectangle")
                .font(.caption).foregroundStyle(.orange)
            Text(key)
                .font(.subheadline).fontWeight(.medium)
            Spacer()
            Text("[ \(items.count) ]")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.orange.opacity(0.1)).clipShape(Capsule())
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - JSON Form Detail View (for nested navigation)

struct JSONFormDetailView: View {
    let section: JSONFormSection
    let onUpdate: (JSONValue) -> Void

    @State private var editedValue: JSONValue

    init(section: JSONFormSection, onUpdate: @escaping (JSONValue) -> Void) {
        self.section = section
        self.onUpdate = onUpdate
        _editedValue = State(initialValue: section.value)
    }

    var body: some View {
        JSONFormView(root: editedValue) { updated in
            editedValue = updated
            onUpdate(updated)
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
