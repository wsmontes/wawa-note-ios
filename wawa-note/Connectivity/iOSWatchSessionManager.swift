import OSLog
import WatchConnectivity

// Related JIRA: KAN-153

final class iOSWatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let coordinator: RecordingCoordinator
    private let session: WCSession

    init(
        coordinator: RecordingCoordinator,
        session: WCSession = .default
    ) {
        self.coordinator = coordinator
        self.session = session
        super.init()
        session.delegate = self
    }

    func activate() {
        guard WCSession.isSupported() else {
            AppLog.general.info("WCSession not supported on this device")
            return
        }
        session.activate()
        AppLog.general.info("WCSession activated on iOS")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator.onStatusChange = { [weak self] status in
                self?.sendStatus(status)
            }
            self.sendStatus(self.coordinator.currentStatus())
        }
    }

    // MARK: - Sending status

    private func sendStatus(_ status: RecordingStatus) {
        guard session.activationState == .activated else { return }

        let message: [String: Any] = [
            WatchMessageKey.type: "status",
            WatchMessageKey.state: status.state,
            WatchMessageKey.elapsedTime: status.elapsedTime,
            WatchMessageKey.audioLevel: status.audioLevel,
            WatchMessageKey.isActive: status.isActive,
            WatchMessageKey.recordingTitle: status.recordingTitle ?? NSNull(),
            WatchMessageKey.errorMessage: status.errorMessage ?? NSNull(),
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil)
        } else {
            do {
                try session.updateApplicationContext(message)
            } catch {
                AppLog.general.warning("WCSession updateApplicationContext failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            AppLog.general.error("WCSession activation failed: \(error.localizedDescription)")
        } else {
            AppLog.general.info("WCSession activated: \(activationState.rawValue)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sendStatus(self.coordinator.currentStatus())
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLog.general.info("WCSession did become inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        AppLog.general.info("WCSession did deactivate — reactivating")
        session.activate()
    }

    func session(_ wcSession: WCSession, didReceiveMessage message: [String: Any]) {
        guard let rawCommand = message[WatchMessageKey.command] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyCommand(rawCommand)
        }
    }

    func session(_ wcSession: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let rawCommand = message[WatchMessageKey.command] as? String ?? ""
        nonisolated(unsafe) let handler = replyHandler
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                handler([
                    WatchMessageKey.state: "error",
                    WatchMessageKey.elapsedTime: 0,
                    WatchMessageKey.audioLevel: 0,
                    WatchMessageKey.isActive: false,
                ])
                return
            }
            self.applyCommand(rawCommand)
            let status = self.coordinator.currentStatus()
            handler([
                WatchMessageKey.state: status.state,
                WatchMessageKey.elapsedTime: status.elapsedTime,
                WatchMessageKey.audioLevel: status.audioLevel,
                WatchMessageKey.isActive: status.isActive,
            ])
        }
    }

    func sessionReachabilityDidChange(_ wcSession: WCSession) {
        AppLog.general.info("WCSession reachability: \(wcSession.isReachable)")
        if wcSession.isReachable {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sendStatus(self.coordinator.currentStatus())
            }
        }
    }

    // MARK: - Internal

    private func applyCommand(_ rawCommand: String) {
        guard let command = WatchCommand(rawValue: rawCommand) else { return }

        // We're on the main queue (called from DispatchQueue.main.async).
        // coordinator is @MainActor — assumeIsolated is safe here.
        MainActor.assumeIsolated {
            switch command {
            case .startRecording:
                _ = coordinator
                coordinator.startRecording()
            case .pauseRecording:
                coordinator.pauseRecording()
            case .resumeRecording:
                coordinator.resumeRecording()
            case .stopRecording:
                coordinator.stopRecording()
            case .requestStatus:
                sendStatus(coordinator.currentStatus())
            }
        }
    }
}
