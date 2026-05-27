import WidgetKit
import SwiftUI

struct RecordingComplication: Widget {
    let kind = "RecordingComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ComplicationRouter(entry: entry)
        }
        .configurationDisplayName("Recording Status")
        .description("Shows if a recording is in progress.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

// MARK: - Router

private struct ComplicationRouter: View {
    @Environment(\.widgetFamily) var family
    let entry: ComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryCorner:
            CornerComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        @unknown default:
            Image(systemName: "mic.circle.fill")
        }
    }
}

// MARK: - Provider

struct Provider: TimelineProvider {
    typealias Entry = ComplicationEntry

    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), state: "idle", elapsedTime: 0, isActive: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        let entry = readSharedDefaults()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = readSharedDefaults()
        let refresh = entry.isActive
            ? Date().addingTimeInterval(15)
            : Date().addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(refresh))
        completion(timeline)
    }

    private func readSharedDefaults() -> ComplicationEntry {
        let shared = UserDefaults(suiteName: "group.com.wawa-note")
        return ComplicationEntry(
            date: Date(),
            state: shared?.string(forKey: "recordingState") ?? "idle",
            elapsedTime: shared?.double(forKey: "elapsedTime") ?? 0,
            isActive: shared?.bool(forKey: "isActive") ?? false
        )
    }
}

// MARK: - Entry

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let state: String
    let elapsedTime: Double
    let isActive: Bool

    var stateIcon: String {
        switch state {
        case "recording": return "record.circle.fill"
        case "paused": return "pause.circle.fill"
        case "stopped": return "checkmark.circle.fill"
        default: return "mic.circle.fill"
        }
    }

    var tintColor: Color {
        switch state {
        case "recording": return .red
        case "paused": return .orange
        case "stopped": return .green
        default: return .secondary
        }
    }
}

// MARK: - Complication Views

private struct CircularComplicationView: View {
    let entry: ComplicationEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.stateIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(entry.tintColor)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct CornerComplicationView: View {
    let entry: ComplicationEntry

    var body: some View {
        if entry.isActive {
            Text("REC")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.red)
                .widgetLabel(label: {
                    Text(formatShortTime(entry.elapsedTime))
                })
        } else {
            Image(systemName: entry.stateIcon)
                .foregroundStyle(entry.tintColor)
                .widgetLabel(label: { Text("Wawa") })
        }
    }
}

private struct RectangularComplicationView: View {
    let entry: ComplicationEntry

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: entry.stateIcon)
                .foregroundStyle(entry.tintColor)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.isActive ? "Recording" : "Wawa Note")
                    .font(.headline)
                    .lineLimit(1)
                if entry.isActive {
                    Text(formatShortTime(entry.elapsedTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private func formatShortTime(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}
