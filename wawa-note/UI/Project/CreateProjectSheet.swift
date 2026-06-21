import SwiftUI
import SwiftData

struct CreateProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var selectedTemplate: ProjectTemplate? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $name)
                }

                Section("Template (optional)") {
                    ForEach(ProjectTemplate.allCases, id: \.rawValue) { template in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(template.displayName)
                                    .font(.body)
                                Text(template.frameworkId)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedTemplate == template {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTemplate = (selectedTemplate == template) ? nil : template
                        }
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { createProject() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func createProject() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let service = ProjectService(context: modelContext)
        _ = try? service.create(
            name: trimmed,
            template: selectedTemplate,
            origin: .user
        )
        dismiss()
    }
}
