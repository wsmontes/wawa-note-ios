import SwiftUI
import SwiftData

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = RecordingViewModel()
    var onMeetingSaved: ((MeetingModel) -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                statusBadge

                timerView

                if viewModel.state == .stopped {
                    playbackControls
                } else {
                    audioLevelMeter
                }

                if viewModel.state == .recording {
                    markImportantButton
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if viewModel.savedMeetingId != nil && viewModel.state == .stopped {
                    VStack(spacing: 8) {
                        AppStatusBadge(title: "Saved", systemImage: "checkmark", tone: .success)
                        Text("Meeting saved. Audio recorded.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                controls

                Spacer()
            }
            .navigationTitle(viewModel.state == .idle ? "Record" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.state == .idle || viewModel.state == .stopped {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .onAppear {
                viewModel.setModelContext(modelContext)
            }
        }
    }

    // MARK: - Mark Important

    private var markImportantButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            viewModel.markImportant()
        } label: {
            Label("Mark Important", systemImage: "bookmark.fill")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .tint(.yellow)
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.state {
        case .idle:
            AppStatusBadge(title: "Ready", systemImage: "mic", tone: .neutral)
        case .recording:
            AppStatusBadge(title: "Recording", systemImage: "record.circle", tone: .recording)
        case .paused:
            AppStatusBadge(title: "Paused", systemImage: "pause.circle", tone: .warning)
        case .stopped:
            AppStatusBadge(title: "Stopped", systemImage: "stop.circle", tone: .neutral)
        }
    }

    // MARK: - Timer

    private var timerView: some View {
        Text(viewModel.elapsedTimeFormatted)
            .font(.system(size: 52, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(viewModel.state == .recording ? .red : .primary)
    }

    // MARK: - Audio level

    private var audioLevelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<20, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
            }
        }
        .frame(height: 40)
        .opacity(viewModel.state == .recording || viewModel.state == .paused ? 1 : 0.3)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / 20.0
        let active = viewModel.audioLevel > threshold
        if !active { return .secondary.opacity(0.3) }
        if threshold > 0.75 { return .red }
        if threshold > 0.45 { return .orange }
        return .green
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 8
        let max: CGFloat = 36
        let threshold = Float(index) / 20.0
        let scale = viewModel.audioLevel > threshold ? 1.0 : 0.3
        return base + (max - base) * CGFloat(scale)
    }

    // MARK: - Playback

    private var playbackControls: some View {
        VStack(spacing: 12) {
            Text(viewModel.playbackTimeFormatted)
                .font(.title2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                if viewModel.isPlaying {
                    Button {
                        viewModel.pausePlayback()
                    } label: {
                        Label("Pause", systemImage: "pause.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        viewModel.stopPlayback()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        viewModel.startPlayback()
                    } label: {
                        Label("Play", systemImage: "play.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch viewModel.state {
        case .idle:
            PrimaryActionButton(
                title: "Start Recording",
                systemImage: "record.circle.fill"
            ) {
                viewModel.startRecording()
            }
            .padding(.horizontal, 32)
            .tint(.red)

        case .recording:
            HStack(spacing: 24) {
                Button {
                    viewModel.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .paused:
            HStack(spacing: 24) {
                Button {
                    viewModel.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "record.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
            }

        case .stopped:
            VStack(spacing: 12) {
                if let meetingId = viewModel.savedMeetingId {
                    PrimaryActionButton(
                        title: "View Meeting",
                        systemImage: "arrow.right"
                    ) {
                        let descriptor = FetchDescriptor<MeetingModel>(predicate: #Predicate { $0.id == meetingId })
                        if let meeting = try? modelContext.fetch(descriptor).first {
                            onMeetingSaved?(meeting)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
    }
}

#Preview {
    RecordView()
}
