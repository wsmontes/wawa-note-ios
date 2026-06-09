import Foundation
import OSLog

// MARK: - Meetily Template System

/// Loads and manages structured JSON templates inspired by Meetily's template engine.
///
/// Meetily templates are JSON documents with typed sections:
/// ```json
/// {
///   "name": "Standard Meeting Notes",
///   "sections": [
///     {"title": "Summary", "instruction": "...", "format": "paragraph"},
///     {"title": "Action Items", "instruction": "...", "format": "list",
///      "item_format": "| **Owner** | Task | ... |"}
///   ]
/// }
/// ```
///
/// Section formats:
/// - `paragraph` — prose text
/// - `list` — bullet points
/// - `string` — single value
/// - `table` — markdown table (uses `item_format`)
///
/// This maps directly to Wawa Note's FrameworkService system,
/// converting Meetily templates into ProjectFramework instances.
@MainActor
final class MeetilyTemplateService: ObservableObject {
    static let shared = MeetilyTemplateService()

    private let logger = Logger(subsystem: "com.wawa.note", category: "MeetilyTemplates")

    @Published private(set) var templates: [MeetilyTemplate] = []
    @Published private(set) var builtInTemplateIDs: Set<String> = []

    private init() {
        loadBuiltInTemplates()
    }

    // MARK: - Template Types

    struct MeetilyTemplate: Codable, Identifiable, Sendable {
        var id: String { name.lowercased().replacingOccurrences(of: " ", with: "_") }
        let name: String
        let description: String?
        let sections: [TemplateSection]
    }

    struct TemplateSection: Codable, Sendable {
        let title: String
        let instruction: String
        let format: SectionFormat
        let itemFormat: String?
        let exampleItemFormat: String?

        enum SectionFormat: String, Codable, Sendable {
            case paragraph, list, string, table
        }

        enum CodingKeys: String, CodingKey {
            case title, instruction, format
            case itemFormat = "item_format"
            case exampleItemFormat = "example_item_format"
        }
    }

    // MARK: - Load built-in templates

    private func loadBuiltInTemplates() {
        guard let templatesURL = Bundle.main.url(
            forResource: "MeetilyTemplates",
            withExtension: nil
        ) else {
            logger.warning("MeetilyTemplates directory not found in bundle")
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: templatesURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            for fileURL in files {
                if let template = self.loadTemplate(from: fileURL) {
                    self.templates.append(template)
                    builtInTemplateIDs.insert(template.id)
                    logger.info("Loaded template: \(template.name) (\(template.sections.count) sections)")
                }
            }

            logger.info("Loaded \(self.templates.count) Meetily templates")
        } catch {
            logger.error("Failed to load templates: \(error)")
        }
    }

    private func loadTemplate(from url: URL) -> MeetilyTemplate? {
        guard let data = try? Data(contentsOf: url),
              let template = try? JSONDecoder().decode(MeetilyTemplate.self, from: data) else {
            logger.warning("Failed to parse template: \(url.lastPathComponent)")
            return nil
        }
        return template
    }

    // MARK: - Query

    func template(named name: String) -> MeetilyTemplate? {
        templates.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func template(id: String) -> MeetilyTemplate? {
        templates.first { $0.id == id }
    }

    // MARK: - Custom templates (user-created)

    /// Add a custom user-created template.
    func addCustomTemplate(_ template: MeetilyTemplate) {
        templates.removeAll { $0.id == template.id }
        templates.append(template)
        saveCustomTemplates()
    }

    /// Remove a custom template (built-in templates cannot be removed).
    func removeTemplate(id: String) {
        guard !builtInTemplateIDs.contains(id) else {
            logger.warning("Cannot remove built-in template: \(id)")
            return
        }
        templates.removeAll { $0.id == id }
        saveCustomTemplates()
    }

    private let customTemplatesKey = "meetily_custom_templates"

    private func saveCustomTemplates() {
        let custom = templates.filter { !builtInTemplateIDs.contains($0.id) }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: customTemplatesKey)
    }

    private func loadCustomTemplates() {
        guard let data = UserDefaults.standard.data(forKey: customTemplatesKey),
              let custom = try? JSONDecoder().decode([MeetilyTemplate].self, from: data) else {
            return
        }
        templates.append(contentsOf: custom)
    }

    // MARK: - Build system prompt from template

