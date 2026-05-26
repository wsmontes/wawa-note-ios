import Foundation
import OSLog

final class RemoteTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "remote-whisper"
    let displayName = "Whisper via API"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript {
        let url = baseURL.appendingPathComponent("audio/transcriptions")

        let audioData = try Data(contentsOf: audioFileURL)
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = buildMultipartBody(
            audioData: audioData,
            fileName: audioFileURL.lastPathComponent,
            model: "whisper-1",
            boundary: boundary
        )

        AppLog.transcription.info("Sending audio to Whisper API: \(audioFileURL.lastPathComponent) (\(audioData.count) bytes)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.recognitionFailed
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            AppLog.transcription.error("Whisper API returned status \(httpResponse.statusCode)")
            throw TranscriptionError.recognitionFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError.recognitionFailed
        }

        let segment = TranscriptSegment(
            meetingId: UUID(),
            startTime: 0,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceEngineId: id
        )

        AppLog.transcription.info("Whisper transcription complete: \(text.prefix(100))...")

        return Transcript(
            languageCode: json["language"] as? String,
            segments: [segment],
            sourceEngineId: id
        )
    }

    private func buildMultipartBody(audioData: Data, fileName: String, model: String, boundary: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)")
        append("\(model)\(lineBreak)")

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        append("Content-Type: audio/mp4\(lineBreak)\(lineBreak)")
        body.append(audioData)
        append("\(lineBreak)")

        append("--\(boundary)--\(lineBreak)")

        return body
    }
}
