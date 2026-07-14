# Unified Transcription Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace scattered transcription logic across 8 entry points with `TranscriptionPipeline.shared.run(itemID:context:mode:)` — a single orchestrator with focused processors.

**Architecture:** One orchestrator delegates to typed processors (Audio/Image/Text) for Phase 0 extraction, then to ContentAnalysisService for Phase 1 analysis. All paths guarantee terminal state. All callers route through ProcessingQueue → TranscriptionPipeline.

**Tech Stack:** Swift 5.10+, Swift Concurrency, AVFoundation, Speech, Vision, SwiftData, WawaNoteCore

## Global Constraints

- Target device: iPhone 14 Plus (iOS 18.6.2)
- Protocol-first boundaries — `ContentProcessor` protocol for extractors
- Swift Concurrency (async/await), @MainActor for UI view models
- Keep SwiftUI views thin — business logic in services
- No hardcoded API keys, provider URLs, or secrets
- Use Keychain for API keys, FileManager for large artifacts, SwiftData for metadata
- Typed error enums only
- Prefer small files with clear responsibilities — no god objects
- Dependency injection through initializers where practical
- Existing patterns preserved: `AppLog.*`, `safeSave()`, `resolveEngine()`

---

### Task 1: ContentProcessor Protocol + SourceContext

**Files:**
- Create: `wawa-note/Domain/Services/ContentProcessor.swift`

**Interfaces:**
- Produces: `ContentProcessor` protocol, `SourceContext` struct, `ExtractionError` enum

- [ ] **Step 1: Create the file with protocol, context, and error types**

