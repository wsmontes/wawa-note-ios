import Foundation

final class ContextWindowManager {
    let modelContextLimit: Int
    private let charsPerToken = 4

    init(modelContextLimit: Int) {
        self.modelContextLimit = modelContextLimit
    }

    func estimateTokens(_ text: String) -> Int {
        max(1, text.count / charsPerToken)
    }

    func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.content) }
    }

    func estimateToolTokens(_ tools: [AIToolDefinition]) -> Int {
        let jsonEncoder = JSONEncoder()
        var total = 0
        for tool in tools {
            if let data = try? jsonEncoder.encode(tool) {
                total += estimateTokens(String(data: data, encoding: .utf8) ?? "")
            }
        }
        return total
    }

    /// Trim message history to fit within the model's context window.
    /// Always preserves: system prompt, tool definitions, and the most recent messages.
    /// Returns the trimmed messages and a flag indicating if truncation occurred.
    func prepareMessages(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [AIToolDefinition],
        maxTokensBudget: Int
    ) -> (messages: [ChatMessage], wasTruncated: Bool, truncatedCount: Int) {
        let overhead = estimateTokens(systemPrompt) + estimateToolTokens(tools)
        let availableForHistory = maxTokensBudget - overhead

        if availableForHistory <= 0 {
            return ([], true, history.count)
        }

        // Always keep messages from most recent to oldest
        var accumulated = 0
        var included: [ChatMessage] = []

        for msg in history.reversed() {
            let msgTokens = estimateTokens(msg.content)
            if accumulated + msgTokens <= availableForHistory {
                included.insert(msg, at: 0)
                accumulated += msgTokens
            } else {
                break
            }
        }

        let truncated = included.count < history.count
        return (included, truncated, history.count - included.count)
    }
}
