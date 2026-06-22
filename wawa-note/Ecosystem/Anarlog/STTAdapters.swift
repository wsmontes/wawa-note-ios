import Foundation
import OSLog
// Related JIRA: KAN-6, KAN-22


// MARK: - STT Adapter Protocol

/// Protocol for speech-to-text (STT) provider adapters.
///
/// Ported from anarlog's `owhisper-client` adapter system.
/// Each adapter wraps a REST API with:
/// - URL construction (endpoint + query params)
/// - Request configuration (headers, body format, model selection)
/// - Response parsing (provider-specific JSON → unified TranscriptSegment)
///
/// The anarlog `owhisper-client` has adapters for 17 providers:
/// OpenAI, Deepgram, AssemblyAI, Gladia, ElevenLabs, Mistral, Fireworks,
/// Soniox, AquaVoice, DashScope, PyAnnote, WhisperCPP, SmallestAI, Argmax,
/// DeepgramCompat, Hyprnote, and a generic HTTP adapter.
protocol STTAdapter: Sendable {
    /// Provider identifier (matches anarlog's adapter names).
    var providerID: String { get }
    var displayName: String { get }

    /// Build the URL for a transcription request.
    func buildURL(config: STTConfig) -> URL

    /// Build the URLRequest with headers, body, and method.
    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest

    /// Parse the provider's response into unified transcript segments.
    func parseResponse(_ data: Data) throws -> [STTWord]
}

// MARK: - Unified Types

/// Unified word from any STT provider.
struct STTWord: Codable, Sendable {
    let text: String
    let startMs: Double
    let endMs: Double
    let channel: Int
    let speakerIndex: Int?
}

/// Configuration for STT requests.
struct STTConfig {
    var model: String?
    var language: String?
    var apiKey: String
    var baseURL: String?
    var diarization: Bool = false
    var punctuate: Bool = true
}

// MARK: - Deepgram Adapter

struct DeepgramAdapter: STTAdapter {
    let providerID = "deepgram"
    let displayName = "Deepgram"

    func buildURL(config: STTConfig) -> URL {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "punctuate", value: "\(config.punctuate)"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        if let model = config.model {
            queryItems.append(URLQueryItem(name: "model", value: model))
        }
        if let lang = config.language {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        }
        if config.diarization {
            queryItems.append(URLQueryItem(name: "diarize", value: "true"))
        }
        components.queryItems = queryItems
        return components.url!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue("Token \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]] else {
            return []
        }
        var words: [STTWord] = []
        for (chIdx, channel) in channels.enumerated() {
            guard let alternatives = channel["alternatives"] as? [[String: Any]],
                  let alt = alternatives.first,
                  let rawWords = alt["words"] as? [[String: Any]] else { continue }
            for word in rawWords {
                words.append(STTWord(
                    text: word["punctuated_word"] as? String ?? word["word"] as? String ?? "",
                    startMs: (word["start"] as? Double ?? 0) * 1000,
                    endMs: (word["end"] as? Double ?? 0) * 1000,
                    channel: chIdx,
                    speakerIndex: word["speaker"] as? Int
                ))
            }
        }
        return words
    }
}

// MARK: - AssemblyAI Adapter

struct AssemblyAIAdapter: STTAdapter {
    let providerID = "assemblyai"
    let displayName = "AssemblyAI"

    func buildURL(config: STTConfig) -> URL {
        URL(string: "https://api.assemblyai.com/v2/transcript")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        // AssemblyAI uses two-step: upload → transcribe
        // First upload the audio
        var uploadReq = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue(config.apiKey, forHTTPHeaderField: "authorization")
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        uploadReq.httpBody = audioData
        // The actual transcription request is built after upload
        // This builds the initial upload request
        return uploadReq
    }

    func buildTranscribeRequest(audioURL: String, config: STTConfig) throws -> URLRequest {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "punctuate": config.punctuate
        ]
        if let model = config.model { body["speech_model"] = model }
        if let lang = config.language { body["language_code"] = lang }
        if config.diarization {
            body["speaker_labels"] = true
        }

        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let words = json?["words"] as? [[String: Any]] else { return [] }
        return words.map { word in
            STTWord(
                text: word["text"] as? String ?? "",
                startMs: word["start"] as? Double ?? 0,
                endMs: word["end"] as? Double ?? 0,
                channel: 0,
                speakerIndex: word["speaker"] as? Int
            )
        }
    }
}

// MARK: - Gladia Adapter

struct GladiaAdapter: STTAdapter {
    let providerID = "gladia"
    let displayName = "Gladia"

    func buildURL(config: STTConfig) -> URL {
        URL(string: "https://api.gladia.io/v2/transcription")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        // Gladia accepts multipart or direct audio URL
        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.language ?? "en")\r\n".data(using: .utf8)!)
        if config.diarization {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"diarization\"\r\n\r\n".data(using: .utf8)!)
            body.append("true\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = json?["result"] as? [String: Any],
              let transcription = result["transcription"] as? [String: Any],
              let utterances = transcription["utterances"] as? [[String: Any]] else {
            return []
        }
        var words: [STTWord] = []
        for utterance in utterances {
            guard let rawWords = utterance["words"] as? [[String: Any]] else { continue }
            let speakerIdx = utterance["speaker"] as? Int
            for word in rawWords {
                words.append(STTWord(
                    text: word["word"] as? String ?? "",
                    startMs: word["start"] as? Double ?? 0,
                    endMs: word["end"] as? Double ?? 0,
                    channel: speakerIdx ?? 0,
                    speakerIndex: speakerIdx
                ))
            }
        }
        return words
    }
}

