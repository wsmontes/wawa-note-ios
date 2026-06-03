import AVFoundation
import OSLog

enum AudioPlaybackState {
    case idle
    case playing
    case paused
    case finished
}

enum AudioPlaybackError: Error {
    case fileNotFound
    case playerCreationFailed
}

final class AudioPlaybackService: NSObject, ObservableObject, @unchecked Sendable {
    private var player: AVAudioPlayer?
    @Published private(set) var state: AudioPlaybackState = .idle
    @Published private(set) var currentTime: TimeInterval = 0

    private var timer: Timer?

    func load(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileNotFound
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            state = .idle
            currentTime = 0
            AppLog.audio.info("Playback loaded: \(url.lastPathComponent)")
        } catch {
            AppLog.audio.error("Failed to create player: \(error.localizedDescription)")
            throw AudioPlaybackError.playerCreationFailed
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        state = .playing
        startTimer()
        AppLog.audio.info("Playback started")
    }

    func pause() {
        player?.pause()
        state = .paused
        timer?.invalidate()
        AppLog.audio.info("Playback paused")
    }

    func resume() {
        player?.play()
        state = .playing
        startTimer()
        AppLog.audio.info("Playback resumed")
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        state = .idle
        currentTime = 0
        timer?.invalidate()
        AppLog.audio.info("Playback stopped")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            DispatchQueue.main.async { self.currentTime = player.currentTime }
        }
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate()
        state = .finished
        currentTime = player.duration
        AppLog.audio.info("Playback finished (success: \(flag))")
    }
}
