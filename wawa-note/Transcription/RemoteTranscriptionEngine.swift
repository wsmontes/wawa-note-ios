import AVFoundation
import OSLog
import WawaNoteCore

final class RemoteTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
  let id = "remote-whisper"
  let displayName = "Whisper via API"

  private let baseURL: URL
  private let apiKey: String
  private let session: URLSession
  private let chunker = AudioChunker(chunkDuration: 600, overlap: 0)

  var onProgress: ((TranscriptionProgress) -> Void)?
  var onCheckpoint: ((Transcript, Int) -> Void)?
  /// Index of the last successfully transcribed chunk (0-based).
  /// Set by ContentExtractionService from a persisted checkpoint to enable resume.
  var resumeFromChunk: Int = 0
  /// Last checkpoint segment text, seeded by ContentExtractionService so
  /// deduplicateStart correctly removes the chunk overlap at the resume boundary.
  var resumePreviousText: String = ""
  private(set) var isCancelled = false

  var capabilities: TranscriptionCapabilities {
    TranscriptionCapabilities(
      supportsLive: false,
      supportsFile: true,
      isOnDevice: false,
      maxDuration: 7200,  // 2 hours
      supportedLocales: [],
      hasModelDownload: false
    )
  }

  init(baseURL: URL, apiKey: String = "", session: URLSession? = nil) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    // Custom session with generous timeouts for large uploads on bad connections.
    // timeoutIntervalForRequest: time waiting for *any* data from server (between packets).
    // timeoutIntervalForResource: total wall-clock time for the entire transfer.
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = 120  // 2 min between any server response
      config.timeoutIntervalForResource = 600  // 10 min total per chunk upload+process
      config.waitsForConnectivity = true  // Wait for network instead of failing immediately
      config.allowsExpensiveNetworkAccess = true
      config.allowsConstrainedNetworkAccess = true
      self.session = URLSession(configuration: config)
    }
  }

  func cancel() {
    isCancelled = true
  }

  func finalize() {
    onCheckpoint = nil
    onProgress = nil
    isCancelled = false
  }

  func checkAvailability() -> LocalTranscriptionAvailability {
    .available(localeIdentifier: "auto")
  }

  // MARK: - Duration

  private func getDuration(_ url: URL) -> Float64 {
    var fileID: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
      return 0
    }
    defer { AudioFileClose(fileID) }
    var duration: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size, &duration)
    return duration
  }

  private func fileSizeMB(_ url: URL) -> Double {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Double(values?.fileSize ?? 0) / 1_000_000
  }

  // MARK: - Transcribe

  func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript {
    isCancelled = false

    let durationSeconds = getDuration(audioFileURL)
    let mb = fileSizeMB(audioFileURL)

    AppLog.transcription.info(
      "Transcribing file: \(String(format: "%.1f", durationSeconds))s, \(String(format: "%.1f", mb))MB"
    )

    if durationSeconds <= chunker.chunkDuration && mb < 25 {
      onProgress?(.transcribing(chunk: 1, totalChunks: 1))
      return try await transcribeSingle(url: audioFileURL, prompt: nil, meetingId: meetingId)
    }

    let total = Int(ceil(durationSeconds / chunker.chunkDuration))
    AppLog.transcription.info("Splitting into ~\(total) chunks...")
    chunker.onProgress = { [weak self] completed, total in
      self?.onProgress?(.chunking(completed: completed, total: total))
    }
    onProgress?(.chunking(completed: 0, total: total))

    let chunks = try await chunker.splitAudio(url: audioFileURL)
    defer { chunker.cleanup() }

    // Resume support: skip already-transcribed chunks from a previous attempt.
    let startIndex = min(resumeFromChunk, chunks.count)

    // Seed previousText from resumePreviousText so deduplicateStart correctly
    // removes the chunk overlap at the resume boundary.
    var previousText: String
    if startIndex > 0, !resumePreviousText.isEmpty {
      previousText = resumePreviousText
    } else {
      previousText = ""
    }
    var allSegments: [TranscriptSegment] = []
    var languageCode: String?

    if startIndex > 0 {
      AppLog.transcription.info(
        "Resuming remote transcription from chunk \(startIndex + 1)/\(chunks.count)")
    }

    for (i, chunk) in chunks.enumerated() {
      // Skip chunks already persisted in a previous checkpoint
      if i < startIndex { continue }

      try Task.checkCancellation()
      if isCancelled { throw TranscriptionError.cancelled }

      onProgress?(.transcribing(chunk: i + 1, totalChunks: chunks.count))
      let prompt = i > 0 || startIndex > 0 ? String(previousText.suffix(500)) : nil
      AppLog.transcription.info("Chunk \(i+1)/\(chunks.count)")

      // Per-chunk retry with adaptive backoff for bad networks.
      var transcript: Transcript?
      var lastChunkError: Error?
      for attempt in 0...Self.maxRetriesPerChunk {
        if attempt > 0 {
          // Adaptive backoff: 3s, 9s, 27s — longer delays for flaky connections
          let baseDelay = pow(3.0, Double(attempt))
          let jitter = Double.random(in: -0.25...0.25)
          let delay = UInt64(max(1, baseDelay * (1 + jitter))) * 1_000_000_000
          AppLog.transcription.info(
            "Remote chunk \(i+1) retry \(attempt)/\(Self.maxRetriesPerChunk) — waiting \(delay / 1_000_000_000)s"
          )
          try await Task.sleep(nanoseconds: delay)
        }
        do {
          transcript = try await transcribeSingle(
            url: chunk.url, prompt: prompt, meetingId: meetingId)
          lastChunkError = nil
          break
        } catch TranscriptionError.cancelled {
          throw TranscriptionError.cancelled
        } catch TranscriptionError.fileTooLarge {
          // Non-retryable: server rejected the file size
          throw TranscriptionError.fileTooLarge
        } catch {
          lastChunkError = error
          AppLog.transcription.warning(
            "Remote chunk \(i+1) attempt \(attempt+1) failed: \(error.localizedDescription)")
        }
      }

      guard let chunkTranscript = transcript else {
        // All retries exhausted. Save checkpoint so next ProcessingQueue retry resumes here.
        if !allSegments.isEmpty {
          let partial = Transcript(
            meetingId: allSegments.first?.meetingId,
            languageCode: languageCode,
            segments: allSegments,
            sourceEngineId: id
          )
          onCheckpoint?(partial, i)
        }
        throw lastChunkError
          ?? TranscriptionError.recognitionFailed(
            "Chunk \(i+1)/\(chunks.count) failed after \(Self.maxRetriesPerChunk + 1) attempts")
      }

      languageCode = chunkTranscript.languageCode ?? languageCode
      let chunkText = chunkTranscript.segments.map(\.text).joined(separator: " ")

      for segment in chunkTranscript.segments {
        let adjustedStart = segment.startTime + chunk.startTime
        let adjustedEnd = segment.endTime.map { $0 + chunk.startTime }
        // When the chunk has overlap, only dedup segments within the overlap window
        let isOverlapSegment =
          chunk.overlapStart > 0
          && segment.startTime < chunk.overlapStart
        var text = segment.text
        if isOverlapSegment && (i > 0 || startIndex > 0) {
          text = deduplicateStart(text, against: previousText)
        }

        allSegments.append(
          TranscriptSegment(
            meetingId: segment.meetingId,
            startTime: adjustedStart,
            endTime: adjustedEnd,
            speakerId: segment.speakerId,
            text: text,
            originalText: segment.originalText,
            confidence: segment.confidence,
            languageCode: segment.languageCode,
            sourceEngineId: segment.sourceEngineId
          ))
      }
      previousText = chunkText

      // Checkpoint after each chunk (cross-attempt resume)
      let partial = Transcript(
        meetingId: allSegments.first?.meetingId,
        languageCode: languageCode,
        segments: allSegments,
        sourceEngineId: id
      )
      onCheckpoint?(partial, i + 1)
    }

    allSegments = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

    AppLog.transcription.info("Remote transcription complete: \(allSegments.count) segments")
    return Transcript(
      meetingId: allSegments.first?.meetingId,
      languageCode: languageCode,
      segments: allSegments,
      sourceEngineId: id
    )
  }

  // MARK: - Single chunk (with exponential backoff + network resilience)

  /// Maximum retries at the chunk level (handled by transcribeFile loop).
  /// This is the per-HTTP-request retry for transient server/network errors.
  private static let maxRetriesPerChunk = 3
  private static let maxHTTPRetries = 2
  private static let baseDelayNs: UInt64 = 2_000_000_000  // 2 seconds

  private func transcribeSingle(url: URL, prompt: String?, meetingId: UUID) async throws
    -> Transcript
  {
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    let boundary = UUID().uuidString
    let model = AIConfigService.shared.modelFor(feature: "transcription")

    // Build multipart body to a temp file (avoids loading entire audio into RAM).
    let tempDir = FileManager.default.temporaryDirectory
    let bodyURL = tempDir.appendingPathComponent("transcription_\(UUID().uuidString).body")
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    try buildBodyFile(
      audioURL: url, prompt: prompt, model: model, boundary: boundary, outputURL: bodyURL)

    var lastError: Error?
    for attempt in 0...Self.maxHTTPRetries {
      if attempt > 0 {
        // Exponential backoff: 2s, 4s with ±25% jitter
        let baseNs = Self.baseDelayNs << (attempt - 1)
        let jitter = Int64(Double(baseNs) * Double.random(in: -0.25...0.25))
        let delay = UInt64(max(0, Int64(baseNs) + jitter))
        AppLog.transcription.info(
          "HTTP retry \(attempt)/\(Self.maxHTTPRetries) — waiting \(delay / 1_000_000_000)s")
        try await Task.sleep(nanoseconds: delay)
      }

      do {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Per-request timeout: generous for large file uploads on bad connections.
        // The session-level timeoutIntervalForResource (600s) is the ultimate backstop.
        request.timeoutInterval = 300
        request.setValue(
          "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (resData, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
          throw TranscriptionError.recognitionFailed(
            "Transcription failed — invalid server response")
        }

        guard (200...299).contains(http.statusCode) else {
          let body = String(data: resData, encoding: .utf8) ?? "<no body>"
          AppLog.transcription.error("API returned \(http.statusCode): \(body.prefix(300))")
          if http.statusCode == 413 { throw TranscriptionError.fileTooLarge }
          // Retry on server errors (5xx), rate limits (429), and request timeout (408)
          if http.statusCode == 429 || http.statusCode == 408
            || (500...599).contains(http.statusCode)
          {
            lastError = TranscriptionError.recognitionFailed("HTTP \(http.statusCode)")
            continue
          }
          throw TranscriptionError.recognitionFailed(
            "Transcription failed — HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
          let body = String(data: resData, encoding: .utf8) ?? "<no body>"
          AppLog.transcription.error("Parse error: \(body.prefix(300))")
          throw TranscriptionError.recognitionFailed(
            "Transcription failed — could not parse response")
        }

        // Parse verbose_json segments when available
        if let rawSegments = json["segments"] as? [[String: Any]], !rawSegments.isEmpty {
          let segments: [TranscriptSegment] = rawSegments.compactMap { seg in
            guard let text = seg["text"] as? String else { return nil }
            return TranscriptSegment(
              meetingId: meetingId,
              startTime: seg["start"] as? Double ?? 0,
              endTime: seg["end"] as? Double,
              text: text.trimmingCharacters(in: .whitespacesAndNewlines),
              confidence: nil,
              languageCode: json["language"] as? String,
              sourceEngineId: id
            )
          }
          if !segments.isEmpty {
            AppLog.transcription.info(
              "Whisper verbose_json: \(segments.count) segments with timestamps")
            return Transcript(
              meetingId: meetingId,
              languageCode: json["language"] as? String,
              segments: segments,
              sourceEngineId: id
            )
          }
        }

        // Fallback: plain text response (no timestamps)
        guard let text = json["text"] as? String else {
          let body = String(data: resData, encoding: .utf8) ?? "<no body>"
          AppLog.transcription.error("Parse error — no text field: \(body.prefix(300))")
          throw TranscriptionError.recognitionFailed("Remote transcription error")
        }
        AppLog.transcription.info("Whisper plain text: \(text.count) chars (no timestamps)")
        return Transcript(
          meetingId: meetingId,
          languageCode: json["language"] as? String,
          segments: [
            TranscriptSegment(
              meetingId: meetingId, startTime: 0,
              text: text.trimmingCharacters(in: .whitespacesAndNewlines),
              sourceEngineId: id
            )
          ],
          sourceEngineId: id
        )
      } catch let error as TranscriptionError {
        lastError = error
        if case .fileTooLarge = error { throw error }  // don't retry
        if case .cancelled = error { throw error }  // don't retry
      } catch let error as URLError {
        lastError = error
        // Network errors are retryable: timeout, connection lost, not connected
        let retryableCodes: Set<URLError.Code> = [
          .timedOut, .networkConnectionLost, .notConnectedToInternet,
          .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
          .secureConnectionFailed, .dataNotAllowed,
        ]
        if retryableCodes.contains(error.code) {
          AppLog.transcription.warning(
            "Network error (attempt \(attempt+1)): \(error.code.rawValue) — \(error.localizedDescription)"
          )
        } else {
          // Non-retryable URL error
          throw error
        }
      } catch {
        lastError = error
        AppLog.transcription.warning(
          "Unexpected error (attempt \(attempt+1)): \(error.localizedDescription)")
      }
    }

    throw lastError
      ?? TranscriptionError.recognitionFailed(
        "Remote transcription failed after \(Self.maxHTTPRetries + 1) attempts")
  }

  // MARK: - Multipart to temp file (streaming — no full-file RAM load)

  private func buildBodyFile(
    audioURL: URL, prompt: String?, model: String, boundary: String, outputURL: URL
  ) throws {
    guard let output = OutputStream(url: outputURL, append: false) else {
      throw NSError(
        domain: "body", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot create output stream"])
    }
    output.open()
    defer { output.close() }

    let lb = "\r\n"

    enum BodyWriteError: Error, LocalizedError {
      case writeFailed(Int)
      case partialWrite(expected: Int, actual: Int)
      var errorDescription: String? {
        switch self {
        case .writeFailed(let code): return "OutputStream write failed with code \(code)"
        case .partialWrite(let expected, let actual):
          return "OutputStream partial write: \(actual)/\(expected) bytes"
        }
      }
    }

    func write(_ s: String) throws {
      guard let d = s.data(using: .utf8) else { return }
      let written = try d.withUnsafeBytes { ptr -> Int in
        let result = output.write(
          ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count)
        if result < 0 {
          throw BodyWriteError.writeFailed(result)
        }
        return result
      }
      if written != d.count {
        throw BodyWriteError.partialWrite(expected: d.count, actual: written)
      }
    }

    try write("--\(boundary)\(lb)")
    try write("Content-Disposition: form-data; name=\"model\"\(lb)\(lb)")
    try write("\(model)\(lb)")

    try write("--\(boundary)\(lb)")
    try write("Content-Disposition: form-data; name=\"response_format\"\(lb)\(lb)")
    try write("verbose_json\(lb)")
    try write("--\(boundary)\(lb)")
    try write("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\(lb)\(lb)")
    try write("segment\(lb)")

    if let prompt, !prompt.isEmpty {
      try write("--\(boundary)\(lb)")
      try write("Content-Disposition: form-data; name=\"prompt\"\(lb)\(lb)")
      try write("\(prompt)\(lb)")
    }

    let filename = audioURL.lastPathComponent
    let mimeType: String = {
      switch audioURL.pathExtension.lowercased() {
      case "wav": return "audio/wav"
      case "mp3": return "audio/mpeg"
      case "m4a": return "audio/mp4"
      default: return "audio/mp4"
      }
    }()
    try write("--\(boundary)\(lb)")
    try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lb)")
    try write("Content-Type: \(mimeType)\(lb)\(lb)")

    // Stream audio file data in 64 KB chunks to avoid RAM spikes on large files.
    // A 10-min M4A can be 15-25 MB; loading it all at once wastes memory
    // and risks jetsam on constrained devices.
    guard let input = InputStream(url: audioURL) else {
      throw NSError(
        domain: "body", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Cannot open audio file for reading"])
    }
    input.open()
    defer { input.close() }

    let bufferSize = 65_536  // 64 KB
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while input.hasBytesAvailable {
      let bytesRead = input.read(&buffer, maxLength: bufferSize)
      if bytesRead > 0 {
        let written = output.write(buffer, maxLength: bytesRead)
        if written < 0 {
          throw BodyWriteError.writeFailed(written)
        }
        if written != bytesRead {
          throw BodyWriteError.partialWrite(expected: bytesRead, actual: written)
        }
      } else if bytesRead < 0 {
        throw input.streamError
          ?? NSError(
            domain: "body", code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Error reading audio file"])
      } else {
        break  // EOF
      }
    }

    try write("\(lb)")
    try write("--\(boundary)--\(lb)")
  }

  // MARK: - Dedup

  private func deduplicateStart(_ text: String, against previous: String) -> String {
    let prevWords = previous.lowercased().split(separator: " ")
    let currWords = text.lowercased().split(separator: " ")
    let original = text.split(separator: " ").map(String.init)
    guard !prevWords.isEmpty, !currWords.isEmpty else { return text }

    var maxMatch = 0
    for j in 1...min(10, prevWords.count, currWords.count) {
      if prevWords.suffix(j) == currWords.prefix(j) { maxMatch = j }
    }
    if maxMatch > 0, maxMatch < original.count {
      return original.dropFirst(maxMatch).joined(separator: " ")
    }
    return text
  }
}
