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
  @Published private(set) var duration: TimeInterval = 0

  private var timer: Timer?

  /// Progress from 0.0 to 1.0
  var progress: Double {
    guard duration > 0 else { return 0 }
    return min(1.0, max(0.0, currentTime / duration))
  }

  /// Formatted "MM:SS / MM:SS" string
  var timeDisplay: String {
    "\(formatTime(currentTime)) / \(formatTime(duration))"
  }

  func load(url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AudioPlaybackError.fileNotFound
    }
    // Configure audio session for playback
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    try? session.setActive(true)

    do {
      player = try AVAudioPlayer(contentsOf: url)
      player?.delegate = self
      player?.prepareToPlay()
      state = .idle
      currentTime = 0
      duration = player?.duration ?? 0
      AppLog.audio.info(
        "Playback loaded: \(url.lastPathComponent) (\(self.formatTime(self.duration)))")
    } catch {
      AppLog.audio.error("Failed to create player: \(error.localizedDescription)")
      throw AudioPlaybackError.playerCreationFailed
    }
  }

  func play() {
    guard let player else { return }
    if state == .finished {
      player.currentTime = 0
      currentTime = 0
    }
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

  /// Seek to a specific time in seconds.
  func seek(to time: TimeInterval) {
    guard let player else { return }
    let target = max(0, min(time, player.duration))
    player.currentTime = target
    currentTime = target
    // Restart playback if was playing
    if state == .playing {
      player.play()
    }
  }

  /// Seek by a relative amount in seconds.
  func seek(by delta: TimeInterval) {
    seek(to: currentTime + delta)
  }

  /// Toggle between play and pause.
  func togglePlayPause() {
    switch state {
    case .idle, .paused, .finished: play()
    case .playing: pause()
    }
  }

  func unload() {
    timer?.invalidate()
    timer = nil
    player?.stop()
    player = nil
    state = .idle
    currentTime = 0
    duration = 0
    try? AVAudioSession.sharedInstance().setActive(false)
  }

  // MARK: - Private

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, let player = self.player else { return }
      Task { @MainActor in
        self.currentTime = player.currentTime
      }
    }
  }

  private func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "--:--" }
    let min = Int(t) / 60
    let sec = Int(t) % 60
    return String(format: "%d:%02d", min, sec)
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
