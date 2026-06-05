import WatchConnectivity
import WatchKit
import OSLog

final class WatchSessionManager: NSObject, WCSessionDelegate, ObservableObject, @unchecked Sendable {
    @Published var recordingStatus = RecordingStatus.idle()

    private let session: WCSession
    private var localTimer: Timer?

    override init() {
        self.session = .default
        super.init()
        session.delegate = self
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.activate()
    }

    func sendCommand(_ command: WatchCommand) {
        guard session.activationState == .activated else { return }

        let message: [String: Any] = ["command": command.rawValue]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil)
        } else {
            do {
                try session.updateApplicationContext(message)
            } catch {
                AppLog.general.warning("Watch sendMessage failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Local timer

    private func startLocalTimer() {
        localTimer?.invalidate()
        localTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.recordingStatus.isActive else { return }
                var updated = self.recordingStatus
                updated = RecordingStatus(
                    state: updated.state,
                    elapsedTime: updated.elapsedTime + 1.0,
                    audioLevel: updated.audioLevel,
                    errorMessage: updated.errorMessage,
                    recordingTitle: updated.recordingTitle,
                    isActive: true
                )
                self.recordingStatus = updated
            }
        }
    }

    private func stopLocalTimer() {
        localTimer?.invalidate()
        localTimer = nil
    }

    // MARK: - WCSessionDelegate (watchOS)

    @objc(session:activationDidCompleteWithState:error:)
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            AppLog.general.error("Watch WCSession activation failed: \(error.localizedDescription)")
        }
        if activationState == .activated {
            session.sendMessage(["command": WatchCommand.requestStatus.rawValue], replyHandler: nil)
        }
    }

    @objc(session:didReceiveMessage:)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Extract Sendable values before crossing into main actor.
        let type = message["type"] as? String
        let state = message["state"] as? String ?? "idle"
        let elapsedTime = message["elapsedTime"] as? Double ?? 0
        let audioLevel = message["audioLevel"] as? Float ?? 0
        let isActive = message["isActive"] as? Bool ?? false
        let errorMessage = message["errorMessage"] as? String
        let recordingTitle = message["recordingTitle"] as? String

        DispatchQueue.main.async { [weak self] in
            self?.applyStatusUpdate(
                type: type,
                state: state,
                elapsedTime: elapsedTime,
                audioLevel: audioLevel,
                isActive: isActive,
                errorMessage: errorMessage,
                recordingTitle: recordingTitle
            )
        }
    }

    // MARK: - Status handling

    private func applyStatusUpdate(
        type: String?,
        state: String,
        elapsedTime: Double,
        audioLevel: Float,
        isActive: Bool,
        errorMessage: String?,
        recordingTitle: String?
    ) {
        guard type == "status" else { return }

        let previousIsActive = recordingStatus.isActive

        recordingStatus = RecordingStatus(
            state: state,
            elapsedTime: elapsedTime,
            audioLevel: audioLevel,
            errorMessage: errorMessage,
            recordingTitle: recordingTitle,
            isActive: isActive
        )

        if isActive && !previousIsActive {
            WKInterfaceDevice.current().play(.click)
            startLocalTimer()
        } else if !isActive && previousIsActive {
            WKInterfaceDevice.current().play(.notification)
            stopLocalTimer()
        }

        // Persist to App Group for complication
        if let shared = UserDefaults(suiteName: "group.com.wawa-note") {
            shared.set(recordingStatus.state, forKey: "recordingState")
            shared.set(recordingStatus.elapsedTime, forKey: "elapsedTime")
            shared.set(recordingStatus.isActive, forKey: "isActive")
            shared.set(recordingStatus.recordingTitle, forKey: "recordingTitle")
        }
    }
}
