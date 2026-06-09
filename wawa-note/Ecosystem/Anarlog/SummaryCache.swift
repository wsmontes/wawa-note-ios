import Foundation
import OSLog
import CryptoKit

// MARK: - Summary Cache

/// Fingerprint-based caching for LLM summaries.
///
/// Ported from Meetily's `service.rs` caching system.
///
/// Avoids re-generating summaries when the transcript, template,
/// and model configuration haven't changed. Uses FNV-1a hash
/// for fast fingerprint computation (same algorithm as Meetily).
///
/// Cache entries are keyed by a content fingerprint that includes:
/// - Transcript content hash
/// - Template ID
/// - Model provider + name
/// - Prompt text
/// - Language settings
@MainActor
final class SummaryCache: ObservableObject {
    static let shared = SummaryCache()

    private let logger = Logger(subsystem: "com.wawa.note", category: "SummaryCache")
    private let defaults = UserDefaults.standard
    private let cacheKey = "meetily_summary_cache"

    @Published private(set) var cacheEntries: [String: CacheEntry] = [:]
    @Published private(set) var hitCount = 0
    @Published private(set) var missCount = 0

    private init() {
        loadFromDisk()
    }

    // MARK: - Types

    struct CacheEntry: Codable, Sendable {
        let markdown: String
        let source: CacheSource
        let outputLanguage: String?
        let createdAt: Date

        var age: TimeInterval { Date().timeIntervalSince(createdAt) }
    }

    struct CacheSource: Codable, Sendable {
        let transcriptFingerprint: String
        let templateID: String
        let promptFingerprint: String
        let modelProvider: String
        let modelName: String
        let tokenThreshold: Int
        var ollamaEndpoint: String?
        var customEndpoint: String?
        var maxTokens: Int?
        var temperature: Float?
        var topP: Float?
    }

    // MARK: - Fingerprint computation

    /// FNV-1a 64-bit hash — fast, non-cryptographic fingerprint.
    /// Same algorithm as Meetily's `stable_text_fingerprint`.
    static func fingerprint(_ text: String) -> String {
        let fnvOffset: UInt64 = 0xcbf29ce484222325
        let fnvPrime: UInt64 = 0x100000001b3

        var hash: UInt64 = fnvOffset
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return String(format: "%016x:%d", hash, text.count)
    }

    /// Compute a combined cache key from all relevant inputs.
    static func cacheKey(
        transcript: String,
        templateID: String,
        systemPrompt: String,
        modelProvider: String,
        modelName: String
    ) -> String {
        let combined = "\(fingerprint(transcript)):\(templateID):\(fingerprint(systemPrompt)):\(modelProvider):\(modelName)"
        return fingerprint(combined)
    }

    // MARK: - Cache operations

    /// Check if a cached summary exists for the given parameters.
    func get(
        transcript: String,
        templateID: String,
        systemPrompt: String,
        modelProvider: String,
        modelName: String
    ) -> CacheEntry? {
        let key = Self.cacheKey(
            transcript: transcript,
            templateID: templateID,
            systemPrompt: systemPrompt,
            modelProvider: modelProvider,
            modelName: modelName
        )

        guard let entry = cacheEntries[key] else {
            missCount += 1
            return nil
        }

        // Verify fingerprint matches (defense against hash collisions)
        let currentFingerprint = Self.fingerprint(transcript)
        guard entry.source.transcriptFingerprint == currentFingerprint else {
            logger.info("Cache miss: transcript changed")
            cacheEntries.removeValue(forKey: key)
            missCount += 1
            return nil
        }

        hitCount += 1
        logger.info("Cache hit! (hits: \(self.hitCount), misses: \(self.missCount))")
        return entry
    }

    /// Store a summary in the cache.
    func set(
        markdown: String,
        transcript: String,
        templateID: String,
        systemPrompt: String,
        modelProvider: String,
        modelName: String,
        outputLanguage: String? = nil,
        tokenThreshold: Int = 0,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        topP: Float? = nil
    ) {
        let key = Self.cacheKey(
            transcript: transcript,
            templateID: templateID,
            systemPrompt: systemPrompt,
            modelProvider: modelProvider,
            modelName: modelName
        )

        let entry = CacheEntry(
            markdown: markdown,
            source: CacheSource(
                transcriptFingerprint: Self.fingerprint(transcript),
                templateID: templateID,
                promptFingerprint: Self.fingerprint(systemPrompt),
                modelProvider: modelProvider,
                modelName: modelName,
                tokenThreshold: tokenThreshold,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP
            ),
            outputLanguage: outputLanguage,
            createdAt: Date()
        )

        cacheEntries[key] = entry
        saveToDisk()
        logger.debug("Cached summary for template '\(templateID)'")
    }

    /// Invalidate all cached entries (e.g., after model or template changes).
    func invalidateAll() {
        cacheEntries.removeAll()
        saveToDisk()
        hitCount = 0
        missCount = 0
        logger.info("Cache invalidated")
    }

    /// Invalidate entries for a specific template.
    func invalidate(templateID: String) {
        let before = cacheEntries.count
        cacheEntries = cacheEntries.filter { $0.value.source.templateID != templateID }
        let removed = before - cacheEntries.count
        saveToDisk()
        logger.info("Invalidated \(removed) cache entries for template '\(templateID)'")
    }