    /// Generate a system prompt for LLM analysis from a template.
    /// The LLM is instructed to produce markdown following the template structure.
    func buildSystemPrompt(for template: MeetilyTemplate, language: String? = nil) -> String {
        var prompt = """
        # Role

        You are an expert meeting analyst. Generate structured meeting notes following the template below.

        # Template: \(template.name)

        """

        if let desc = template.description {
            prompt += "\(desc)\n\n"
        }

        prompt += "# Output Format\n\n"

        for (idx, section) in template.sections.enumerated() {
            prompt += "## \(section.title)\n"
            prompt += "**Instruction:** \(section.instruction)\n"

            switch section.format {
            case .paragraph:
                prompt += "**Format:** Write as a concise paragraph.\n"
            case .list:
                if let itemFmt = section.itemFormat {
                    prompt += "**Format:** Use this table structure:\n```\n\(itemFmt)\n```\n"
                } else {
                    prompt += "**Format:** Use bullet points (- item).\n"
                }
            case .string:
                prompt += "**Format:** Single value, no extra text.\n"
            case .table:
                prompt += "**Format:** Markdown table.\n"
            }

            if idx < template.sections.count - 1 {
                prompt += "\n"
            }
        }

        if let lang = language {
            prompt += "\n\n# Language\n\nWrite the summary in \(lang).\n"
        }

        prompt += "\n\n# Important\n\n"
        prompt += "- Output ONLY the formatted markdown. No preamble, no 'Here is the summary'.\n"
        prompt += "- Follow the template structure exactly.\n"
        prompt += "- Be concrete and specific. Reference what was actually said.\n"

        return prompt
    }

    /// Build a user prompt that includes the transcript and context.
    func buildUserPrompt(
        template: MeetilyTemplate,
        transcript: String,
        participants: String = "",
        preNotes: String = "",
        postNotes: String = ""
    ) -> String {
        var prompt = ""

        if !participants.isEmpty {
            prompt += "# Participants\n\(participants)\n\n"
        }

        if !preNotes.isEmpty {
            prompt += "# Pre-Meeting Notes\n\(preNotes)\n\n"
        }

        if !postNotes.isEmpty {
            prompt += "# Meeting Notes\n\(postNotes)\n\n"
        }

        prompt += "# Transcript\n\(transcript)\n\n"

        prompt += "# Template Sections to Fill\n"
        for section in template.sections {
            prompt += "- **\(section.title):** \(section.instruction)\n"
        }

        return prompt
    }

    // MARK: - Convert to ProjectFramework

    /// Convert a Meetily template to a Wawa Note ProjectFramework.
    /// This allows Meetily templates to be used as analysis schemas.
    func toProjectFramework(_ template: MeetilyTemplate) -> ProjectFramework {
        var properties: [String: SchemaProperty] = [:]
        var renderers: [FieldRenderer] = []

        // Always include short_summary
        properties["short_summary"] = SchemaProperty(
            type: "string", items: nil, properties: nil,
            description: "One-line summary"
        )
        renderers.append(FieldRenderer(
            field: "short_summary", type: .card,
            title: "Summary", icon: "text.alignleft"
        ))

        for section in template.sections {
            let key = section.title.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "&", with: "and")

            switch section.format {
            case .paragraph, .string:
                properties[key] = SchemaProperty(
                    type: "string", items: nil, properties: nil,
                    description: section.instruction
                )
                renderers.append(FieldRenderer(
                    field: key, type: .card,
                    title: section.title, icon: "text.alignleft"
                ))
            case .list, .table:
                properties[key] = SchemaProperty(
                    type: "array",
                    items: SchemaItems(type: "object", properties: [
                        "item": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
                    ]),
                    properties: nil,
                    description: section.instruction
                )
                renderers.append(FieldRenderer(
                    field: key, type: .list,
                    title: section.title, icon: "list.bullet"
                ))
            }
        }

        let schema = AnalysisOutputSchema(
            type: "object",
            properties: properties,
            required: ["short_summary"]
        )

        return ProjectFramework(
            id: "meetily/\(template.id)",
            name: template.name,
            description: template.description ?? "",
            itemAnalysis: AnalysisConfig(
                systemPrompt: buildSystemPrompt(for: template),
                outputSchema: schema,
                renderAs: renderers
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "Synthesize this project's items using the \(template.name) template.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "items", title: "Items", type: .list, source: "items"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items")
            ],
            entityKinds: ["person", "organization", "decision", "action"],
            edgeTypes: ["supports", "contradicts", "references", "relates_to"]
        )
    }
}