// MARK: - ElevenLabs Adapter (Scribe)

struct ElevenLabsAdapter: STTAdapter {
    let providerID = "elevenlabs"
    let displayName = "ElevenLabs Scribe"

    func buildURL(config: STTConfig) -> URL {
        URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let words = json?["words"] as? [[String: Any]] else { return [] }
        return words.map { word in
            STTWord(
                text: word["text"] as? String ?? "",
                startMs: (word["start"] as? Double ?? 0) * 1000,
                endMs: (word["end"] as? Double ?? 0) * 1000,
                channel: 0,
                speakerIndex: word["speaker_id"] as? Int
            )
        }
    }
}

// MARK: - Mistral Adapter

struct MistralSTTAdapter: STTAdapter {
    let providerID = "mistral"
    let displayName = "Mistral"

    func buildURL(config: STTConfig) -> URL {
        URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.model ?? "mistral-large")\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Mistral returns full text or segmented
        if let segments = json?["segments"] as? [[String: Any]] {
            return segments.map { seg in
                STTWord(
                    text: seg["text"] as? String ?? "",
                    startMs: (seg["start"] as? Double ?? 0) * 1000,
                    endMs: (seg["end"] as? Double ?? 0) * 1000,
                    channel: 0,
                    speakerIndex: nil
                )
            }
        }
        // Fallback: single text
        let text = json?["text"] as? String ?? ""
        return [STTWord(text: text, startMs: 0, endMs: 0, channel: 0, speakerIndex: nil)]
    }
}

// MARK: - Adapter Registry

/// Registry of all available STT adapters, matching anarlog's owhisper-client catalog.
@MainActor
final class STTAdapterRegistry {
    static let shared = STTAdapterRegistry()

    private let logger = Logger(subsystem: "com.wawa.note", category: "STTAdapters")

    private let adapters: [String: any STTAdapter] = [
        "deepgram": DeepgramAdapter(),
        "assemblyai": AssemblyAIAdapter(),
        "gladia": GladiaAdapter(),
        "elevenlabs": ElevenLabsAdapter(),
        "mistral": MistralSTTAdapter(),
        // OpenAI Whisper is handled by the existing RemoteTranscriptionEngine
        // These providers below share OpenAI-compatible APIs:
        "openai": OpenAISTTAdapter(),
        "fireworks": OpenAICompatibleSTTAdapter(providerID: "fireworks",
            baseURL: "https://api.fireworks.ai/inference/v1"),
        "soniox": OpenAICompatibleSTTAdapter(providerID: "soniox",
            baseURL: "https://api.soniox.com/v1"),
        "aquavoice": OpenAICompatibleSTTAdapter(providerID: "aquavoice",
            baseURL: "https://api.aquavoice.io/v1"),
        "smallestai": OpenAICompatibleSTTAdapter(providerID: "smallestai",
            baseURL: "https://api.smallest.ai/v1"),
    ]

    func adapter(for providerID: String) -> (any STTAdapter)? {
        adapters[providerID]
    }

    var allProviderIDs: [String] { Array(adapters.keys).sorted() }
    var allDisplayNames: [(id: String, name: String)] {
        adapters.map { ($0.key, $0.value.displayName) }.sorted(by: { $0.name < $1.name })
    }
}

// MARK: - OpenAI-compatible STT Adapter

private struct OpenAISTTAdapter: STTAdapter {
    let providerID = "openai"
    let displayName = "OpenAI Whisper"

    func buildURL(config: STTConfig) -> URL {
        URL(string: "\(config.baseURL ?? "https://api.openai.com/v1")/audio/transcriptions")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        var request = URLRequest(url: buildURL(config: config))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.model ?? "whisper-1")\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)
        if let lang = config.language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(WhisperVerboseResponse.self, from: data)
        return response.words?.map { w in
            STTWord(text: w.word, startMs: w.start * 1000, endMs: w.end * 1000, channel: 0, speakerIndex: nil)
        } ?? [STTWord(text: response.text ?? "", startMs: 0, endMs: 0, channel: 0, speakerIndex: nil)]
    }

    private struct WhisperVerboseResponse: Codable {
        let text: String?
        let words: [WhisperWord]?

        struct WhisperWord: Codable {
            let word: String
            let start: Double
            let end: Double
        }
    }
}

/// Generic adapter for OpenAI-compatible STT APIs (Fireworks, Soniox, AquaVoice, SmallestAI, etc.)
private struct OpenAICompatibleSTTAdapter: STTAdapter {
    let providerID: String
    let displayName: String
    let baseURL: String

    init(providerID: String, baseURL: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.displayName = providerID.capitalized
    }

    func buildURL(config: STTConfig) -> URL {
        URL(string: "\(config.baseURL ?? baseURL)/audio/transcriptions")!
    }

    func buildRequest(audioData: Data, config: STTConfig) throws -> URLRequest {
        // Delegate to OpenAI adapter's format
        let openAI = OpenAISTTAdapter()
        return try openAI.buildRequest(audioData: audioData, config: STTConfig(
            model: config.model, language: config.language,
            apiKey: config.apiKey, baseURL: config.baseURL ?? baseURL,
            diarization: config.diarization, punctuate: config.punctuate
        ))
    }

    func parseResponse(_ data: Data) throws -> [STTWord] {
        let openAI = OpenAISTTAdapter()
        return try openAI.parseResponse(data)
    }
}