    /// Remove entries older than the specified age.
    func prune(olderThan age: TimeInterval) {
        let before = cacheEntries.count
        cacheEntries = cacheEntries.filter { $0.value.age < age }
        let removed = before - cacheEntries.count
        saveToDisk()
        if removed > 0 {
            logger.info("Pruned \(removed) stale cache entries (older than \(Int(age / 86400))d)")
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = defaults.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        cacheEntries = entries
        logger.debug("Loaded \(entries.count) cached summaries")
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cacheEntries) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    // MARK: - Stats

    var stats: CacheStats {
        CacheStats(
            entries: cacheEntries.count,
            hits: hitCount,
            misses: missCount,
            hitRate: hitCount + missCount > 0
                ? Double(hitCount) / Double(hitCount + missCount)
                : 0
        )
    }

    struct CacheStats {
        let entries: Int
        let hits: Int
        let misses: Int
        let hitRate: Double
    }
}

// MARK: - Language Normalization

/// Two-pass language normalization inspired by Meetily's `processor.rs`.
///
/// Flow:
/// 1. Generate summary in the target language (pass 1)
/// 2. If target is not English AND transcript is not English:
///    translation pass converts to target language (pass 2)
/// 3. Strip `<thinking>` tags from reasoning model outputs
enum LanguageNormalizer {
    private static let thinkingTagRegex = try! NSRegularExpression(
        pattern: "<think(?:ing)?>.*?</think(?:ing)?>",
        options: [.dotMatchesLineSeparators]
    )

    /// System prompt for English normalization pass.
    static let englishNormalizationPrompt = """
    You are a precise English Markdown editor. Convert the provided Markdown document into English while preserving structure exactly.

    **CRITICAL RULES:**
    1. Translate any non-English prose into English.
    2. Preserve the Markdown structure EXACTLY: keep every `#`, `**`, `-`, `|`, code fence marker, and table pipe in the same position.
    3. Do NOT translate: proper nouns (names of people, products, companies), code identifiers, file paths, URLs, numeric values, or text inside backticks.
    4. If the document is already English, lightly preserve it without rewriting meaning.
    5. Do not add commentary or explanation. Output ONLY the English Markdown.
    """

    /// Detect if text is primarily English (simple heuristic).
    static func isEnglish(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let englishWords = ["the", "and", "that", "this", "with", "for", "was", "are", "have", "from"]
        let nonEnglishMarkers = [
            // Portuguese/Spanish
            "que", "para", "uma", "com", "não", "como", "mais", "dos", "das",
            "los", "las", "por", "del", "una", "ente", "ción", "idad",
            // French
            "dans", "avec", "une", "pour", "sur", "sont", "aux",
            // German
            "und", "der", "die", "das", "mit", "auf", "für", "ist", "von", "zu",
            // Italian
            "che", "sono", "una", "per", "con", "del", "gli",
            // Dutch
            "een", "het", "zijn", "voor", "niet", "worden",
            // Japanese/Korean/Chinese markers
            "です", "ます", "した", "いる", "ある",
            "습니다", "입니다", "하는", "그리고",
            "的", "是", "了", "在", "有"
        ]

        var englishCount = 0
        var nonEnglishCount = 0

        let words = lowercased.components(separatedBy: .whitespacesAndNewlines)
        for word in words where word.count > 2 {
            if englishWords.contains(word) { englishCount += 1 }
            if nonEnglishMarkers.contains(word) { nonEnglishCount += 1 }
        }

        // English if we see English words and no non-English markers
        return englishCount > nonEnglishCount || (englishCount > 0 && nonEnglishCount == 0)
    }

    /// Map BCP-47 language code to English name for LLM prompts.
    static func languageName(from code: String) -> String? {
        let normalised = code.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = normalised.components(separatedBy: "-").first ?? normalised

        return switch base {
        case "en": "English"
        case "pt": "Portuguese"
        case "es": "Spanish"
        case "fr": "French"
        case "de": "German"
        case "it": "Italian"
        case "ja": "Japanese"
        case "ko": "Korean"
        case "zh": "Chinese"
        case "ru": "Russian"
        case "ar": "Arabic"
        case "hi": "Hindi"
        case "nl": "Dutch"
        case "sv": "Swedish"
        case "no": "Norwegian"
        case "da": "Danish"
        case "fi": "Finnish"
        case "pl": "Polish"
        case "tr": "Turkish"
        case "th": "Thai"
        case "vi": "Vietnamese"
        case "id": "Indonesian"
        default: nil
        }
    }

    /// Strip `<thinking>` tags from reasoning model outputs (Claude, DeepSeek, etc.).
    static func stripThinkingTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return thinkingTagRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve the final language action based on desired language and detected content language.
    enum LanguageAction {
        case keepAsIs          // Already in target language
        case normalizeToEnglish // Translate to English
        case translate(to: String)  // Translate to specific language
    }

    static func resolveLanguageAction(
        targetLanguage: String?,
        detectedContentLanguage: String?
    ) -> LanguageAction {
        guard let target = targetLanguage?.lowercased(),
              target != "en", target != "eng",
              let targetName = languageName(from: target),
              targetName != "English" else {
            // Target is English or not specified — check if content needs normalization
            if let detected = detectedContentLanguage,
               let detectedName = languageName(from: detected),
               detectedName != "English" {
                return .normalizeToEnglish
            }
            return .keepAsIs
        }
        return .translate(to: targetName)
    }
}