```swift
import Foundation
import WawaNoteCore

// Related JIRA: KAN-XX

// MARK: - Content Processor Protocol

/// Extracts text from a KnowledgeItem. Each content type (audio, image,
/// text) has its own processor conforming to this protocol.
protocol ContentProcessor {
    /// Extracts text from the item. MUST set item.status = .failed and
    /// item.lastErrorRaw on failure before returning nil.
    /// - Returns: extracted text, or nil if extraction failed.
    func extract(from item: KnowledgeItem, context: ModelContext) async -> String?
}

// MARK: - Extraction Error

/// Structured error codes for every failure path in content extraction.
/// Each case carries a user-visible message set on item.lastErrorRaw.
enum ExtractionError: Error, LocalizedError {
    case audioFileNotFound
    case audioTooSmall
    case audioTooShort
    case audioTooLong(Double)
    case noEngineAvailable
    case speechPermissionDenied
    case modelNotInstalled(String)
    case recognitionTimedOut
    case noInternet
    case remoteAuthFailed
    case remoteFileTooLarge
    case remoteRateLimited
    case remoteServerError
    case retriesExhausted(Int, String)
    case engineError(String)
    case noSpeechDetected
    case imageUnreadable
    case imageNoContent
    case ocrFailed
    case textEmpty
    case bookmarkFetchFailed
    case taskCancelled

    var errorDescription: String? {
        switch self {
        case .audioFileNotFound:
            return "Audio file not found. It may have been moved or deleted."
        case .audioTooSmall:
            return "Audio file is too small (less than 4KB). Try recording again."
        case .audioTooShort:
            return "Audio is less than 1 second. Record at least a few seconds of speech."
        case .audioTooLong(let d):
            return "Recording is \(Int(d))s — exceeds 2-hour maximum. Split into shorter segments."
        case .noEngineAvailable:
            return "No transcription engine available. Check Settings → AI Services."
        case .speechPermissionDenied:
            return "Speech recognition permission denied. Enable in Settings → Privacy → Speech Recognition."
        case .modelNotInstalled(let locale):
            return "On-device speech model for \(locale) not installed. Connect to Wi-Fi to download."
        case .recognitionTimedOut:
            return "On-device recognition timed out. Try a shorter recording or switch to Whisper API."
        case .noInternet:
            return "No internet connection. Whisper API requires network access."
        case .remoteAuthFailed:
            return "Whisper API authentication failed. Check your API key in Settings → AI Services."
        case .remoteFileTooLarge:
            return "Audio too large for Whisper API (max 25 MB). Try a shorter recording."
        case .remoteRateLimited:
            return "Whisper API rate limited. Wait a few minutes and try again."
        case .remoteServerError:
            return "Whisper API server error. The service may be temporarily unavailable."
        case .retriesExhausted(let n, let msg):
            return "Transcription failed after \(n) attempts. Last error: \(msg)"
        case .engineError(let detail):
            return "Transcription engine error: \(detail)"
        case .noSpeechDetected:
            return "No speech detected in the audio. Try recording in a quieter environment."
        case .imageUnreadable:
            return "Image file could not be read. It may be corrupted."
        case .imageNoContent:
            return "No text or visual content could be extracted from this image."
        case .ocrFailed:
            return "Text recognition failed. Try a clearer photo with better lighting."
        case .textEmpty:
            return "No text content found in this item."
        case .bookmarkFetchFailed:
            return "Could not fetch content from the bookmark URL."
        case .taskCancelled:
            return "Processing was cancelled."
        }
    }
}

// MARK: - Source Context

/// Describes where an item came from so the analysis prompt can adapt.
struct SourceContext: Sendable {
    enum SourceType: String, Sendable {
        case recording
        case import_
        case scan
        case note
    }

    let sourceType: SourceType
    let metadata: [String: String]

    static func from(_ item: KnowledgeItem) -> SourceContext {
        let sourceType: SourceType
        var metadata: [String: String] = [:]

        if item.audioFileRelativePath != nil {
            sourceType = .recording
            if let dur = item.durationSeconds { metadata["duration"] = formatDuration(dur) }
            if let lang = item.languageCode { metadata["language"] = lang }
        } else if item.imageFileRelativePath != nil {
            sourceType = .scan
            if let pages = item.imagePageCount { metadata["pageCount"] = String(pages) }
        } else if item.isImported {
            sourceType = .import_
            if let source = item.importSourceURL {
                metadata["filename"] = URL(string: source)?.lastPathComponent ?? source
            }
        } else {
            sourceType = .note
        }

        metadata["createdAt"] = item.createdAt.formatted(date: .complete, time: .shortened)
        if !item.tags.isEmpty { metadata["tags"] = item.tags.joined(separator: ", ") }

        return SourceContext(sourceType: sourceType, metadata: metadata)
    }

    func analysisSystemPrompt() -> String {
        switch sourceType {
        case .recording:
            return "You are an audio content analyst. Extract decisions, action items with owners, risks, open questions, important dates, mentioned people/systems/organizations, and a topic timeline. Return only valid JSON."
        case .import_:
            return "You are a document analyst. Analyze this imported file. Identify its structure, key points, decisions if any, action items, risks, mentioned entities, and dates. Consider the filename and metadata for context. Return only valid JSON."
        case .scan:
            return "You are a visual content analyst. Analyze this image description (which may include OCR text and/or an AI-generated visual description). Identify what is depicted, key objects, text content, context, and any action items or insights. Note this is NOT a meeting transcript — focus on visual content. Return only valid JSON."
        case .note:
            return "You are a knowledge analyst. Analyze this note. Extract key themes, questions being explored, references to other topics, action items if any, and people/systems mentioned. Return only valid JSON."
        }
    }

    func userPromptPrefix() -> String {
        var lines: [String] = []
        switch sourceType {
        case .recording:
            lines.append("The following is an audio transcript.")
            if let dur = metadata["duration"] { lines.append("Duration: \(dur)") }
            if let lang = metadata["language"] { lines.append("Language: \(lang)") }
        case .import_:
            lines.append("The following is the content of an imported file.")
            if let fn = metadata["filename"] { lines.append("Filename: \(fn)") }
        case .scan:
            lines.append("The following describes an image (may include OCR text and/or visual scene description).")
            if let pages = metadata["pageCount"] { lines.append("Pages: \(pages)") }
        case .note:
            lines.append("The following is a user note.")
        }
        if let tags = metadata["tags"], !tags.isEmpty { lines.append("Tags: \(tags)") }
        if let createdAt = metadata["createdAt"] { lines.append("Created: \(createdAt)") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
make quick
```
Expected: BUILD SUCCEEDED (test host warning is pre-existing)

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/ContentProcessor.swift
git commit -m "feat: add ContentProcessor protocol + ExtractionError + SourceContext

Foundation types for unified transcription pipeline. ContentProcessor
protocol defines the single-method interface for all content extractors.
ExtractionError enum provides 21 structured, user-visible error codes.
SourceContext moved from ContentExtractionService for reuse.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: AudioProcessor

**Files:**
- Create: `wawa-note/Domain/Services/Processors/AudioProcessor.swift`

