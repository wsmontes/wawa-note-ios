import SwiftUI
import SwiftData
import EventKit
import Contacts
import UniformTypeIdentifiers

// MARK: - Send To Action

enum SendToDestination: String, CaseIterable {
    case reminders = "Reminders"
    case calendar = "Calendar"
    case contacts = "Contacts"
    case markdown = "Markdown"
    case pdf = "PDF"
    case csv = "CSV"
    case share = "Share"
}

/// Unified export context menu builder.
/// Determines available destinations based on the item type.
struct SendToMenu: View {
    let item: UnifiedItem
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Menu {
            ForEach(availableDestinations, id: \.rawValue) { dest in
                Button { execute(dest) } label: {
                    Label(dest.rawValue, systemImage: icon(for: dest))
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var availableDestinations: [SendToDestination] {
        switch item {
        case .knowledge:
            return [.share, .markdown, .pdf]
        case .derived(let di):
            switch di.type {
            case .task:
                return [.reminders, .calendar, .share]
            case .synthesis:
                return [.markdown, .pdf, .share]
            case .signal:
                return [.reminders, .calendar, .share]
            case .connection:
                return [.share]
            case .decision, .question:
                return [.share]
            }
        }
    }

    private func icon(for dest: SendToDestination) -> String {
        switch dest {
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .contacts: "person.crop.circle"
        case .markdown: "doc.richtext"
        case .pdf: "doc.text"
        case .csv: "tablecells"
        case .share: "square.and.arrow.up"
        }
    }

    private func execute(_ dest: SendToDestination) {
        switch dest {
        case .reminders: exportToReminders()
        case .calendar: exportToCalendar()
        case .contacts: exportToContacts()
        case .markdown: exportMarkdown()
        case .pdf: exportPDF()
        case .csv: exportCSV()
        case .share: shareItem()
        }
    }

    // MARK: - Export implementations

    private func exportToReminders() {
        guard case .derived(let derived) = item, derived.type == .task else { return }
        let eventStore = EKEventStore()
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                guard granted else { return }
                let reminder = EKReminder(eventStore: eventStore)
                reminder.title = derived.title
                if let due = derived.dueAt {
                    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
                }
                reminder.calendar = eventStore.defaultCalendarForNewReminders()
                try eventStore.save(reminder, commit: true)
                AppLog.general.info("SendTo: task exported to Reminders: \(derived.title)")
            } catch {
                AppLog.general.error("SendTo: Reminders export failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportToCalendar() {
        guard case .derived(let derived) = item, derived.type == .task, let dueAt = derived.dueAt else { return }
        let eventStore = EKEventStore()
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                guard granted else { return }
                let event = EKEvent(eventStore: eventStore)
                event.title = derived.title
                event.startDate = dueAt
                event.endDate = dueAt.addingTimeInterval(3600)
                event.calendar = eventStore.defaultCalendarForNewEvents
                try eventStore.save(event, span: .thisEvent, commit: true)
                AppLog.general.info("SendTo: task exported to Calendar: \(derived.title)")
            } catch {
                AppLog.general.error("SendTo: Calendar export failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportToContacts() {
        guard case .derived(let derived) = item else { return }
        let contact = CNMutableContact()
        contact.givenName = derived.title
        let store = CNContactStore()
        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(saveRequest)
            AppLog.general.info("SendTo: contact exported: \(derived.title)")
        } catch {
            AppLog.general.error("SendTo: Contacts export failed: \(error.localizedDescription)")
        }
    }

    private func exportMarkdown() {
        var md = ""
        switch item {
        case .knowledge(let ki):
            md = "# \(ki.title)\n\nType: \(ki.type.label)\nCreated: \(ki.createdAt.formatted())\n"
            // Attempt to read analysis artifact if present
            let store = FileArtifactStore()
            let analysisURL = store.meetingDirectoryURL(for: ki.id).appendingPathComponent("analysis.json")
            if FileManager.default.fileExists(atPath: analysisURL.path),
               let data = try? Data(contentsOf: analysisURL),
               let analysisStr = String(data: data, encoding: .utf8) {
                md += "\n## Analysis\n\n```json\n\(analysisStr)\n```\n"
            }
        case .derived(let di):
            md = "# \(di.title)\n\nType: \(di.type.rawValue)\n"
            if let body = di.bodyJSON {
                md += "\n\(body)\n"
            }
        }
        presentShareSheet(md, type: .plainText)
    }

    private func exportPDF() {
        // Render synthesis or item content as PDF using UIGraphicsPDFRenderer
        // Deferred to implementation — requires PDF rendering pipeline
        let text = "PDF export placeholder"
        presentShareSheet(text, type: .plainText)
    }

    private func exportCSV() {
        // Export collection as CSV
        var csv = "Type,Title,Status,Created\n"
        switch item {
        case .derived(let di):
            csv += "\(di.type.rawValue),\"\(di.title)\",\(di.statusRaw ?? ""),\(di.createdAt.ISO8601Format())\n"
        case .knowledge(let ki):
            csv += "\(ki.type.rawValue),\"\(ki.title)\",,\(ki.createdAt.ISO8601Format())\n"
        }
        presentShareSheet(csv, type: .commaSeparatedText)
    }

    private func shareItem() {
        var text = ""
        switch item {
        case .knowledge(let ki): text = ki.title
        case .derived(let di): text = di.title
        }
        presentShareSheet(text, type: .plainText)
    }

    private func presentShareSheet(_ content: String, type: UTType) {
        let tempDir = FileManager.default.temporaryDirectory
        let ext: String
        if type == .commaSeparatedText {
            ext = "csv"
        } else if type == .plainText {
            ext = "md"
        } else {
            ext = "txt"
        }
        let fileURL = tempDir.appendingPathComponent("wawa-export-\(UUID().uuidString.prefix(8)).\(ext)")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)

        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
}
