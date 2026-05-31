import SwiftUI
import SwiftData

struct PromoteToProjectSheet: View {
    let item: KnowledgeItem
    let onComplete: (Project) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var contentPipeline: ContentPipelineService

    @State private var isGenerating = false
    @State private var preview: ConversionPreview?
    @State private var errorMessage: String?
    @State private var selectedModel: String = ""

    init(item: KnowledgeItem, onComplete: @escaping (Project) -> Void) {
        self.item = item
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = errorMessage {
                    errorView(error)
                } else if let preview {
                    previewContent(preview)
                } else if isGenerating {
                    generatingView
                } else {
                    configView
                }
            }
            .navigationTitle("Promote to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            selectedModel = ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
        }
    }

    // MARK: - Config

    private var configView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Create Project from Meeting")
                .font(.title2)
                .fontWeight(.semibold)
            Text("AI will extract tasks, people, entities, and relationships from the analysis.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            ActiveModelPicker(selectedModel: $selectedModel, label: "Model")
            Button {
                Task { await generatePreview() }
            } label: {
                Label("Generate Project", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Analyzing meeting...")
                .font(.headline)
            Text("Extracting tasks, people, and structure")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Error

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Could not generate preview")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                isGenerating = true
                errorMessage = nil
                Task { await generatePreview() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    // MARK: - Preview

    private func previewContent(_ preview: ConversionPreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Project name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(preview.projectName)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)

                // Tasks
                if !preview.tasks.isEmpty {
                    sectionHeader("Tasks (\(preview.tasks.count))", icon: "checklist")

                    VStack(spacing: 0) {
                        ForEach(Array(preview.tasks.enumerated()), id: \.element.id) { idx, task in
                            taskRow(task)
                            if idx < preview.tasks.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                // People
                if !preview.people.isEmpty {
                    sectionHeader("People (\(preview.people.count))", icon: "person.2")

                    VStack(spacing: 0) {
                        ForEach(Array(preview.people.enumerated()), id: \.element.id) { idx, person in
                            personRow(person)
                            if idx < preview.people.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                // Entities
                if !preview.entities.isEmpty {
                    sectionHeader("Entities", icon: "cube")

                    VStack(spacing: 0) {
                        ForEach(Array(preview.entities.enumerated()), id: \.element.id) { idx, entity in
                            entityRow(entity)
                            if idx < preview.entities.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                // Edges
                if !preview.edges.isEmpty {
                    sectionHeader("Relationships (\(preview.edges.count))", icon: "link")

                    VStack(spacing: 0) {
                        ForEach(Array(preview.edges.enumerated()), id: \.element.id) { idx, edge in
                            edgeRow(edge)
                            if idx < preview.edges.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                // Confirm button
                Button {
                    executeConversion(preview)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Create Project")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer().frame(height: 24)
            }
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Rows

    private func taskRow(_ task: ConversionPreview.ConversionTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                if let owner = task.ownerName {
                    Text("Owner: \(owner)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let priority = task.priority {
                Text(priority)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(priorityColor(priority).opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(12)
    }

    private func personRow(_ person: ConversionPreview.ConversionPerson) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.purple)
            Text(person.displayName)
                .font(.subheadline)
            if let role = person.role {
                Text("· \(role)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func entityRow(_ entity: ConversionPreview.ConversionEntity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entityKindIcon(entity.kind))
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.displayName)
                    .font(.subheadline)
                Text(entity.kind.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func edgeRow(_ edge: ConversionPreview.ConversionEdge) -> some View {
        HStack(spacing: 8) {
            Text(edge.fromRef)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
            Text(edge.toRef)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(edge.edgeType)
                .font(.caption2)
                .foregroundStyle(.blue)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "critical": return .red
        case "high": return .orange
        case "low": return .green
        default: return .blue
        }
    }

    private func entityKindIcon(_ kind: String) -> String {
        switch kind {
        case "organization": return "building.2"
        case "system": return "server.rack"
        case "repository": return "chevron.left.forwardslash.chevron.right"
        case "ticket": return "tag"
        case "location": return "location"
        default: return "cube"
        }
    }

    // MARK: - Actions

    private func makeService() -> ProjectConversionService {
        ProjectConversionService(context: modelContext)
    }

    private func generatePreview() async {
        isGenerating = true
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            errorMessage = "No AI provider configured. Go to Settings to add one."
            isGenerating = false
            return
        }

        do {
            let model = selectedModel.isEmpty
                ? ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
                : selectedModel
            let preview = try await makeService().generatePreview(from: item, using: provider, model: model)
            self.preview = preview
        } catch let error as ProviderError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func executeConversion(_ preview: ConversionPreview) {
        do {
            let project = try makeService().executeConversion(from: item, preview: preview)
            // Pipeline handles analysis + ingestion (Step 3 picks up projectID from re-fetch)
            // ProjectDetailView will show progress via ingestionState environment object
            contentPipeline.process( item.id, using: modelContext)
            dismiss()
            onComplete(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
