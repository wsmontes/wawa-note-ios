import SwiftUI
import SwiftData
// Related JIRA: KAN-8, KAN-34


struct PromoteToProjectSheet: View {
    let item: KnowledgeItem
    let onComplete: (Project) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @EnvironmentObject private var processingQueue: ProcessingQueueService

    @State private var isGenerating = false
    @State private var preview: ConversionPreview?
    @State private var errorMessage: String?
    @State private var selectedModel: String = ""
    @State private var selectedTaskIDs: Set<String> = []
    @State private var selectedPersonIDs: Set<String> = []
    @State private var selectedEntityIDs: Set<String> = []
    @State private var selectedEdgeIDs: Set<String> = []
    @State private var generationStep: String = ""
    @State private var selectedTemplate: ProjectTemplate? = nil

    private var allSelected: Bool {
        guard let preview else { return false }
        return selectedTaskIDs.count == preview.tasks.count
    }

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
                if preview != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(allSelected ? "Deselect All" : "Select All") { selectAll() }
                    }
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
            Text("Create Project from Item")
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
            Text(generationStep.isEmpty ? "Analyzing item..." : generationStep)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(preview.projectName).font(.title3).fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)

                if !preview.tasks.isEmpty {
                    sectionHeader("Tasks (\(selectedTaskIDs.count)/\(preview.tasks.count))", icon: "checklist")
                    VStack(spacing: 0) {
                        ForEach(Array(preview.tasks.enumerated()), id: \.element.id) { idx, task in
                            selectableRow(
                                isSelected: selectedTaskIDs.contains(task.id),
                                onToggle: { selectedTaskIDs.toggle(task.id) }
                            ) {
                                taskRowContent(task)
                            }
                            if idx < preview.tasks.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .padding(.horizontal, AppSpacing.lg)
                }

                if !preview.people.isEmpty {
                    sectionHeader("People (\(selectedPersonIDs.count)/\(preview.people.count))", icon: "person.2")
                    VStack(spacing: 0) {
                        ForEach(Array(preview.people.enumerated()), id: \.element.id) { idx, person in
                            selectableRow(
                                isSelected: selectedPersonIDs.contains(person.id),
                                onToggle: { selectedPersonIDs.toggle(person.id) }
                            ) {
                                personRowContent(person)
                            }
                            if idx < preview.people.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .padding(.horizontal, AppSpacing.lg)
                }

                if !preview.entities.isEmpty {
                    sectionHeader("Entities (\(selectedEntityIDs.count)/\(preview.entities.count))", icon: "cube")
                    VStack(spacing: 0) {
                        ForEach(Array(preview.entities.enumerated()), id: \.element.id) { idx, entity in
                            selectableRow(
                                isSelected: selectedEntityIDs.contains(entity.id),
                                onToggle: { selectedEntityIDs.toggle(entity.id) }
                            ) {
                                entityRowContent(entity)
                            }
                            if idx < preview.entities.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .padding(.horizontal, AppSpacing.lg)
                }

                if !preview.edges.isEmpty {
                    sectionHeader("Relationships (\(selectedEdgeIDs.count)/\(preview.edges.count))", icon: "link")
                    VStack(spacing: 0) {
                        ForEach(Array(preview.edges.enumerated()), id: \.element.id) { idx, edge in
                            selectableRow(
                                isSelected: selectedEdgeIDs.contains(edge.id),
                                onToggle: { selectedEdgeIDs.toggle(edge.id) }
                            ) {
                                edgeRowContent(edge)
                            }
                            if idx < preview.edges.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .padding(.horizontal, AppSpacing.lg)
                }

                // Template picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Template (optional)").font(.caption).foregroundStyle(.secondary)
                    Picker("Template", selection: $selectedTemplate) {
                        Text("None").tag(nil as ProjectTemplate?)
                        ForEach(ProjectTemplate.allCases, id: \.rawValue) { t in
                            Text(t.displayName).tag(t as ProjectTemplate?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, AppSpacing.lg)

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
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.sm)

                Spacer().frame(height: 24)
            }
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Selectable Row

    private func selectableRow(isSelected: Bool, onToggle: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            content()
        }
        .padding(12)
    }

    // MARK: - Row content helpers

    private func taskRowContent(_ task: ConversionPreview.ConversionTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).font(.subheadline)
            if let owner = task.ownerName {
                Text("Owner: \(owner)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if let priority = task.priority {
                Text(priority).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(priorityColor(priority).opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    private func personRowContent(_ person: ConversionPreview.ConversionPerson) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill").font(.caption).foregroundStyle(.purple)
            Text(person.displayName).font(.subheadline)
            if let role = person.role {
                Text("· \(role)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func entityRowContent(_ entity: ConversionPreview.ConversionEntity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entityKindIcon(entity.kind)).font(.caption).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.displayName).font(.subheadline)
                Text(entity.kind.capitalized).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func edgeRowContent(_ edge: ConversionPreview.ConversionEdge) -> some View {
        HStack(spacing: 8) {
            Text(edge.fromRef).font(.caption).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            Text(edge.toRef).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(edge.edgeType).font(.caption2).foregroundStyle(.blue)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.footnote).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
    }

    private func selectAll() {
        guard let preview else { return }
        let allSelected = selectedTaskIDs.count == preview.tasks.count
            && selectedPersonIDs.count == preview.people.count
            && selectedEntityIDs.count == preview.entities.count
            && selectedEdgeIDs.count == preview.edges.count
        if allSelected {
            selectedTaskIDs = []
            selectedPersonIDs = []
            selectedEntityIDs = []
            selectedEdgeIDs = []
        } else {
            selectedTaskIDs = Set(preview.tasks.map(\.id))
            selectedPersonIDs = Set(preview.people.map(\.id))
            selectedEntityIDs = Set(preview.entities.map(\.id))
            selectedEdgeIDs = Set(preview.edges.map(\.id))
        }
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
        generationStep = "Analyzing content..."
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            errorMessage = "No AI provider configured. Go to Settings to add one."
            isGenerating = false
            return
        }

        do {
            let model = selectedModel.isEmpty
                ? ActiveModelPicker.effectiveModel(context: modelContext, feature: "analysis")
                : selectedModel
            generationStep = "Extracting structure..."
            let preview = try await makeService().generatePreview(from: item, using: provider, model: model)
            self.preview = preview
            selectedTaskIDs = Set(preview.tasks.map(\.id))
            selectedPersonIDs = Set(preview.people.map(\.id))
            selectedEntityIDs = Set(preview.entities.map(\.id))
            selectedEdgeIDs = Set(preview.edges.map(\.id))
        } catch let error as ProviderError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func executeConversion(_ preview: ConversionPreview) {
        let filteredPreview = ConversionPreview(
            projectName: preview.projectName,
            tasks: preview.tasks.filter { selectedTaskIDs.contains($0.id) },
            people: preview.people.filter { selectedPersonIDs.contains($0.id) },
            entities: preview.entities.filter { selectedEntityIDs.contains($0.id) },
            edges: preview.edges.filter { selectedEdgeIDs.contains($0.id) }
        )
        do {
            let project = try makeService().executeConversion(from: item, preview: filteredPreview, template: selectedTemplate)
            processingQueue.enqueue(itemID: item.id, trigger: .newCapture)
            dismiss()
            onComplete(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Set where Element == String {
    mutating func toggle(_ element: String) {
        if contains(element) { remove(element) } else { insert(element) }
    }
}
