import MediaPlayer
import OSLog

final class NowPlayingController {
    private let remoteCommand: MPRemoteCommandCenter
    private let nowPlayingInfo: MPNowPlayingInfoCenter

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?

    init(
        remoteCommand: MPRemoteCommandCenter = .shared(),
        nowPlayingInfo: MPNowPlayingInfoCenter = .default()
    ) {
        self.remoteCommand = remoteCommand
        self.nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Activate / Deactivate

    func activate() {
        remoteCommand.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        }
        remoteCommand.playCommand.isEnabled = true

        remoteCommand.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }
        remoteCommand.pauseCommand.isEnabled = true

        remoteCommand.stopCommand.addTarget { [weak self] _ in
            self?.onStop?()
            return .success
        }
        remoteCommand.stopCommand.isEnabled = true

        remoteCommand.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?()
            return .success
        }
        remoteCommand.togglePlayPauseCommand.isEnabled = true

        // Disable irrelevant commands so they don't show on lock screen.
        remoteCommand.nextTrackCommand.isEnabled = false
        remoteCommand.previousTrackCommand.isEnabled = false
        remoteCommand.changePlaybackPositionCommand.isEnabled = false
        remoteCommand.seekForwardCommand.isEnabled = false
        remoteCommand.seekBackwardCommand.isEnabled = false
        remoteCommand.skipForwardCommand.isEnabled = false
        remoteCommand.skipBackwardCommand.isEnabled = false
        remoteCommand.changeRepeatModeCommand.isEnabled = false
        remoteCommand.changeShuffleModeCommand.isEnabled = false
        remoteCommand.ratingCommand.isEnabled = false
        remoteCommand.likeCommand.isEnabled = false
        remoteCommand.dislikeCommand.isEnabled = false
        remoteCommand.bookmarkCommand.isEnabled = false

        AppLog.audio.info("NowPlaying controller activated (lock screen controls enabled)")
    }

    func deactivate() {
        // Remove all targets — each addTarget was for a fresh block, so
        // calling removeTarget(nil) clears them all.
        remoteCommand.playCommand.removeTarget(nil)
        remoteCommand.pauseCommand.removeTarget(nil)
        remoteCommand.stopCommand.removeTarget(nil)
        remoteCommand.togglePlayPauseCommand.removeTarget(nil)

        remoteCommand.playCommand.isEnabled = false
        remoteCommand.pauseCommand.isEnabled = false
        remoteCommand.stopCommand.isEnabled = false
        remoteCommand.togglePlayPauseCommand.isEnabled = false

        nowPlayingInfo.nowPlayingInfo = nil

        AppLog.audio.info("NowPlaying controller deactivated")
    }

    // MARK: - Now Playing Info

    func update(title: String, elapsedTime: TimeInterval, isPlaying: Bool) {
        let formatted = formatTime(elapsedTime)
        let duration = max(elapsedTime, 1.0)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: isPlaying ? "Gravando" : "Pausado",
            MPMediaItemPropertyAlbumTitle: formatted,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPMediaItemPropertyPlaybackDuration: duration,
        ]

        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        nowPlayingInfo.nowPlayingInfo = info
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(max(0, interval))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
