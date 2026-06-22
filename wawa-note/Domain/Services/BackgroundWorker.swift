import Foundation

/// Actor for CPU-intensive work that should NOT run on @MainActor.
/// Handles JSON parsing, prompt building, text processing — anything
/// that doesn't need SwiftData ModelContext access.
actor BackgroundWorker {

    // MARK: - JSON Parsing

    /// Parses raw AI response into IngestionResponse. Tries lenient strategies.
    func parseIngestionJSON(_ raw: String) -> IngestionResponse? {
        // Try direct decode first
        if let data = raw.data(using: .utf8),
           let response = try? JSONDecoder().decode(IngestionResponse.self, from: data) {
            return response
        }

        // Try extracting JSON from markdown code blocks
        let trimmed = extractJSONBlock(from: raw)
        if let data = trimmed.data(using: .utf8),
           let response = try? JSONDecoder().decode(IngestionResponse.self, from: data) {
            return response
        }

        return nil
    }

    // MARK: - Prompt Building

    /// Builds the ingestion prompt from pre-fetched context (no ModelContext needed).
    func buildIngestionPrompt(projectContext: String, newItemContext: String, frameworkID: String?) -> String {
        """
        ## NEW ITEM TO ANALYZE

        \(newItemContext)

        ## CURRENT PROJECT STATE

        \(projectContext)

        Analyze how this new item relates to the project. Return JSON per the schema in your system prompt.
        """
    }

    /// Builds item context string from pre-extracted data.
    func buildItemContextString(title: String, type: String, bodyText: String?, transcription: String?, analysisJSON: String?) -> String {
        var ctx = "Title: \(title)\nType: \(type)\n"
        if let body = bodyText, !body.isEmpty {
            ctx += "Content:\n\(String(body.prefix(8000)))\n"
        }
        if let transcript = transcription, !transcript.isEmpty {
            ctx += "Transcription:\n\(String(transcript.prefix(8000)))\n"
        }
        if let analysis = analysisJSON, !analysis.isEmpty {
            ctx += "Previous Analysis:\n\(String(analysis.prefix(4000)))\n"
        }
        return ctx
    }

    // MARK: - Text Processing

    /// Extracts entities from text without needing ModelContext.
    func extractMentionedNames(from text: String) -> [String] {
        // Simple heuristic: capitalized multi-word sequences
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var names: [String] = []
        var current: [String] = []

        for word in words {
            let clean = word.trimmingCharacters(in: .punctuationCharacters)
            if clean.isEmpty { continue }
            let first = clean.first!
            if first.isUppercase && clean.count > 1 {
                current.append(clean)
            } else {
                if current.count >= 2 {
                    names.append(current.joined(separator: " "))
                }
                current = []
            }
        }
        if current.count >= 2 {
            names.append(current.joined(separator: " "))
        }
        return Array(Set(names))
    }

    // MARK: - Private

    private func extractJSONBlock(from text: String) -> String {
        // Try to find ```json ... ``` blocks
        if let jsonStart = text.range(of: "```json"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find { ... } at top level
        if let firstBrace = text.firstIndex(of: "{"),
           let lastBrace = text.lastIndex(of: "}") {
            return String(text[firstBrace...lastBrace])
        }
        return text
    }
}

// MARK: - AsyncSemaphore

/// Simple async semaphore for rate-limiting concurrent operations.
/// Replaces manual `activeCount` tracking with proper structured concurrency.
actor AsyncSemaphore {
    private let maxCount: Int
    private var currentCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.maxCount = count
    }

    /// Acquires a slot. Suspends if at capacity.
    func acquire() async {
        if currentCount < maxCount {
            currentCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a slot. Resumes the next waiter if any.
    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            currentCount -= 1
        }
    }

    /// Current number of active slots.
    var activeCount: Int { currentCount }
}
