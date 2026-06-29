import AVFoundation
import SwiftUI

// MARK: - Reusable Audio Player View

/// Polished, reusable audio player. Use it anywhere you need to play an .m4a file.
/// Features: play/pause, seek slider, time display, skip buttons, waveform bar.
struct AudioPlayerView: View {
    @StateObject private var service = AudioPlaybackService()
    let audioURL: URL
    let title: String
    let compact: Bool

    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    init(audioURL: URL, title: String = "", compact: Bool = false) {
        self.audioURL = audioURL
        self.title = title
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            // Title
            if !title.isEmpty {
                Text(title)
                    .font(compact ? .caption : .subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if compact {
                compactLayout
            } else {
                fullLayout
            }
        }
        .padding(compact ? 10 : 14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { try? service.load(url: audioURL) }
        .onDisappear { service.unload() }
    }

    // MARK: - Full Layout

    private var fullLayout: some View {
        VStack(spacing: 10) {
            // Progress slider
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : service.progress },
                        set: { v in
                            seekValue = v
                            isSeeking = true
                        }
                    ),
                    onEditingChanged: { editing in
                        if !editing {
                            service.seek(to: seekValue * service.duration)
                            isSeeking = false
                        }
                    }
                )
                .tint(.purple)

                HStack {
                    Text(isSeeking ? formatTime(seekValue * service.duration) : formatTime(service.currentTime))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(formatTime(service.duration))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }

            // Controls
            HStack(spacing: 24) {
                // Skip back 15s
                Button {
                    service.seek(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .opacity(service.duration > 0 ? 1 : 0.3)
                .disabled(service.duration == 0)

                // Play/Pause
                Button {
                    service.togglePlayPause()
                } label: {
                    Image(systemName: playIcon)
                        .font(.system(size: 36))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)

                // Skip forward 15s
                Button {
                    service.seek(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .opacity(service.duration > 0 ? 1 : 0.3)
                .disabled(service.duration == 0)
            }
        }
    }

    // MARK: - Compact Layout

    private var compactLayout: some View {
        HStack(spacing: 8) {
            // Play/Pause
            Button {
                service.togglePlayPause()
            } label: {
                Image(systemName: playIcon)
                    .font(.title2)
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(.systemFill))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.purple)
                        .frame(width: geo.size.width * service.progress, height: 4)
                        .animation(.linear(duration: 0.1), value: service.progress)
                }
                .frame(height: 4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            service.seek(to: p * service.duration)
                        }
                )
            }
            .frame(height: 4)

            // Time
            Text(formatTime(service.currentTime))
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private var playIcon: String {
        switch service.state {
        case .playing: return "pause.fill"
        case .finished: return "arrow.counterclockwise"
        default: return "play.fill"
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "--:--" }
        let min = Int(t) / 60
        let sec = Int(t) % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - Audio Player Sheet (for modal presentation)

struct AudioPlayerSheet: View {
    let audioURL: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer().frame(height: 20)

                // Waveform icon
                Image(systemName: "waveform")
                    .font(.system(size: 60))
                    .foregroundStyle(.purple)
                    .padding(.bottom, 8)

                AudioPlayerView(audioURL: audioURL, title: title)
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Audio Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
