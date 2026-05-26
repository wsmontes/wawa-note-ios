import Foundation

struct JSONExporter: Sendable {

    func export(
        meeting: MeetingModel,
        transcript: Transcript?,
        analysis: MeetingAnalysis?
    ) throws -> Data {
        let export = MeetingExport(
            title: meeting.title,
            createdAt: meeting.createdAt,
            durationSeconds: meeting.durationSeconds,
            status: meeting.status.rawValue,
            transcript: transcript,
            analysis: analysis
        )
        return try JSONEncoder().encode(export)
    }
}

private struct MeetingExport: Encodable {
    let title: String
    let createdAt: Date
    let durationSeconds: Double?
    let status: String
    let transcript: Transcript?
    let analysis: MeetingAnalysis?
}
