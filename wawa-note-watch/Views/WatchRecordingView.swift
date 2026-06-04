import SwiftUI

struct WatchRecordingView: View {
    @EnvironmentObject private var sessionManager: WatchSessionManager

    private var status: RecordingStatus {
        sessionManager.recordingStatus
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            statusIcon
            timerText
            audioLevelMeter

            if let error = status.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            controls

            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Status icon

    private var statusIcon: some View {
        Group {
            switch status.state {
            case "recording":
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            case "paused", "interrupted":
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
            case "stopped":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            default:
                Image(systemName: "mic.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title2)
    }

    // MARK: - Timer

    private var timerText: some View {
        Text(formatTime(status.elapsedTime))
            .font(.system(size: 36, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(status.state == "recording" ? .red : status.state == "interrupted" ? .orange : .primary)
    }

    // MARK: - Audio level meter

    private var audioLevelMeter: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(barColor(for: i))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .frame(height: 20)
        .opacity(status.isActive ? 1 : 0.3)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / 8.0
        let active = status.audioLevel > threshold
        if !active { return .secondary.opacity(0.3) }
        if threshold > 0.65 { return .red }
        if threshold > 0.35 { return .orange }
        return .green
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index) / 8.0
        let scale: CGFloat = status.audioLevel > threshold ? 1.0 : 0.3
        return 4 + (16 - 4) * scale
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch status.state {
        case "idle":
            Button {
                sessionManager.sendCommand(.startRecording)
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .tint(.red)

        case "recording":
            HStack(spacing: 12) {
                Button {
                    sessionManager.sendCommand(.pauseRecording)
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.title3)
                }
                .tint(.orange)

                Button {
                    sessionManager.sendCommand(.stopRecording)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                }
                .tint(.red)
            }

        case "paused", "interrupted":
            HStack(spacing: 12) {
                Button {
                    sessionManager.sendCommand(.resumeRecording)
                } label: {
                    Image(systemName: "record.circle.fill")
                        .font(.title3)
                }
                .tint(.orange)

                Button {
                    sessionManager.sendCommand(.stopRecording)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                }
                .tint(.red)
            }

        case "stopped":
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