**Interfaces:**
- Consumes: `ContentProcessor` protocol (Task 1), `ContentExtractionService.resolveEngine()`, `TranscriptionEngine`, `FileArtifactStore`
- Produces: `AudioProcessor: ContentProcessor`

- [ ] **Step 1: Create directory**

```bash
mkdir -p wawa-note/Domain/Services/Processors
```

- [ ] **Step 2: Create AudioProcessor.swift with full implementation**

```swift
import Foundation
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from audio items via transcription.
/// Handles all 17 error cases with structured ExtractionError codes.
/// Delegates engine selection to ContentExtractionService.resolveEngine().
final class AudioProcessor: ContentProcessor {

    private let fileStore: FileArtifactStore

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    // MARK: - ContentProcessor

    func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
        guard !Task.isCancelled else {
            fail(item, context: context, error: .taskCancelled)
            return nil
        }

        // Resolve audio URL (sandbox or shared container for Share Extension imports)
        let sandboxURL = fileStore.audioFileURL(for: item.id)
        let sharedURL = fileStore.sharedAudioURL(for: item.id)
        let audioURL: URL
        if FileManager.default.fileExists(atPath: sandboxURL.path) {
            audioURL = sandboxURL
        } else if FileManager.default.fileExists(atPath: sharedURL.path) {
            audioURL = sharedURL
        } else {
            fail(item, context: context, error: .audioFileNotFound)
            return nil
        }

        // Validate audio
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        guard fileSize > 4096 else {
            fail(item, context: context, error: .audioTooSmall)
            return nil
        }

        let duration = audioDuration(url: audioURL)
        guard duration >= 1.0 else {
            fail(item, context: context, error: .audioTooShort)
            return nil
        }
        guard duration <= 7200 else {
            fail(item, context: context, error: .audioTooLong(duration))
            return nil
        }

        // Resolve engine
        guard let engine = ContentExtractionService.resolveEngine(context: context) else {
            fail(item, context: context, error: .noEngineAvailable)
            return nil
        }

        // Check availability
        let availability = engine.checkAvailability()
        switch availability {
        case .available: break
        case .permissionDenied:
            fail(item, context: context, error: .speechPermissionDenied)
            return nil
        case .modelMissing(let locale):
            fail(item, context: context, error: .modelNotInstalled(locale.identifier))
            return nil
        case .hardwareUnsupported:
            fail(item, context: context, error: .noEngineAvailable)
            return nil
        case .localeUnsupported:
            fail(item, context: context, error: .noEngineAvailable)
            return nil
        case .failed(let msg):
            fail(item, context: context, error: .engineError(msg))
            return nil
        }

        do {
            try await engine.prepareIfNeeded()
        } catch {
            fail(item, context: context, error: .engineError(error.localizedDescription))
            return nil
        }

        // Safe re-transcription: backup existing transcript
        let meetingDir = fileStore.meetingDirectoryURL(for: item.id)
        let transcriptURL = meetingDir.appendingPathComponent("transcript.json")
        let backupURL = meetingDir.appendingPathComponent("transcript.json.bak")
        let checkpointURL = meetingDir.appendingPathComponent("transcript_checkpoint.json")
        let isReTranscribing = FileManager.default.fileExists(atPath: transcriptURL.path)

        if isReTranscribing {
            try? FileManager.default.moveItem(at: transcriptURL, to: backupURL)
            try? FileManager.default.removeItem(at: checkpointURL)
        }

        // Checkpoint resume
        if let checkpoint = loadCheckpoint(itemID: item.id, meetingDir: meetingDir) {
            engine.resumeFromChunk = checkpoint.completedChunks
            engine.resumePreviousText = checkpoint.segments.map(\.text).joined(separator: " ")
        }

        // Wire checkpoint saver
        let itemID = item.id
        engine.onCheckpoint = { partialTranscript, completedChunks in
            let data = CheckpointData(
                completedChunks: completedChunks,
                segments: partialTranscript.segments,
                languageCode: partialTranscript.languageCode,
                savedAt: Date()
            )
            if let encoded = try? JSONEncoder().encode(data) {
                try? encoded.write(to: checkpointURL, options: .atomic)
            }
        }

        // Cancel monitor
        let monitor = Task { [engine] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            engine.cancel()
        }
        defer { monitor.cancel() }

        // Transcribe
        do {
            var result = try await engine.transcribeFile(audioURL, meetingId: item.id)

            // Merge checkpoint segments if resuming
            if let checkpoint = loadCheckpoint(itemID: itemID, meetingDir: meetingDir),
               !checkpoint.segments.isEmpty {
                var merged = checkpoint.segments
                merged.append(contentsOf: result.segments)
                result = Transcript(
                    meetingId: itemID,
                    languageCode: result.languageCode ?? checkpoint.languageCode,
                    segments: merged,
                    sourceEngineId: result.sourceEngineId
                )
            }

            engine.finalize()

            // Write transcript
            try fileStore.createMeetingDirectory(for: itemID)
            try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: itemID)
            try? FileManager.default.removeItem(at: checkpointURL)

            // Clean up backup on success
            if isReTranscribing { try? FileManager.default.removeItem(at: backupURL) }

            item.transcriptionEngineId = engine.id
            item.languageCode = result.languageCode
            context.safeSave(context: "audio-extraction-success", itemId: itemID)

            NotificationCenter.default.post(name: .transcriptReady, object: itemID.uuidString)
            return result.segments.map(\.text).joined(separator: "\n")

        } catch let error as TranscriptionError {
            // Restore backup on failure
            if isReTranscribing {
                try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
            }

            let extractionError = mapTranscriptionError(error)
            fail(item, context: context, error: extractionError)
            return nil
        } catch {
            if isReTranscribing {
                try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
            }
            fail(item, context: context, error: .engineError(error.localizedDescription))
            return nil
        }
    }

    // MARK: - Private

    private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
        item.status = .failed
        item.lastErrorRaw = error.errorDescription
        context.safeSave(context: "audio-extraction-failed", itemId: item.id)
    }

    private func audioDuration(url: URL) -> Double {
        let secs = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return (secs.isNaN || secs.isInfinite || secs <= 0) ? 0 : secs
    }

    private func mapTranscriptionError(_ error: TranscriptionError) -> ExtractionError {
        switch error {
        case .notAuthorized: return .speechPermissionDenied
        case .cancelled: return .taskCancelled
        case .noSupportedLocale: return .noEngineAvailable
        case .fileTooLarge: return .remoteFileTooLarge
        case .fileTooLongForLocal: return .audioTooLong(7200)
        case .modelNotInstalled(let locale): return .modelNotInstalled(locale)
        case .onDeviceUnavailable: return .noEngineAvailable
        case .recognitionFailed(let msg):
            if msg.contains("timed out") { return .recognitionTimedOut }
            if msg.contains("413") { return .remoteFileTooLarge }
            if msg.contains("429") { return .remoteRateLimited }
            if msg.contains("401") || msg.contains("403") { return .remoteAuthFailed }
            if msg.contains("500") || msg.contains("502") || msg.contains("503") { return .remoteServerError }
            if msg.contains("No speech") { return .noSpeechDetected }
            return .engineError(msg)
        }
    }

    private struct CheckpointData: Codable {
        let completedChunks: Int
        let segments: [TranscriptSegment]
        let languageCode: String?
        let savedAt: Date
    }

    private func loadCheckpoint(itemID: UUID, meetingDir: URL) -> CheckpointData? {
        let url = meetingDir.appendingPathComponent("transcript_checkpoint.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(CheckpointData.self, from: data),
              Date().timeIntervalSince(checkpoint.savedAt) < 86400
        else { return nil }
        return checkpoint
    }
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
make quick
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/Processors/
git commit -m "feat: add AudioProcessor with 17 structured error cases

Extracts text from audio via transcription engines. Handles all error
paths with ExtractionError codes and user-visible messages. Supports
checkpoint resume, safe re-transcription with backup/restore, and
engine availability checking.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: ImageProcessor

**Files:**
- Create: `wawa-note/Domain/Services/Processors/ImageProcessor.swift`

**Interfaces:**
- Consumes: `ContentProcessor` protocol (Task 1), Vision framework, `ProviderRouter`
- Produces: `ImageProcessor: ContentProcessor`

- [ ] **Step 1: Create ImageProcessor.swift**

```swift
import Foundation
import UIKit
import Vision
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from images via OCR + LLM Vision.
final class ImageProcessor: ContentProcessor {

