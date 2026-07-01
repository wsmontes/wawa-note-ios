import EventKit
import WawaNoteCore
import Foundation
import OSLog

enum RemindersExportResult {
  case success(exported: Int)
  case partial(exported: Int, failed: Int)
  case permissionDenied
  case noRemindersAccount
  case allFailed

  var message: String {
    switch self {
    case .success(let exported):
      return "\(exported) task\(exported == 1 ? "" : "s") sent to Reminders."
    case .partial(let exported, let failed):
      return
        "\(exported) exported, \(failed) failed.\n\nCheck Settings > Privacy & Security > Reminders."
    case .permissionDenied:
      return
        "Reminders access is off.\n\nGo to Settings > Privacy & Security > Reminders and enable access for Wawa Note."
    case .noRemindersAccount:
      return
        "No Reminders account found.\n\nOpen the Reminders app to set up an account, then try again."
    case .allFailed:
      return "Could not export tasks.\n\nCheck Settings > Privacy & Security > Reminders."
    }
  }

  var needsSettingsButton: Bool {
    switch self {
    case .permissionDenied, .allFailed: return true
    default: return false
    }
  }
}

@MainActor
final class TaskRemindersService {
  private let eventStore: EKEventStore

  init(eventStore: EKEventStore = .shared) {
    self.eventStore = eventStore
  }

  func requestPermission() async -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .fullAccess || status == .authorized {
      return true
    }
    if status == .denied || status == .restricted {
      return false
    }
    do {
      return try await eventStore.requestFullAccessToReminders()
    } catch {
      AppLog.general.error("Reminders permission failed: \(error.localizedDescription)")
      return false
    }
  }

  func exportTasks(_ tasks: [TaskItem]) async -> RemindersExportResult {
    guard await requestPermission() else {
      return .permissionDenied
    }

    // Find a calendar — prefer default, fall back to any available
    let calendar: EKCalendar
    if let defaultCal = eventStore.defaultCalendarForNewReminders() {
      calendar = defaultCal
    } else if let anyCal = eventStore.calendars(for: .reminder).first {
      calendar = anyCal
    } else {
      AppLog.general.error("No Reminders calendar available — user needs to set up an account")
      return .noRemindersAccount
    }

    var exported = 0
    var failed = 0

    for task in tasks {
      do {
        try await exportTask(task, calendar: calendar)
        exported += 1
      } catch {
        AppLog.general.error("Failed to export task '\(task.title)': \(error)")
        failed += 1
      }
    }

    if exported > 0 && failed == 0 {
      return .success(exported: exported)
    } else if exported > 0 {
      return .partial(exported: exported, failed: failed)
    } else {
      return .allFailed
    }
  }

  private func exportTask(_ task: TaskItem, calendar: EKCalendar) async throws {
    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = task.title

    if let due = task.dueAt {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day], from: due)
    }

    reminder.priority = mapPriority(task.priority)

    if let notes = buildNotes(for: task) {
      reminder.notes = notes
    }

    reminder.calendar = calendar

    try eventStore.save(reminder, commit: true)
    AppLog.general.info("Exported task '\(task.title)' to Reminders")
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
    if let source = task.sourceItemID {
      parts.append("Source: wawanote://item/\(source.uuidString.prefix(8))")
    }
    parts.append("Exported by Wawa Note")
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }
}

enum RemindersError: Error, LocalizedError {
  case permissionDenied
  case noDefaultCalendar

  var errorDescription: String? {
    switch self {
    case .permissionDenied: return "Reminders access is off. Enable in Settings."
    case .noDefaultCalendar: return "No Reminders account configured. Add one in the Reminders app."
    }
  }
}
