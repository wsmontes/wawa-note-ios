import Foundation
import OSLog

final class TemplateService: @unchecked Sendable {
    private var templates: [String: AITemplate] = [:]

    init() {
        loadBuiltInTemplates()
    }

    // MARK: - Load

    private func loadBuiltInTemplates() {
        let ids = ["ask", "analyze", "compare", "expand", "organize"]
        for id in ids {
            guard let url = Bundle.main.url(forResource: id, withExtension: "md", subdirectory: "templates"),
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  let tmpl = TemplateParser.parse(content, id: id) else {
                AppLog.general.warning("Failed to load template: \(id)")
                continue
            }
            self.templates[id] = tmpl
        }
        let count = self.templates.keys.count
        AppLog.general.info("Loaded \(count) AI templates")
    }

    // MARK: - Query

    func all() -> [AITemplate] {
        Array(self.templates.values)
    }

    func template(by id: String) -> AITemplate? {
        self.templates[id]
    }

    func templates(for activation: TemplateActivation) -> [AITemplate] {
        self.templates.values.filter { $0.activation == activation }
    }

    func templatesForItem(_ item: KnowledgeItem) -> [AITemplate] {
        self.templates.values.filter { template in
            guard template.activation == .auto || template.activation == .glob else { return false }
            guard let globs = template.globs else { return template.activation == .auto }
            let typePath = "**/\(item.type.rawValue)/*"
            return globs.contains { glob in
                typePath.contains(glob.replacingOccurrences(of: "**/", with: "").replacingOccurrences(of: "/*", with: ""))
            }
        }
    }

    // MARK: - Execute

    func execute(
        templateID: String,
        variables: [String: String],
        provider: any AIProvider,
        model: String
    ) async throws -> NormalizedResponse {
        guard let template = self.templates[templateID] else {
            throw ProviderError.providerNotFound
        }

        let hint = ProviderAdapter.hint(for: provider)
        let request = ProviderAdapter.buildRequest(template: template, variables: variables, provider: provider)

        let response = try await provider.send(AIRequest(
            model: request.model,
            messages: [
                AIMessage(role: .system, content: [.text(request.systemPrompt)]),
                AIMessage(role: .user, content: [.text(request.userPrompt)])
            ],
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            responseFormat: hint.supportsJSONSchema ? .json : nil
        ))

        return ProviderAdapter.normalizeResponse(response.content, tactic: hint.tactic)
    }
}
