import Foundation
import EventKit
import OSLog

@MainActor
final class TaskRemindersService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func requestPermission() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToReminders()
        } catch {
            AppLog.general.error("Reminders permission failed: \(error.localizedDescription)")
            return false
        }
    }

    func exportTask(_ task: TaskItem) async throws {
        guard try await requestPermission() else {
            throw RemindersError.permissionDenied
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = task.title

        if let due = task.dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
        }

        reminder.priority = mapPriority(task.priority)

        if let notes = buildNotes(for: task) {
            reminder.notes = notes
        }

        // Default calendar
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        try eventStore.save(reminder, commit: true)
        AppLog.general.info("Exported task '\(task.title)' to Reminders")
    }

    func exportTasks(_ tasks: [TaskItem]) async -> (exported: Int, failed: Int) {
        guard let _ = try? await requestPermission() else {
            return (0, tasks.count)
        }

        var exported = 0
        var failed = 0

        for task in tasks {
            do {
                try await exportTask(task)
                exported += 1
            } catch {
                AppLog.general.error("Failed to export task '\(task.title)': \(error)")
                failed += 1
            }
        }

        return (exported, failed)
    }

    private func mapPriority(_ p: TaskPriority) -> Int {
        switch p {
        case .low: return 0
        case .medium: return 5
        case .high: return 7
        case .critical: return 9
        }
    }

    private func buildNotes(for task: TaskItem) -> String? {
        var parts: [String] = []
        if let owner = task.ownerName { parts.append("Owner: \(owner)") }
        if let source = task.sourceItemID { parts.append("Source: wawanote://item/\(source.uuidString.prefix(8))") }
        parts.append("Exported by Wawa Note")
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

enum RemindersError: Error, LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Reminders access is off. Enable in Settings."
        }
    }
}