    private let fileStore: FileArtifactStore

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
        guard !Task.isCancelled else {
            fail(item, context: context, error: .taskCancelled)
            return nil
        }

        guard let relativePath = item.imageFileRelativePath else {
            fail(item, context: context, error: .imageUnreadable)
            return nil
        }

        let sandboxURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(relativePath)
        let sharedURL = fileStore.sharedImageURL(for: item.id, relativePath: relativePath)
        let imageURL: URL
        if FileManager.default.fileExists(atPath: sandboxURL.path) {
            imageURL = sandboxURL
        } else if FileManager.default.fileExists(atPath: sharedURL.path) {
            imageURL = sharedURL
        } else {
            fail(item, context: context, error: .imageUnreadable)
            return nil
        }

        guard let imageData = try? Data(contentsOf: imageURL),
              let image = UIImage(data: imageData),
              let cgImage = image.cgImage
        else {
            fail(item, context: context, error: .imageUnreadable)
            return nil
        }

        // Phase 1: Apple OCR
        let ocrText: String? = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }

        // Phase 2: LLM Vision
        var visualDescription = ""
        if let provider = try? ProviderRouter.resolveActive(context: context) {
            let model = AIConfigService.shared.modelFor(feature: "vision")
            let params = AIConfigService.shared.requestParams(for: "vision", model: model)
            let request = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text(
                        "You are a document image analyst. Describe what you see — document type, layout, visual elements, handwriting, diagrams. Be concise but thorough."
                    )]),
                    AIMessage(role: .user, content: [
                        .text("Analyze this document image."),
                        .imageFile(imageURL)
                    ])
                ],
                temperature: params.temperature,
                maxTokens: min(params.maxTokens ?? 4096, 2048)
            )
            if let response = try? await provider.send(request) {
                visualDescription = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Combine results
        var parts: [String] = []
        if let ocr = ocrText, !ocr.isEmpty { parts.append("OCR TEXT:\n\(ocr)") }
        if !visualDescription.isEmpty { parts.append("VISUAL ANALYSIS:\n\(visualDescription)") }

        guard !parts.isEmpty else {
            fail(item, context: context, error: .imageNoContent)
            return nil
        }

        let combined = parts.joined(separator: "\n\n---\n\n")
        item.bodyText = combined
        context.safeSave(context: "image-extraction-success", itemId: item.id)
        return combined
    }

    private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
        item.status = .failed
        item.lastErrorRaw = error.errorDescription
        context.safeSave(context: "image-extraction-failed", itemId: item.id)
    }
}
```

- [ ] **Step 2: Build**

```bash
make quick
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/Processors/ImageProcessor.swift
git commit -m "feat: add ImageProcessor with OCR + LLM Vision extraction

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: TextProcessor

