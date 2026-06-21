import SwiftUI

struct FrameworkPickerView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let frameworks: [(String, String, String)] = [
        ("builtin/meeting", "Meeting", "Decisions, action items, people tracking"),
        ("builtin/research", "Research", "Sources, analysis, conclusions"),
        ("builtin/brainstorm", "Brainstorm", "Ideas, diverging, converging"),
        ("builtin/journal", "Journal", "Personal reflection, mood tracking"),
        ("builtin/coaching", "Coaching", "Goals, progress, feedback"),
        ("builtin/legal", "Legal", "Claims, evidence, rulings"),
        ("builtin/product", "Product", "Features, specs, roadmap"),
        ("builtin/blank", "Blank", "No preset — fully custom"),
    ]

    var body: some View {
        NavigationStack {
            List(frameworks, id: \.0) { (id, name, desc) in
                HStack {
                    VStack(alignment: .leading) {
                        Text(name).font(.body)
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if project.frameworkId == id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let fields = ProjectUpdateFields(frameworkId: id)
                    _ = try? ProjectService(context: modelContext).update(
                        id: project.id, fields: fields, origin: .user
                    )
                    dismiss()
                }
            }
            .navigationTitle("Choose Framework")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
