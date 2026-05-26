import Foundation

protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript
}