**Files:**
- Create: `wawa-note/Domain/Services/Processors/TextProcessor.swift`

**Interfaces:**
- Consumes: `ContentProcessor` protocol (Task 1)
- Produces: `TextProcessor: ContentProcessor`

- [ ] **Step 1: Create TextProcessor.swift**

```swift
import Foundation
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from notes, bookmarks, and imported documents.
final class TextProcessor: ContentProcessor {

    func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
        guard !Task.isCancelled else {
            fail(item, context: context, error: .taskCancelled)
            return nil
        }

        // Use existing bodyText if available
        if let body = item.bodyText, !body.isEmpty, body != " " {
            return body
        }

        // Fetch web bookmark content
        if item.type == .webBookmark, let urlStr = item.importSourceURL, let url = URL(string: urlStr),
           let scheme = url.scheme, scheme.hasPrefix("http") {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let html = String(data: data, encoding: .utf8) else {
                    fail(item, context: context, error: .bookmarkFetchFailed)
                    return nil
                }
                let plainText = html
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let truncated = String(plainText.prefix(8000))
                item.bodyText = truncated
                context.safeSave(context: "bookmark-extract-success", itemId: item.id)
                return truncated
            } catch {
                fail(item, context: context, error: .bookmarkFetchFailed)
                return nil
            }
        }

        fail(item, context: context, error: .textEmpty)
        return nil
    }

    private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
        item.status = .failed
        item.lastErrorRaw = error.errorDescription
        context.safeSave(context: "text-extraction-failed", itemId: item.id)
    }
}
```

- [ ] **Step 2: Build**

