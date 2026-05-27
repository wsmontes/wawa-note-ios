import Foundation

struct LensConfig: Codable, Identifiable, Sendable {
    var id: String
    let name: String
    let description: String
    let icon: String?
    let systemPrompt: String?
    let userPrompt: String
    let temperature: Double?
    let model: String?

    init(
        id: String,
        name: String,
        description: String = "",
        icon: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String,
        temperature: Double? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.temperature = temperature
        self.model = model
    }
}

struct LensResult: Codable, Sendable {
    let lensId: String
    let lensName: String
    let content: String
    let parsedJSON: Data?

    init(lensId: String, lensName: String, content: String, parsed: Data? = nil) {
        self.lensId = lensId
        self.lensName = lensName
        self.content = content
        self.parsedJSON = parsed
    }
}
