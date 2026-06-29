import Foundation

final class ContextWindowManager {
    let modelContextLimit: Int
    private let charsPerToken = 4
    private let codeCharsPerToken = 3  // JSON/code: many special chars → ~3 chars/token
    private let cjkCharsPerToken = 2  // CJK: 1-2 chars/token in most tokenizers

    init(modelContextLimit: Int) {
        self.modelContextLimit = modelContextLimit
    }

    /// Improved token estimation using content heuristics.
    /// Falls back to 4 chars/token for general text, with adjustments for:
    /// - CJK text: ~2 chars/token
    /// - JSON/code with high special-char density: ~3 chars/token
    func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        // Detect content type for better ratio
        let specialCharRatio = Double(text.filter { "{}[]\":,()<>/\\|;=+-*&^%$#@!~`".contains($0) }.count) / Double(max(1, text.count))
        let hasCJK = text.unicodeScalars.contains { $0.properties.isIdeographic }

        let ratio: Int
        if hasCJK {
            ratio = cjkCharsPerToken
        } else if specialCharRatio > 0.08 {
            // High special-char density → likely JSON or code → 3 chars/token
            ratio = codeCharsPerToken
        } else {
            ratio = charsPerToken
        }

        return max(1, text.count / ratio)
    }

    func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.content) }
    }

    func estimateToolTokens(_ tools: [AIToolDefinition]) -> Int {
        var total = 0
        for tool in tools {
            if let data = try? JSONEncoder().encode(tool),
                let json = String(data: data, encoding: .utf8)
            {
                total += estimateTokens(json)
            }
        }
        return total
    }

    /// Compress message history through a 5-layer pipeline before sending to the model.
    /// Each layer is cheaper than full context and progressively reduces token usage.
    func prepareMessages(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [AIToolDefinition],
        maxTokensBudget: Int
    ) -> (messages: [ChatMessage], wasTruncated: Bool, truncatedCount: Int) {
        let overhead = estimateTokens(systemPrompt) + estimateToolTokens(tools)
        let availableForHistory = maxTokensBudget - overhead

        guard availableForHistory > 0 else {
            return ([], true, history.count)
        }

        // Layer 1: Truncate large tool outputs (keep head + tail)
        let layer1 = truncateToolOutputs(history)

        // Layer 2: Prune old messages (keep role + first 100 chars for context)
        let layer2 = pruneOldMessages(layer1)

        // Layer 3: Deduplicate identical tool results
        let layer3 = deduplicateToolResults(layer2)

        // Layer 4: Auto-summarize oldest messages if still over budget
        let layer4 = autoSummarize(layer3, availableTokens: availableForHistory)

        // Layer 5: Hard truncation from oldest (last resort)
        var accumulated = 0
        var included: [ChatMessage] = []
        for msg in layer4.reversed() {
            let tokens = estimateTokens(msg.content)
            if accumulated + tokens <= availableForHistory {
                included.insert(msg, at: 0)
                accumulated += tokens
            } else {
                break
            }
        }

        let truncated = included.count < history.count
        return (included, truncated, history.count - included.count)
    }

    // MARK: - Layer 1: Tool output truncation

    private let maxToolOutputChars = 2000

    private func truncateToolOutputs(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { msg in
            guard msg.role == .tool, msg.content.count > maxToolOutputChars else { return msg }
            let head = String(msg.content.prefix(maxToolOutputChars / 2))
            let tail = String(msg.content.suffix(maxToolOutputChars / 2))
            var truncated = msg
            truncated.content = "\(head)\n...[\(msg.content.count - maxToolOutputChars) chars truncated]...\n\(tail)"
            return truncated
        }
    }

    // MARK: - Layer 2: Message pruning

    private let pruneAfterTurns = 10
    private let prunedPreviewChars = 100

    private func pruneOldMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > pruneAfterTurns else { return messages }
        let keepRecent = messages.count - pruneAfterTurns
        return messages.enumerated().map { idx, msg in
            guard idx < keepRecent else { return msg }
            guard msg.role == .user || msg.role == .assistant else { return msg }
            var pruned = msg
            let preview = String(msg.content.prefix(prunedPreviewChars)).replacingOccurrences(of: "\n", with: " ")
            pruned.content = "[earlier] \(msg.role.apiName): \(preview)..."
            return pruned
        }
    }

    // MARK: - Layer 3: Tool result dedup

    private func deduplicateToolResults(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen: Set<String> = []
        return messages.map { msg in
            guard msg.role == .tool else { return msg }
            if seen.contains(msg.content) {
                var deduped = msg
                deduped.content = "[Same as previous]"
                return deduped
            }
            seen.insert(msg.content)
            return msg
        }
    }

    // MARK: - Layer 4: Auto-summary

    /// Trigger auto-summary when history exceeds half the model's context window.
    /// Avoids aggressive pruning on large-context models (up to 1M tokens).
    private lazy var summaryAfterTokens: Int = {
        modelContextLimit / 2
    }()

    private func autoSummarize(_ messages: [ChatMessage], availableTokens: Int) -> [ChatMessage] {
        let totalTokens = estimateTokens(messages)
        guard totalTokens > summaryAfterTokens else { return messages }

        // Take the oldest 40% of messages and collapse them into a summary
        let splitPoint = max(1, messages.count * 40 / 100)
        let oldMessages = Array(messages.prefix(splitPoint))
        let recentMessages = Array(messages.suffix(messages.count - splitPoint))

        let summaryText = oldMessages.map { msg in
            let preview = String(msg.content.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            return "[\(msg.role.apiName)]: \(preview)"
        }.joined(separator: "\n")

        let summaryMsg = ChatMessage(
            conversationId: UUID(), role: .system,
            content: "[CONVERSATION SUMMARY: \(oldMessages.count) earlier messages compressed]\n\(summaryText)"
        )

        return [summaryMsg] + recentMessages
    }
}