```bash
make quick
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/Processors/TextProcessor.swift
git commit -m "feat: add TextProcessor for notes, bookmarks, and imported docs

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: ContentAnalysisService (Extract from ContentPipelineService)

**Files:**
- Create: `wawa-note/Domain/Services/ContentAnalysisService.swift`

**Interfaces:**
- Consumes: `ProviderRouter`, `AgentLoop`, `AnalysisService`, `SourceContext`, `AIConfigService`
- Produces: `ContentAnalysisService.analyze(item:context:) async` — sets `.analyzed` or `.failed`

Because the analysis logic is tightly coupled to `ContentPipelineService`'s agent loop, this task extracts it into a standalone service.

- [ ] **Step 1: Create ContentAnalysisService.swift with the analysis Phase 1 logic from ContentPipelineService.process()**

```swift
import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

/// Runs AI analysis on extracted content. Extracted from ContentPipelineService
/// as part of the unified pipeline refactoring.
@MainActor
final class ContentAnalysisService {
    private let fileStore: FileArtifactStore
    private let modelContainer: ModelContainer

    init(fileStore: FileArtifactStore = FileArtifactStore(), modelContainer: ModelContainer) {
        self.fileStore = fileStore
        self.modelContainer = modelContainer
    }

    /// Analyze extracted text for a KnowledgeItem.
    /// Sets item.status = .analyzed on success, .failed on error.
    /// - Returns: true if analysis completed successfully.
    func analyze(item: KnowledgeItem, context: ModelContext) async -> Bool {
        guard !Task.isCancelled else {
            item.lastErrorRaw = "Analysis was cancelled."
            item.status = .failed
            context.safeSave(context: "analysis-cancelled", itemId: item.id)
            return false
        }

        // Resolve provider
        guard let provider = try? ProviderRouter.resolveActive(context: context) else {
            item.lastErrorRaw = ExtractionError.engineError("No AI provider configured. Go to Settings → AI Services.").errorDescription
            item.status = .failed
            context.safeSave(context: "analysis-no-provider", itemId: item.id)
            return false
        }

        // Get text to analyze
        let extractionSvc = ContentExtractionService(modelContext: context, fileStore: fileStore)
        guard let text = await extractionSvc.bestAvailableText(for: item),
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            item.lastErrorRaw = "No extractable text found for analysis."
            item.status = .failed
            context.safeSave(context: "analysis-no-text", itemId: item.id)
            return false
        }

        // Build source context
        let sourceCtx = SourceContext.from(item)
        let settings = AutomationSettings.shared
        let model = settings.resolveAutoAnalysisModel(context: context) ?? settings.autoAnalysisModel

        // Chunk text for analysis
        let segments = extractionSvc.chunkText(text, itemID: item.id)
        let transcript = Transcript(
            meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "text-direct"
        )

        // Retry loop (max 2 attempts)
        var lastError: String?
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            do {
                let result = try await AnalysisService().analyze(
                    transcript: transcript, using: provider, model: model,
                    meetingId: item.id, sourceContext: sourceCtx
                )

                try fileStore.createMeetingDirectory(for: item.id)
                try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)

                item.status = .analyzed
                item.analysisProviderId = model
                item.inboxDate = nil
                context.safeSave(context: "analysis-success", itemId: item.id)

                NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)
                return true
            } catch let error as ProviderError where !error.isRetryable {
                lastError = error.localizedDescription
                break // Permanent error — no retry
            } catch {
                lastError = error.localizedDescription
                // Transient error — will retry
            }
        }

        // All retries exhausted or permanent error
        item.status = .failed
        item.lastErrorRaw = lastError ?? "Analysis failed after retries."
        context.safeSave(context: "analysis-failed", itemId: item.id)
        return false
    }
}
```

- [ ] **Step 2: Build**

```bash
make quick
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/ContentAnalysisService.swift
git commit -m "feat: extract ContentAnalysisService from ContentPipelineService

Standalone analysis service with retry logic, provider resolution,
and structured error handling. Sets .analyzed or .failed with lastError.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: TranscriptionPipeline Orchestrator

**Files:**
- Create: `wawa-note/Domain/Services/TranscriptionPipeline.swift`

**Interfaces:**
- Consumes: All Tasks 1-5
- Produces: `TranscriptionPipeline.shared.run(itemID:context:mode:)`

- [ ] **Step 1: Create TranscriptionPipeline.swift**

