import Foundation

enum TemplateActivation: String, Codable, Sendable {
  case manual  // User explicitly invokes
  case auto  // Always active for matching items
  case glob  // Active when item path matches globs
  case scheduled  // Runs on schedule
}

enum TemplateRenderer: String, Codable, Sendable {
  case richText = "rich_text"
  case cards = "cards"
  case sideBySide = "side_by_side"
  case diffInline = "diff_inline"
  case actionList = "action_list"
}

struct AITemplate: Codable, Identifiable, Sendable {
  let id: String
  let name: String
  let description: String
  let icon: String
  let activation: TemplateActivation
  let globs: [String]?
  let renderer: TemplateRenderer
  let model: String?
  let temperature: Double?
  let maxTokens: Int?
  let systemPrompt: String
  let userPrompt: String
  let responseSchema: String?

  var displayName: String { name }
}

// MARK: - Parser

enum TemplateParser {
  static func parse(_ markdown: String, id: String) -> AITemplate? {
    guard markdown.hasPrefix("---") else { return nil }

    let rest = markdown.dropFirst(3)
    guard let endRange = rest.range(of: "\n---\n") else { return nil }

    let frontmatter = String(rest[..<endRange.lowerBound])
    let body = String(rest[endRange.upperBound...])

    var name = id
    var description = ""
    var icon = "sparkles"
    var activation = TemplateActivation.manual
    var globs: [String]?
    var renderer = TemplateRenderer.richText
    var model: String?
    var temperature: Double?
    var maxTokens: Int?

    // Parse YAML frontmatter
    for line in frontmatter.split(separator: "\n") {
      let trimmed = String(line).trimmingCharacters(in: .whitespaces)
      guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
      let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
      let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(
        in: .whitespaces)

      switch key {
      case "name": name = value.replacingOccurrences(of: "\"", with: "")
      case "description": description = value.replacingOccurrences(of: "\"", with: "")
      case "icon": icon = value.replacingOccurrences(of: "\"", with: "")
      case "activation":
        activation =
          TemplateActivation(rawValue: value.replacingOccurrences(of: "\"", with: "")) ?? .manual
      case "globs":
        let cleaned = value.replacingOccurrences(of: "[", with: "").replacingOccurrences(
          of: "]", with: "")
        globs = cleaned.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        }
      case "renderer":
        renderer =
          TemplateRenderer(rawValue: value.replacingOccurrences(of: "\"", with: "")) ?? .richText
      case "model": model = value.replacingOccurrences(of: "\"", with: "")
      case "temperature": temperature = Double(value)
      case "max_tokens": maxTokens = Int(value)
      default: break
      }
    }

    // Parse body sections: # System, # User Prompt, # Response Schema
    var systemPrompt = "You are a helpful AI assistant."
    var userPrompt = "Analyze: {content}"
    var responseSchema: String?

    let sections = body.components(separatedBy: "\n# ")
    for section in sections {
      let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("System") {
        systemPrompt = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
      } else if trimmed.hasPrefix("User Prompt") {
        userPrompt = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
      } else if trimmed.hasPrefix("Response Schema") {
        responseSchema = String(trimmed.dropFirst(15)).trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }

    return AITemplate(
      id: id,
      name: name,
      description: description,
      icon: icon,
      activation: activation,
      globs: globs,
      renderer: renderer,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      responseSchema: responseSchema
    )
  }
}
