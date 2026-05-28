import SwiftUI
import SwiftData

struct KnowledgeQueryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var allItems: [KnowledgeItem]
    @State private var question = ""
    @State private var result: CrossReferenceResult?
    @State private var isQuerying = false
    @State private var error: String?
    @State private var selectedTemplateID = "ask"
    @State private var selectedModel: String = ""
    @State private var relevantItemIDs: [UUID] = []
    @State private var relevantScores: [UUID: Float] = [:]

    private let templateService = TemplateService()
    private let crossRefService = CrossReferenceService()
    private let semanticSearch = SemanticSearchService()
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if allItems.isEmpty {
                        emptyState
                    } else {
                        queryInput
                        if !isQuerying && result == nil && error == nil {
                            placeholderPrompt
                        }
                        if let error { errorCard }
                        if let result { resultCards(result) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ask")
            .onTapGesture {
                if isFocused { isFocused = false }
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 80)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Nothing to ask yet").font(.title3).fontWeight(.medium)
            Text("Record meetings, write notes, or import files to build your knowledge base first.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    // MARK: - Input

    private var queryInput: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Ask anything across your knowledge...", text: $question, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if isQuerying {
                    Button { cancelQuery() } label: {
                        Image(systemName: "stop.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.red)
                    }
                } else {
                    Button {
                        isFocused = false
                        performQuery()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title).symbolRenderingMode(.hierarchical)
                    }
                    .disabled(question.isEmpty)
                }
            }
            .padding(.horizontal, 16)

            // Template selector
            let allTemplates = templateService.all()
            if !allTemplates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allTemplates, id: \.id) { tmpl in
                            Button {
                                selectedTemplateID = tmpl.id
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: tmpl.icon).font(.caption2)
                                    Text(tmpl.name).font(.caption2)
                                }
                                .foregroundStyle(selectedTemplateID == tmpl.id ? .white : .blue)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(
                                    selectedTemplateID == tmpl.id
                                    ? Color.blue
                                    : Color.blue.opacity(0.1)
                                )
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            ActiveModelPicker(selectedModel: $selectedModel, label: "Model")
                .padding(.horizontal, 16)

            HStack {
                if isQuerying && !relevantItemIDs.isEmpty {
                    Text("Searching across \(relevantItemIDs.count) relevant items...")
                        .font(.caption).foregroundStyle(.blue)
                } else {
                    Text("\(allItems.count) items searchable").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    // MARK: - Placeholder

    private var placeholderPrompt: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.quaternary)
            Text("Ask a question about your knowledge")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Try: \"What decisions were made about the product launch?\" or \"Summarize the risks mentioned this week.\"")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }

    // MARK: - Error

    private var errorCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error ?? "Something went wrong").font(.subheadline)
            Spacer()
            Button("Retry") { performQuery() }.font(.subheadline).buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Results

    @ViewBuilder
    private func resultCards(_ r: CrossReferenceResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Answer
            if !r.answer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.blue); Text("Answer").font(.headline) }
                    Text(r.answer).font(.body)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
            }

            // Connections
            if !r.connections.isEmpty {
                sectionLabel("Connections", icon: "link")
                VStack(spacing: 0) {
                    ForEach(Array(r.connections.enumerated()), id: \.element.id) { idx, conn in
                        connectionCard(conn)
                        if idx < r.connections.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
            }

            // Insights
            if !r.insights.isEmpty {
                sectionLabel("Insights", icon: "lightbulb")
                VStack(spacing: 0) {
                    ForEach(Array(r.insights.enumerated()), id: \.element.id) { idx, ins in
                        insightCard(ins)
                        if idx < r.insights.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
            }

            // Contradictions
            if !r.contradictions.isEmpty {
                sectionLabel("Contradictions", icon: "exclamationmark.triangle")
                VStack(spacing: 0) {
                    ForEach(Array(r.contradictions.enumerated()), id: \.element.id) { idx, c in
                        contradictionCard(c)
                        if idx < r.contradictions.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
            }

            Spacer().frame(height: 32)
        }
        .padding(.top, 16)
    }

    // MARK: - Result cards

    private func connectionCard(_ conn: CrossReferenceResult.Connection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Color.blue.opacity(conn.strength)).frame(width: 8, height: 8)
                Text(conn.relationship).font(.subheadline).fontWeight(.medium)
                Spacer()
                Text("\(Int(conn.strength * 100))%").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.secondarySystemGroupedBackground)).clipShape(Capsule())
            }
            Text(conn.explanation).font(.caption).foregroundStyle(.secondary)

            if let fromItem = findItem(conn.fromItemId) {
                NavigationLink { KnowledgeDetailView(item: fromItem) } label: {
                    Label(fromItem.title, systemImage: fromItem.type.icon).font(.caption)
                }
            }
            if let toItem = findItem(conn.toItemId) {
                NavigationLink { KnowledgeDetailView(item: toItem) } label: {
                    Label(toItem.title, systemImage: toItem.type.icon).font(.caption)
                }
            }
        }
        .padding(12)
    }

    private func insightCard(_ ins: CrossReferenceResult.Insight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.caption)
                Text(ins.text).font(.subheadline)
            }
            HStack(spacing: 10) {
                Text("\(ins.sourceItemIds.count) sources").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(ins.confidence * 100))%").font(.caption).foregroundStyle(.secondary)
            }

            if !ins.sourceItemIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ins.sourceItemIds, id: \.self) { itemId in
                            if let item = findItem(itemId) {
                                NavigationLink { KnowledgeDetailView(item: item) } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: item.type.icon).font(.caption2)
                                        Text(item.title).font(.caption2).lineLimit(1)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func contradictionCard(_ c: CrossReferenceResult.Contradiction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text(c.description).font(.subheadline)
            }
            if let res = c.resolution {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text(res).font(.caption)
                }
            }
            HStack(spacing: 8) {
                if let itemA = findItem(c.itemAId) {
                    NavigationLink { KnowledgeDetailView(item: itemA) } label: {
                        Label(itemA.title, systemImage: itemA.type.icon).font(.caption)
                    }
                }
                if let itemB = findItem(c.itemBId) {
                    NavigationLink { KnowledgeDetailView(item: itemB) } label: {
                        Label(itemB.title, systemImage: itemB.type.icon).font(.caption)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.headline)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func findItem(_ id: UUID) -> KnowledgeItem? {
        allItems.first { $0.id == id }
    }

    private func cancelQuery() {
        isQuerying = false
    }

    // MARK: - Query

    private func performQuery() {
        guard !question.isEmpty else { return }
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            error = "No AI provider configured. Go to Settings."
            return
        }

        isQuerying = true
        error = nil
        result = nil
        relevantScores = [:]

        let q = question
        let templateID = selectedTemplateID
        let itemIDs = allItems.map(\.id)

        Task { @MainActor in
            do {
                let finalResult: CrossReferenceResult

                if itemIDs.isEmpty {
                    finalResult = CrossReferenceResult(
                        answer: "No knowledge items to search. Record a meeting or create a note first.",
                        connections: [], insights: [], contradictions: []
                    )
                } else if templateID == "ask" {
                    finalResult = try await performAskQuery(q: q, itemIDs: itemIDs, provider: provider, model: selectedModel.isEmpty ? config.defaultModel : selectedModel)
                } else {
                    finalResult = try await performTemplateQuery(
                        templateID: templateID, question: q, itemIDs: itemIDs,
                        provider: provider, model: selectedModel.isEmpty ? config.defaultModel : selectedModel
                    )
                }

                self.result = finalResult
            } catch let error as ProviderError {
                self.error = error.userMessage
            } catch {
                self.error = error.localizedDescription
            }
            self.isQuerying = false
        }
    }

    // MARK: - Ask path (semantic search + AI cross-reference)

    private func performAskQuery(q: String, itemIDs: [UUID], provider: any AIProvider, model: String) async throws -> CrossReferenceResult {
        let searchIDs: [UUID]

        // Try semantic search first; fall back to recent items if embeddings fail
        if let relevant = try? await semanticSearch.findRelevant(
            query: q,
            itemIDs: itemIDs,
            limit: 8,
            using: provider
        ), !relevant.isEmpty {
            searchIDs = relevant.map(\.itemId)
            await MainActor.run {
                relevantItemIDs = searchIDs
                relevantScores = Dictionary(uniqueKeysWithValues: relevant.map { ($0.itemId, $0.score) })
            }
        } else {
            searchIDs = Array(itemIDs.prefix(5))
            await MainActor.run { relevantItemIDs = searchIDs }
        }

        return try await crossRefService.query(q, across: searchIDs, using: provider, model: model)
    }

    // MARK: - Template path (organize, compare, expand, analyze)

    private func performTemplateQuery(
        templateID: String, question: String, itemIDs: [UUID],
        provider: any AIProvider, model: String
    ) async throws -> CrossReferenceResult {
        let ctx = buildContext(for: templateID, itemIDs: itemIDs)
        let response = try await templateService.execute(
            templateID: templateID,
            variables: ["question": question, "content": ctx, "context": ctx],
            provider: provider,
            model: model
        )
        return parseTemplateResponse(response, templateID: templateID)
    }

    private func buildContext(for templateID: String, itemIDs: [UUID]) -> String {
        switch templateID {
        case "organize":
            return allItems.prefix(20).map { "[\($0.id.uuidString.prefix(8))] \($0.type.icon) \($0.title)" }.joined(separator: "\n")
        case "compare":
            return allItems.prefix(5).map { "[\($0.id.uuidString.prefix(8))] \($0.title)\n\($0.bodyText ?? "")\n" }.joined(separator: "\n---\n")
        default:
            return allItems.prefix(10).map { "[\($0.id.uuidString.prefix(8))] \($0.title) (\($0.type.label))\n" }.joined()
        }
    }

    private func parseTemplateResponse(_ response: NormalizedResponse, templateID: String) -> CrossReferenceResult {
        guard let json = response.parsedJSON else {
            return CrossReferenceResult(answer: response.text, connections: [], insights: [], contradictions: [])
        }

        let answer = (json["answer"] as? String)
            ?? (json["overview"] as? String)
            ?? (json["one_liner"] as? String)
            ?? response.text

        var insights: [CrossReferenceResult.Insight] = []
        var connections: [CrossReferenceResult.Connection] = []
        var contradictions: [CrossReferenceResult.Contradiction] = []

        if let items = json["insights"] as? [[String: Any]] {
            for item in items {
                let srcIds = (item["source_item_ids"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []
                insights.append(CrossReferenceResult.Insight(
                    text: (item["text"] as? String) ?? (item["insight"] as? String) ?? "",
                    sourceItemIds: srcIds,
                    confidence: (item["confidence"] as? Double) ?? 0.5
                ))
            }
        }

        if let items = json["connections"] as? [[String: Any]] {
            for item in items {
                connections.append(CrossReferenceResult.Connection(
                    fromItemId: UUID(uuidString: (item["from_item_id"] as? String) ?? "") ?? UUID(),
                    toItemId: UUID(uuidString: (item["to_item_id"] as? String) ?? "") ?? UUID(),
                    relationship: (item["relationship"] as? String) ?? "related to",
                    explanation: (item["explanation"] as? String) ?? "",
                    strength: (item["strength"] as? Double) ?? 0.5
                ))
            }
        }

        if let items = json["contradictions"] as? [[String: Any]] {
            for item in items {
                contradictions.append(CrossReferenceResult.Contradiction(
                    description: (item["description"] as? String) ?? "",
                    itemAId: UUID(uuidString: (item["item_a_id"] as? String) ?? "") ?? UUID(),
                    itemBId: UUID(uuidString: (item["item_b_id"] as? String) ?? "") ?? UUID(),
                    resolution: item["resolution"] as? String
                ))
            }
        }

        return CrossReferenceResult(answer: answer, connections: connections, insights: insights, contradictions: contradictions)
    }
}