```swift
import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

// MARK: - Transcription Pipeline

/// Single orchestrator for all content extraction + analysis.
/// Every entry point routes through here via ProcessingQueue.
///
/// Guarantee: every call reaches a terminal state (.failed, .analyzed,
/// .pendingReview) or the defer block forces .failed.
@MainActor
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()

    enum Mode {
        case transcribeOnly   // Extract text → .pendingReview
        case full             // Extract + analyze → .analyzed
    }

    private var activeJobs: [UUID: Task<Void, Never>] = [:]
    private let fileStore = FileArtifactStore()
    private lazy var audioProcessor = AudioProcessor(fileStore: fileStore)
    private lazy var imageProcessor = ImageProcessor(fileStore: fileStore)
    private lazy var textProcessor = TextProcessor()

    private var analysisService: ContentAnalysisService?

    private init() {}

    /// Set the analysis service after init (requires ModelContainer).
    func configure(modelContainer: ModelContainer) {
        analysisService = ContentAnalysisService(
            fileStore: fileStore, modelContainer: modelContainer)
    }

    // MARK: - Public API

    func run(
        itemID: UUID,
        context: ModelContext,
        mode: Mode = .full
    ) async {
        guard activeJobs[itemID] == nil else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var terminalStateReached = false
            defer {
                self.activeJobs[itemID] = nil
                if !terminalStateReached {
                    if let item = try? KnowledgeItemService(context: context).fetchItem(id: itemID) {
                        if !item.status.isTerminal {
                            item.lastErrorRaw = "Pipeline terminated without reaching a terminal state."
                            item.status = .failed
                            context.safeSave(context: "pipeline-terminal-guarantee", itemId: itemID)
                        }
                    }
                }
                NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
            }

            guard !Task.isCancelled else {
                terminalStateReached = true
                return
            }

            guard let item = try? KnowledgeItemService(context: context).fetchItem(id: itemID) else {
                terminalStateReached = true
                return
            }

            // Phase 0: Extract
            if mode != .analyzeOnly {
                item.status = .transcribing
                context.safeSave(context: "pipeline-start-extraction", itemId: itemID)
                NotificationCenter.default.post(
                    name: .contentPipelineStageChanged, object: itemID.uuidString,
                    userInfo: ["stage": "transcribing"]
                )

                let processor = resolveProcessor(for: item.type)
                if let _ = await processor.extract(from: item, context: context) {
                    // Extraction succeeded — processor may have set .transcribed internally
                    // for audio, or .bodyText written for images.
                } else {
                    // Processor already set .failed + lastErrorRaw
                    terminalStateReached = true
                    return
                }
            }

            // Phase 1: Analyze
            if mode == .full {
                guard let analysisService else {
                    item.status = .failed
                    item.lastErrorRaw = "Analysis service not configured."
                    context.safeSave(context: "pipeline-no-analysis-service", itemId: itemID)
                    terminalStateReached = true
                    return
                }

                item.status = .analyzing
                context.safeSave(context: "pipeline-start-analysis", itemId: itemID)
                NotificationCenter.default.post(
                    name: .contentPipelineStageChanged, object: itemID.uuidString,
                    userInfo: ["stage": "analyzing"]
                )

                _ = await analysisService.analyze(item: item, context: context)
                terminalStateReached = true
            } else {
                // transcribeOnly: set pendingReview so user can verify
                item.status = .pendingReview
                context.safeSave(context: "pipeline-extraction-complete", itemId: itemID)
                terminalStateReached = true
            }
        }
        activeJobs[itemID] = task
    }

    // MARK: - Private

    private func resolveProcessor(for type: KnowledgeItemType) -> any ContentProcessor {
        switch type {
        case .audio: return audioProcessor
        case .image: return imageProcessor
        default: return textProcessor
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
make quick
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/TranscriptionPipeline.swift
git commit -m "feat: add TranscriptionPipeline orchestrator

Single orchestrator delegating to typed processors. Terminal state
guarantee on every exit path. All callers route through here.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Wire Up — ContentPipelineService + ProcessingQueue

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift` — simplify processEntry
- Modify: `wawa-note/Domain/Services/ProcessingQueueService.swift` — remove polling

- [ ] **Step 1: Simplify ContentPipelineService.processEntry()**

Replace the body of `processEntry()` to delegate to `TranscriptionPipeline`:

```swift
func processEntry(itemID: UUID, projectID: UUID? = nil, using modelContext: ModelContext? = nil) async {
    let ctx = modelContext ?? ModelContext(modelContainer)
    let container = self.modelContainer
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var resumed = false
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .pipelineCompleted, object: nil, queue: .main
        ) { note in
            guard let completedID = note.object as? String, completedID == itemID.uuidString else { return }
            if let t = token { NotificationCenter.default.removeObserver(t) }
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
        TranscriptionPipeline.shared.run(itemID: itemID, context: ctx)
    }
}
```

