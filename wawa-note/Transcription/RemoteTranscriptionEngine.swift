import AVFoundation
import OSLog

// Related JIRA: KAN-6, KAN-22

final class RemoteTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "remote-whisper"
    let displayName = "Whisper via API"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let chunker = AudioChunker(chunkDuration: 600, overlap: 2)

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

    // Shared in TranscriptionEngine.swift as transcriptionGetDuration(_:)
    private func getDuration(_ url: URL) -> Float64 {
        transcriptionGetDuration(url)
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

        AppLog.transcription.info("Transcribing file: \(String(format: "%.1f", durationSeconds))s, \(String(format: "%.1f", mb))MB")

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

            let transcript = try await transcribeSingle(url: chunk.url, prompt: prompt, meetingId: meetingId)
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

    private func transcribeSingle(url: URL, prompt: String?, meetingId: UUID) async throws -> Transcript {
        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        let boundary = UUID().uuidString
        let model = AIConfigService.shared.modelFor(feature: "transcription")

        // Build multipart body with the native format (M4A/AAC sent directly).
        // OpenAI Whisper API accepts this natively; WAV conversion is deferred
        // until the API explicitly rejects the format (HTTP 415/406).
        let tempDir = FileManager.default.temporaryDirectory
        let bodyURL = tempDir.appendingPathComponent("transcription_\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try buildBodyFile(audioURL: url, prompt: prompt, model: model, boundary: boundary, outputURL: bodyURL)

        var lastError: Error?
        var triedWAVFallback = false
        let isCompressed = ["m4a", "mp4"].contains(url.pathExtension.lowercased())

        // Pre-flight: validate audio file before sending to API.
        // Corrupted files fail immediately without burning retry attempts (API quota + time).
        let audioData: Data
        do {
            audioData = try Data(contentsOf: url)
        } catch {
            throw TranscriptionError.recognitionFailed("Cannot read audio file: \(error.localizedDescription)")
        }
        guard !audioData.isEmpty else {
            throw TranscriptionError.recognitionFailed("Audio file is empty")
        }
        if url.pathExtension.lowercased() == "wav" {
            guard audioData.count >= 44 else {
                throw TranscriptionError.recognitionFailed("WAV file too small (\(audioData.count) bytes) — minimum 44 bytes for header")
            }
            let riffHeader = String(data: audioData.prefix(4), encoding: .ascii)
            guard riffHeader == "RIFF" else {
                throw TranscriptionError.recognitionFailed("WAV file missing RIFF header — file is corrupted")
            }
        }
        if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) {
            guard audioData.count >= 8 else {
                throw TranscriptionError.recognitionFailed("M4A file too small (\(audioData.count) bytes)")
            }
            let ftyp = String(data: audioData.subdata(in: 4..<8), encoding: .ascii)
            guard ftyp == "ftyp" else {
                throw TranscriptionError.recognitionFailed("M4A file missing ftyp atom — file is corrupted")
            }
        }

        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                // Exponential backoff: 1s, 2s, 4s with ±25% jitter
                let baseNs = Self.baseDelayMs << (attempt - 1)
                let jitter = Int64(Double(baseNs) * Double.random(in: -0.25...0.25))
                let delay = UInt64(max(0, Int64(baseNs) + jitter))
                AppLog.transcription.info("Retry \(attempt)/\(Self.maxRetries) — waiting \(delay / 1_000_000)ms")
                try await Task.sleep(nanoseconds: delay)
            }

            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
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

                    // Format rejection: fall back to WAV for AAC/M4A files.
                    // OpenAI Whisper accepts M4A natively, but self-hosted
                    // backends (Ollama, older Whisper) may only support WAV.
                    if (http.statusCode == 415 || http.statusCode == 406)
                        && isCompressed && !triedWAVFallback
                    {
                        triedWAVFallback = true
                        AppLog.transcription.info(
                            "API rejected format (\(http.statusCode)), falling back to WAV")
                        let wavURL = try convertToWAV(url)
                        defer { try? FileManager.default.removeItem(at: wavURL) }
                        // Remove old body, rebuild with WAV
                        try? FileManager.default.removeItem(at: bodyURL)
                        try buildBodyFile(
                            audioURL: wavURL, prompt: prompt, model: model,
                            boundary: boundary, outputURL: bodyURL)
                        continue
                    }

                    // Retry on server errors (5xx) and rate limits (429)
                    if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                        lastError = TranscriptionError.recognitionFailed("HTTP \(http.statusCode)")
                        continue
                    }
                    throw TranscriptionError.recognitionFailed("Remote transcription error")
                }

                guard let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
                    let body = String(data: resData, encoding: .utf8) ?? "<no body>"
                    AppLog.transcription.error("Parse error: \(body.prefix(300))")
                    throw TranscriptionError.recognitionFailed("Remote transcription error")
                }

                // KAN-512: Parse verbose_json segments with fallback to plain text
                let segments: [TranscriptSegment]
                if let jsonSegments = json["segments"] as? [[String: Any]], !jsonSegments.isEmpty {
                    segments = jsonSegments.compactMap { seg in
                        guard let text = seg["text"] as? String else { return nil }
                        // Whisper's avg_logprob is a log-probability (≤ 0), not a [0,1] confidence.
                        // Convert to a probability via exp() so it matches the Apple engine's scale. (KAN-518)
                        let confidence: Double? = (seg["avg_logprob"] as? Double).map { min(1.0, max(0.0, exp($0))) }
                        return TranscriptSegment(
                            meetingId: meetingId,
                            startTime: seg["start"] as? Double ?? 0,
                            endTime: seg["end"] as? Double,
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            confidence: confidence,
                            languageCode: json["language"] as? String,
                            sourceEngineId: id
                        )
                    }
                } else if let text = json["text"] as? String {
                    // Fallback for providers that don't support verbose_json
                    segments = [
                        TranscriptSegment(
                            meetingId: meetingId, startTime: 0,
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            sourceEngineId: id
                        )
                    ]
                } else {
                    throw TranscriptionError.recognitionFailed("No text or segments in response")
                }

                return Transcript(
                    languageCode: json["language"] as? String,
                    segments: segments,
                    sourceEngineId: id
                )
            } catch let error as TranscriptionError {
                lastError = error
                if case .fileTooLarge = error { throw error }  // don't retry
                if case .cancelled = error { throw error }  // don't retry
            } catch {
                lastError = error
                // Network errors are retryable
                AppLog.transcription.warning("Network error (attempt \(attempt+1)): \(error.localizedDescription)")
            }
        }

        throw lastError ?? TranscriptionError.recognitionFailed("Remote transcription failed after \(Self.maxRetries + 1) attempts")
    }

    // MARK: - Multipart to temp file

    private func buildBodyFile(audioURL: URL, prompt: String?, model: String, boundary: String, outputURL: URL) throws {
        guard let output = OutputStream(url: outputURL, append: false) else {
            throw NSError(domain: "body", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create output stream"])
        }
        output.open()
        defer { output.close() }

        let lb = "\r\n"
        func write(_ s: String) {
            if let d = s.data(using: .utf8) {
                _ = d.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count) }
            }
        }
        func writeData(_ d: Data) {
            _ = d.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count) }
        }

        write("--\(boundary)\(lb)")
        write("Content-Disposition: form-data; name=\"model\"\(lb)\(lb)")
        write("\(model)\(lb)")

        if let prompt, !prompt.isEmpty {
            write("--\(boundary)\(lb)")
            write("Content-Disposition: form-data; name=\"prompt\"\(lb)\(lb)")
            write("\(prompt)\(lb)")
        }

        // KAN-512: Request verbose_json for per-segment timestamps
        write("--\(boundary)\(lb)")
        write("Content-Disposition: form-data; name=\"response_format\"\(lb)\(lb)")
        write("verbose_json\(lb)")

        let filename = audioURL.lastPathComponent
        let mimeType: String = {
            switch audioURL.pathExtension.lowercased() {
            case "wav": return "audio/wav"
            case "mp3": return "audio/mpeg"
            case "m4a", "mp4": return "audio/mp4"
            default: return "audio/mp4"
            }
        }()
        write("--\(boundary)\(lb)")
        write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lb)")
        write("Content-Type: \(mimeType)\(lb)\(lb)")

        // Stream audio file data into the body.
        // M4A/AAC is sent directly — the OpenAI Whisper API accepts it natively.
        // Only self-hosted backends (Ollama, etc.) may reject AAC; handled by
        // convertToWAV fallback in transcribeSingle when 415 is received.
        let audioData = try Data(contentsOf: audioURL)
        writeData(audioData)
        write("\(lb)")
        write("--\(boundary)--\(lb)")
    }

    // MARK: - Format fallback

    /// Converts AAC/M4A to 16kHz 16-bit mono PCM WAV.
    /// Only invoked as a fallback when the API rejects the native format (HTTP 415).
    /// OpenAI's Whisper API accepts M4A natively, so this path is rarely taken.
    /// Adapted from AppleSpeechTranscriptionEngine.prepareForRecognition.
    private func convertToWAV(_ url: URL) throws -> URL {
        AppLog.transcription.info("API rejected native format, converting AAC→WAV: \(url.lastPathComponent)")

        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false)
        else {
            throw TranscriptionError.recognitionFailed("Cannot create WAV output format")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_fallback_\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.recognitionFailed("Cannot create audio converter")
        }

        inputFile.framePosition = 0
        let inputLength = AVAudioFrameCount(inputFile.length)
        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputLength) else {
            throw TranscriptionError.recognitionFailed("Cannot allocate input buffer")
        }
        try inputFile.read(into: inputBuf)

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuf.frameLength) * ratio)
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw TranscriptionError.recognitionFailed("Cannot allocate output buffer")
        }

        var provided = false
        var convertError: NSError?
        converter.convert(to: outputBuf, error: &convertError) { _, outStatus in
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return inputBuf
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let convertError { throw convertError }
        try outputFile.write(from: outputBuf)

        AppLog.transcription.info("WAV fallback ready: \(outputBuf.frameLength) frames @ 16kHz")
        return tempURL
    }

    // MARK: - Dedup

    // Shared in TranscriptionEngine.swift as transcriptionDeduplicateStart(_:against:)
    private func deduplicateStart(_ text: String, against previous: String) -> String {
        transcriptionDeduplicateStart(text, against: previous)
    }
}
