import Foundation
// Related JIRA: KAN-12, KAN-64


/// Exports a single KnowledgeItem as complete JSON using ItemExportFull from InstanceExportService.
@MainActor
struct JSONExporter: Sendable {

    /// Legacy signature — kept for backward compatibility. The transcript and analysis
    /// parameters are ignored; the exporter reads them from disk via InstanceExportService.
    func export(
        item: KnowledgeItem,
        transcript: Transcript? = nil,
        analysis: MeetingAnalysis? = nil
    ) throws -> Data {
        let full = InstanceExportService().buildItemExport(item: item)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(full)
    }
}