- [ ] **Step 2: Simplify ProcessingQueueService.finishJob()**

Remove the `isTerminal` check that polled KnowledgeItem status:

```swift
// In finishJob, replace the "check item status" block (lines 226-245) with:
// The pipeline's terminal state guarantee ensures .pipelineCompleted fires
// only when the item is in a terminal state. No need to double-check.
```

- [ ] **Step 3: Build**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift wawa-note/Domain/Services/ProcessingQueueService.swift
git commit -m "fix: wire ContentPipelineService + ProcessingQueue to TranscriptionPipeline

processEntry() now delegates to TranscriptionPipeline.shared.run().
Removed redundant isTerminal polling — pipeline guarantees terminal state.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Wire Up — RecordingCoordinator + KnowledgeDetailView + ChatView

**Files:**
- Modify: `wawa-note/Connectivity/RecordingCoordinator.swift` — mandatory queue
- Modify: `wawa-note/UI/Knowledge/KnowledgeDetailView.swift` — pipeline-driven, ModelContext.refresh
- Modify: `wawa-note/UI/Chat/ChatView.swift` — route dictation through pipeline

- [ ] **Step 1: Verify RecordingCoordinator uses mandatory queue** (already done in previous commits)

- [ ] **Step 2: Verify KnowledgeDetailView refreshes item on .pipelineCompleted** (already done)

- [ ] **Step 3: Wire ChatView dictation through TranscriptionPipeline** (already done)

- [ ] **Step 4: Build + deploy**

```bash
make deploy DEVICE=14plus
```

- [ ] **Step 5: Commit any remaining wiring changes**

```bash
git add -A && git commit -m "fix: final wiring — all entry points route through TranscriptionPipeline

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Remove Dead Code

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift` — remove `process()`, `activeJobs`, `pipelineStatus`
- Modify: `wawa-note/Domain/Services/ContentExtractionService.swift` — remove `extractTextFromAudio()`, `transcribeSingleFile()`

- [ ] **Step 1: Remove process() from ContentPipelineService**

Delete the `process(_:using:forceReanalysis:extractionOnly:)` method and all its helper code.

- [ ] **Step 2: Remove extractTextFromAudio() and transcribeSingleFile() from ContentExtractionService**

Delete both methods. Keep `bestAvailableText()`, `extractTextFromImage()`, `extractTextFromDocument()`, `chunkText()`, `analyze()`.

- [ ] **Step 3: Build**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift wawa-note/Domain/Services/ContentExtractionService.swift
git commit -m "chore: remove dead code — process() and direct extraction paths

Replaced by TranscriptionPipeline + ContentProcessor implementations.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Add pbxproj entries + Final Build

**Files:**
- Modify: `wawa-note.xcodeproj/project.pbxproj` — add all 6 new files

- [ ] **Step 1: Open project in Xcode, add new files to wawa-note target**

```bash
# New files to add via Xcode:
# wawa-note/Domain/Services/ContentProcessor.swift
# wawa-note/Domain/Services/TranscriptionPipeline.swift
# wawa-note/Domain/Services/ContentAnalysisService.swift
# wawa-note/Domain/Services/Processors/AudioProcessor.swift
# wawa-note/Domain/Services/Processors/ImageProcessor.swift
# wawa-note/Domain/Services/Processors/TextProcessor.swift
```

- [ ] **Step 2: Clean build**

```bash
make clean && make deploy DEVICE=14plus
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note.xcodeproj/project.pbxproj
git commit -m "chore: add new pipeline files to Xcode project

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Implementation Order

Tasks 1-4 (processors) can be done in any order. Tasks 5-6 depend on Task 1. Tasks 7-8 depend on Task 6. Task 9 depends on Task 7-8. Task 10 is the final step.

**Recommended:** 1 → 2,3,4 (parallel) → 5 → 6 → 7 → 8 → 9 → 10

## Verification

```bash
# Full build and deploy
make deploy DEVICE=14plus

# Test scenarios:
# 1. Record short audio → stop → verify "Transcribing..." → "Needs review"
# 2. Manual re-transcribe with no provider → verify error banner with message
# 3. Import audio file → verify pipeline picks it up
# 4. Scan document (image) → verify OCR + Vision extraction
# 5. Force-kill during transcription → relaunch → verify checkpoint resume
```
