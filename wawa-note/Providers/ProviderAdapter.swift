import Foundation

// MARK: - Response adapter

enum ProviderTactic {
    case nativeJSON       // Provider supports json_schema natively (OpenAI)
    case promptedJSON     // Provider needs prompt engineering for JSON (Anthropic, DeepSeek)
    case bestEffort       // Parse what we can, fall back to raw text
}

struct ProviderHint {
    let tactic: ProviderTactic
    let supportsJSONSchema: Bool
    let supportsSystemPrompt: Bool
}

struct NormalizedRequest {
    let systemPrompt: String
    let userPrompt: String
    let schema: String?
    let temperature: Double?
    let maxTokens: Int?
    let model: String
}

struct NormalizedResponse {
    let text: String
    let parsedJSON: [String: Any]?
}

// MARK: - Adapter

final class ProviderAdapter: @unchecked Sendable {

    static func hint(for provider: any AIProvider) -> ProviderHint {
        let id = provider.id.lowercased()
        if id.contains("openai") || id == "openai" {
            return ProviderHint(tactic: .nativeJSON, supportsJSONSchema: true, supportsSystemPrompt: true)
        }
        if id.contains("anthropic") || id == "anthropic" {
            return ProviderHint(tactic: .promptedJSON, supportsJSONSchema: false, supportsSystemPrompt: true)
        }
        return ProviderHint(tactic: .bestEffort, supportsJSONSchema: false, supportsSystemPrompt: true)
    }

    static func buildRequest(template: AITemplate, variables: [String: String], provider: any AIProvider) -> NormalizedRequest {
        let hint = Self.hint(for: provider)
        let id = provider.id.lowercased()

        var system = template.systemPrompt
        var user = template.userPrompt
        var schema = template.responseSchema

        for (key, value) in variables {
            user = user.replacingOccurrences(of: "{\(key)}", with: value)
            system = system.replacingOccurrences(of: "{\(key)}", with: value)
        }

        // OpenAI: prepend schema requirement to system prompt
        if hint.tactic == .nativeJSON, let s = schema {
            system = "\(system)\n\nYou MUST return ONLY valid JSON matching this schema. No markdown, no code fences, no explanatory text:\n\(s)"
        }

        // Anthropic/Generic: prompt engineering — inject format instructions into user prompt
        if hint.tactic == .promptedJSON || hint.tactic == .bestEffort {
            if let s = schema {
                user = "\(user)\n\nIMPORTANT: Return ONLY a single JSON object. No markdown wrapping, no code fences, no explanatory text before or after the JSON. The JSON must have this structure:\n\(s)"
            } else {
                user = "\(user)\n\nReturn your response as a single JSON object."
            }
        }

        // Multi-model routing based on provider
        var model = template.model ?? (id.contains("anthropic") ? "claude-sonnet-4-6" : "gpt-5.5")
        if id.contains("deepseek") { model = "deepseek-v4-pro" }
        if id.contains("gemini") { model = "gemini-2.0-flash" }

        return NormalizedRequest(
            systemPrompt: system,
            userPrompt: user,
            schema: hint.tactic == .nativeJSON ? schema : nil,
            temperature: template.temperature,
            maxTokens: template.maxTokens,
            model: model
        )
    }

    static func normalizeResponse(_ text: String, tactic: ProviderTactic) -> NormalizedResponse {
        let cleaned = stripMarkdownFences(text)

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return NormalizedResponse(text: cleaned, parsedJSON: json)
        }

        // Try extracting JSON from within text (common with promptedJSON tactic)
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}") {
            let extracted = String(cleaned[firstBrace...lastBrace])
            if let data = extracted.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return NormalizedResponse(text: extracted, parsedJSON: json)
            }
        }

        // Fallback: raw text
        return NormalizedResponse(text: cleaned, parsedJSON: ["raw_text": cleaned])
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
