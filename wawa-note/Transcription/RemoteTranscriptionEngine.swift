import AVFoundation
import OSLog

final class RemoteTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
  let id = "remote-whisper"
  let displayName = "Whisper via API"

  private let baseURL: URL
  private let apiKey: String
  private let session: URLSession
  private let chunker = AudioChunker(chunkDuration: 600, overlap: 0)

  var onProgress: ((TranscriptionProgress) -> Void)?
  var onCheckpoint: ((Transcript, Int) -> Void)?
  private(set) var isCancelled = false

  var capabilities: TranscriptionCapabilities {
    TranscriptionCapabilities(
      supportsLive: false,
      supportsFile: true,
      isOnDevice: false,
      maxDuration: 3600,
      supportedLocales: [],
      hasModelDownload: false
    )
  }

  init(baseURL: URL, apiKey: String = "", session: URLSession = .shared) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.session = session
  }

  func cancel() {
    isCancelled = true
  }

  func checkAvailability() -> LocalTranscriptionAvailability {
    // Remote engine is always "available" — it doesn't use on-device models
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

    var previousText = ""
    var allSegments: [TranscriptSegment] = []
    var languageCode: String?

    for (i, chunk) in chunks.enumerated() {
      try Task.checkCancellation()
      if isCancelled { throw TranscriptionError.cancelled }

      onProgress?(.transcribing(chunk: i + 1, totalChunks: chunks.count))
      let prompt = i > 0 ? String(previousText.suffix(500)) : nil
      AppLog.transcription.info("Chunk \(i+1)/\(chunks.count)")

      let transcript = try await transcribeSingle(
        url: chunk.url, prompt: prompt, meetingId: meetingId)
      languageCode = transcript.languageCode ?? languageCode

      let chunkText = transcript.segments.map(\.text).joined(separator: " ")

      for segment in transcript.segments {
        let adjustedStart = segment.startTime + chunk.startTime
        let adjustedEnd = segment.endTime.map { $0 + chunk.startTime }
        var text = segment.text
        if i > 0 { text = deduplicateStart(text, against: previousText) }

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

      // Checkpoint after each chunk
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

  // MARK: - Single chunk (with exponential backoff)

  private static let maxRetries = 3
  private static let baseDelayMs: UInt64 = 1_000_000_000  // 1 second

  private func transcribeSingle(url: URL, prompt: String?, meetingId: UUID) async throws
    -> Transcript
  {
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    let boundary = UUID().uuidString
    let model = AIConfigService.shared.modelFor(feature: "transcription")

    // Build multipart body once (memory-efficient)
    let tempDir = FileManager.default.temporaryDirectory
    let bodyURL = tempDir.appendingPathComponent("transcription_\(UUID().uuidString).body")
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    try buildBodyFile(
      audioURL: url, prompt: prompt, model: model, boundary: boundary, outputURL: bodyURL)

    var lastError: Error?
    for attempt in 0...Self.maxRetries {
      if attempt > 0 {
        // Exponential backoff: 1s, 2s, 4s with ±25% jitter
        let baseNs = Self.baseDelayMs << (attempt - 1)
        let jitter = Int64(Double(baseNs) * Double.random(in: -0.25...0.25))
        let delay = UInt64(max(0, Int64(baseNs) + jitter))
        AppLog.transcription.info(
          "Retry \(attempt)/\(Self.maxRetries) — waiting \(delay / 1_000_000)ms")
        try await Task.sleep(nanoseconds: delay)
      }

      do {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
          "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (resData, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
          throw TranscriptionError.recognitionFailed("Remote transcription error")
        }

        guard (200...299).contains(http.statusCode) else {
          let body = String(data: resData, encoding: .utf8) ?? "<no body>"
          AppLog.transcription.error("API returned \(http.statusCode): \(body.prefix(300))")
          if http.statusCode == 413 { throw TranscriptionError.fileTooLarge }
          // Retry on server errors (5xx) and rate limits (429)
          if http.statusCode == 429 || (500...599).contains(http.statusCode) {
            lastError = TranscriptionError.recognitionFailed("HTTP \(http.statusCode)")
            continue
          }
          throw TranscriptionError.recognitionFailed("Remote transcription error")
        }

        guard let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any],
          let text = json["text"] as? String
        else {
          let body = String(data: resData, encoding: .utf8) ?? "<no body>"
          AppLog.transcription.error("Parse error: \(body.prefix(300))")
          throw TranscriptionError.recognitionFailed("Remote transcription error")
        }

        return Transcript(
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
      } catch {
        lastError = error
        // Network errors are retryable
        AppLog.transcription.warning(
          "Network error (attempt \(attempt+1)): \(error.localizedDescription)")
      }
    }

    throw lastError
      ?? TranscriptionError.recognitionFailed(
        "Remote transcription failed after \(Self.maxRetries + 1) attempts")
  }

  // MARK: - Multipart to temp file

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
    func write(_ s: String) {
      if let d = s.data(using: .utf8) {
        _ = d.withUnsafeBytes {
          output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count)
        }
      }
    }
    func writeData(_ d: Data) {
      _ = d.withUnsafeBytes {
        output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count)
      }
    }

    write("--\(boundary)\(lb)")
    write("Content-Disposition: form-data; name=\"model\"\(lb)\(lb)")
    write("\(model)\(lb)")

    if let prompt, !prompt.isEmpty {
      write("--\(boundary)\(lb)")
      write("Content-Disposition: form-data; name=\"prompt\"\(lb)\(lb)")
      write("\(prompt)\(lb)")
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
    write("--\(boundary)\(lb)")
    write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lb)")
    write("Content-Type: \(mimeType)\(lb)\(lb)")

    // Stream audio file data into the body
    let audioData = try Data(contentsOf: audioURL)
    writeData(audioData)
    write("\(lb)")
    write("--\(boundary)--\(lb)")
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
