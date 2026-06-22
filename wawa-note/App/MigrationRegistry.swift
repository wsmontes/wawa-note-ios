import Foundation
import SwiftData

/// Centralized registry for data migrations. Tracks which migrations have run
/// via a plist file (not UserDefaults) with version, date, and success status.
@MainActor
final class MigrationRegistry {

    /// Single migration definition.
    struct Migration: Identifiable {
        let id: String        // Unique key, e.g. "v1_meeting_to_audio"
        let version: Int      // Ordering — lower runs first
        let run: @MainActor (ModelContext) throws -> Void
    }

    /// Persisted record of a completed migration.
    struct Record: Codable {
        let id: String
        let version: Int
        let appliedAt: Date
        let success: Bool
        let errorMessage: String?
    }

    private static let plistName = "MigrationRegistry.plist"

    /// All registered migrations in order.
    static let migrations: [Migration] = [
        Migration(id: "v1_meeting_to_audio", version: 1) { context in
            KnowledgeItemService.migrateMeetingToAudio(context: context)
        },
        Migration(id: "v2_project_colors", version: 2) { context in
            ProjectService.migrateProjectColors(context: context)
        },
        Migration(id: "v3_field_provenance", version: 3) { context in
            ProjectService.migrateFieldProvenance(context: context)
        },
        Migration(id: "v4_to_project_derived", version: 4) { context in
            ProjectService.migrateToProjectDerivedItems(context: context)
        },
    ]

    /// Runs all pending migrations that haven't been applied yet.
    /// Each migration is wrapped in error isolation — a failure in one
    /// does not prevent subsequent migrations from attempting to run.
    static func runPendingMigrations(context: ModelContext) {
        let applied = loadRecords()
        let appliedIDs = Set(applied.map(\.id))
        let pending = migrations
            .filter { !appliedIDs.contains($0.id) }
            .sorted { $0.version < $1.version }

        guard !pending.isEmpty else { return }
        AppLog.general.info("MigrationRegistry: \(pending.count) pending migration(s)")

        var records = applied
        for migration in pending {
            let record: Record
            do {
                try migration.run(context)
                record = Record(id: migration.id, version: migration.version, appliedAt: Date(), success: true, errorMessage: nil)
                AppLog.general.info("MigrationRegistry: ✓ \(migration.id)")
            } catch {
                record = Record(id: migration.id, version: migration.version, appliedAt: Date(), success: false, errorMessage: error.localizedDescription)
                AppLog.warn("general", "MigrationRegistry: ✗ \(migration.id) — \(error.localizedDescription)")
            }
            records.append(record)
        }
        saveRecords(records)
    }

    /// Returns all migration records (for debugging / settings display).
    static func loadRecords() -> [Record] {
        guard let data = try? Data(contentsOf: plistURL),
              let records = try? PropertyListDecoder().decode([Record].self, from: data)
        else { return migrateLegacyFlags() }
        return records
    }

    /// Resets a specific migration so it will re-run on next launch.
    static func reset(migrationID: String) {
        var records = loadRecords()
        records.removeAll { $0.id == migrationID }
        saveRecords(records)
    }

    // MARK: - Private

    private static var plistURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(plistName)
    }

    private static func saveRecords(_ records: [Record]) {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListEncoder().encode(records) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    /// One-time: import existing UserDefaults flags into the plist registry.
    /// After this, the UserDefaults keys are ignored.
    private static func migrateLegacyFlags() -> [Record] {
        var records: [Record] = []
        let legacyMap: [(key: String, id: String, version: Int)] = [
            ("migration_meeting_to_audio_v1", "v1_meeting_to_audio", 1),
            ("migration_project_colors_v1", "v2_project_colors", 2),
            ("migration_field_provenance_v1", "v3_field_provenance", 3),
            ("migration_to_project_derived_v1", "v4_to_project_derived", 4),
        ]
        for entry in legacyMap {
            if UserDefaults.standard.bool(forKey: entry.key) {
                records.append(Record(id: entry.id, version: entry.version, appliedAt: Date.distantPast, success: true, errorMessage: nil))
            }
        }
        if !records.isEmpty {
            saveRecords(records)
            AppLog.general.info("MigrationRegistry: imported \(records.count) legacy flag(s)")
        }
        return records
    }
}
