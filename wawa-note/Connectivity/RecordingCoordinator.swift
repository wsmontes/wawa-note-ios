import AVFoundation
import Combine
import OSLog
import SwiftData
import UIKit

// Related JIRA: KAN-5, KAN-14, KAN-17, KAN-77

extension Notification.Name {
    /// Posted after crash-recovered orphaned recordings have been cleaned up
    /// and their pipeline processing has been triggered. Views observing this
    /// should refresh their data to pick up items that transitioned from
    /// .recording → .recorded / .failed.
    static let wawaOrphanedRecordingsCleanedUp = Notification.Name("WawaOrphanedRecordingsCleanedUp")
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isClipping: Bool = false
    @Published private(set) var clipCount: Int = 0
    @Published private(set) var isAutoPaused: Bool = false
    @Published private(set) var silenceDetected: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedItemId: UUID?
    @Published private(set) var currentInputPortName: String = ""
    @Published private(set) var currentInputIcon: String = "mic.fill"

    private let captureService: AudioCaptureService
    private let nowPlayingController: NowPlayingController
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let contextCaptureService = ContextCaptureService()
    private var annotationService: AnnotationService
    var contentPipeline: ContentPipelineService?
    /// When set, pipeline processing is enqueued through this service instead of
    /// calling ContentPipelineService.process() directly. This enables retry with
    /// backoff, offline queueing, and cancellation — direct calls skip all of that.
    var processingQueue: ProcessingQueueService?

    private var recordingStartDate: Date?
    private var pausedDuration: TimeInterval = 0
    private var wasUserPaused = false  // true when pauseRecording() was called by the user
    private var pauseStartDate: Date?
    private var recordingTitle: String = ""
    private var observationTimer: Timer?
    private var nowPlayingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Segmented recording manifest (segments managed by AudioCaptureService)
    private var manifest: RecordingManifest?

    var onStatusChange: ((RecordingStatus) -> Void)?

    var outputFileURL: URL? { captureService.outputFileURL }

    var elapsedTimeFormatted: String {
        let effective = elapsedTime - pausedDuration
        let m = Int(effective) / 60
        let s = Int(effective) % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Human-readable sample rate with quality indicator for the recording UI.
    /// Updated each observation tick from captureService.captureSampleRate.
    /// Examples: "44.1 kHz · HQ", "8 kHz · LQ", ""
    @Published private(set) var sampleRateBadge: String = ""

    private func updateSampleRateBadge() {
        let rate = captureService.captureSampleRate
        guard rate > 0 else {
            sampleRateBadge = ""
            return
        }
        let khz = rate / 1000
        let quality: String
        switch rate {
        case ..<12000: quality = "LQ"  // Bluetooth HFP 8kHz
        case ..<24000: quality = "MQ"  // 16-22kHz
        default: quality = "HQ"  // 44.1-48kHz built-in/USB
        }
        sampleRateBadge = "\(String(format: "%.1f", khz)) kHz · \(quality)"
    }

    init(
        modelContainer: ModelContainer,
        captureService: AudioCaptureService = AudioCaptureService(),
        nowPlayingController: NowPlayingController = NowPlayingController()
    ) {
        self.modelContainer = modelContainer
        self.captureService = captureService
        self.nowPlayingController = nowPlayingController
        let context = ModelContext(modelContainer)
        self.modelContext = context
        self.annotationService = AnnotationService(context: context)

        // Route change → new segment created by AudioCaptureService
        captureService.onSegmentCreated = { [weak self] closedInfo, newSegment in
            guard let self, var m = self.manifest else { return }
            // Finalize previous segment with accurate metadata from the writer
            if let info = closedInfo, let lastIdx = m.segments.indices.last {
                m.segments[lastIdx].endedAt = info.endedAt
                m.segments[lastIdx].fileSize = info.fileSize
            }
            m.segments.append(newSegment)
            self.manifest = m
            if let itemId = self.savedItemId {
                self.saveManifest(m, meetingId: itemId)
            }
        }

        // Interruption began → segment closed without opening a new one.
        // Finalize the CLOSED segment's metadata by its index, not blindly
        // the last segment. Recovery attempts open/close segments that were
        // never added to the manifest via onSegmentCreated — updating
        // segments[lastIdx] would overwrite an unrelated segment's data.
        captureService.onSegmentClosed = { [weak self] closedInfo in
            guard let self, var m = self.manifest else { return }
            if let idx = m.segments.firstIndex(where: { $0.index == closedInfo.index }) {
                m.segments[idx].endedAt = closedInfo.endedAt
                m.segments[idx].fileSize = closedInfo.fileSize
            } else {
                // Orphan segment from a failed recovery attempt — never
                // registered via onSegmentCreated. Add it now so its audio
                // (even if partial/silent) is tracked and transcribable.
                let orphan = RecordingSegment(
                    id: UUID(), index: closedInfo.index,
                    fileName: closedInfo.fileName,
                    startedAt: Date(),
                    inputPortName: "",
                    inputPortType: "unknown",
                    routeChangeReason: "recovery-orphan",
                    sampleRate: nil
                )
                m.segments.append(orphan)
                if let lastIdx = m.segments.indices.last {
                    m.segments[lastIdx].endedAt = closedInfo.endedAt
                    m.segments[lastIdx].fileSize = closedInfo.fileSize
                }
            }
            self.manifest = m
            if let itemId = self.savedItemId {
                self.saveManifest(m, meetingId: itemId)
            }
        }

        // Manifest is the source of truth for the next segment index — NOT
        // the AudioFileWriter's internal counter, which can get confused
        // across engine teardown/recreation cycles.
        captureService.nextSegmentIndexProvider = { [weak self] in
            guard let self, let m = self.manifest else { return 0 }
            return (m.segments.map(\.index).max() ?? -1) + 1
        }

        // Keep UI state in sync with the real capture service state.
        // The capture service owns the source of truth for recording state;
        // the coordinator mirrors it for the UI layer.
        captureService.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] captureState in
                self?.syncCaptureState(captureState)
            }
            .store(in: &cancellables)

        captureService.$audioInterruptionReason
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                self?.errorMessage = reason
                self?.notifyStatusChange()
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording lifecycle

    func startRecording(
        title: String? = nil,
        scheduledDate: Date? = nil,
        calendarEventIdentifier: String? = nil,
        projectID: UUID? = nil
    ) {
        // Auto-recover from stale state after previous recording
        if self.state == .stopped { returnToIdle() }
        guard self.state == .idle else {
            AppLog.warn("audio", "RecordingCoordinator: startRecording called but state is \(String(describing: self.state))")
            return
        }

        AppLog.event("audio", "Recording requested — title=\(title ?? "nil") projectID=\(projectID?.uuidString.prefix(8) ?? "nil")")

        guard AudioSessionManager.hasMinimumDiskSpace() else {
            AppLog.warn("audio", "Recording blocked: insufficient disk space")
            errorMessage = "Not enough storage space to record. Please free up some space."
            notifyStatusChange()
            return
        }

        // Block early if mic permission is denied — avoids creating an item
        // that would be immediately rolled back when startRecording fails.
        let micPermission = AVAudioSession.sharedInstance().recordPermission
        guard micPermission != .denied else {
            AppLog.warn("audio", "Recording blocked: microphone permission denied")
            errorMessage = "Microphone access is off. Turn it on in Settings to record audio."
            notifyStatusChange()
            return
        }

        errorMessage = nil
        savedItemId = nil

        let recordingTitle = title ?? "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
        self.recordingTitle = recordingTitle

        let context = modelContext

        let item = KnowledgeItem(type: .audio, title: recordingTitle, status: .recording)
        item.scheduledDate = scheduledDate
        item.calendarEventIdentifier = calendarEventIdentifier
        if let projectID {
            item.projectID = projectID
            item.inboxDate = nil
        }
        context.insert(item)

        do {
            try context.save()
        } catch {
            AppLog.error("audio", "Failed to save knowledge item for recording: \(error.localizedDescription)")
            errorMessage = "Could not save recording. Try again."
            notifyStatusChange()
            return
        }

        let itemId = item.id
        savedItemId = itemId

        // Create manifest with placeholder segment — guarantees valid manifest
        // before stopRecording(), even if onSegmentCreated hasn't fired yet.
        // The capture service's onSegmentClosed at stop will finalize metadata.
        let placeholder = RecordingSegment(
            id: UUID(), index: 0,
            fileName: "segment-000.wav",
            startedAt: Date(),
            inputPortName: "",
            inputPortType: AudioSessionManager().bestAvailableInput?.portType.rawValue ?? "unknown",
            routeChangeReason: "initial",
            sampleRate: nil
        )
        manifest = RecordingManifest(
            recordingId: itemId, title: recordingTitle,
            startedAt: Date(), segments: [placeholder]
        )
        saveManifest(manifest!, meetingId: itemId)

        // Pre-flight: configure audio session and start engine BEFORE showing
        // the recording UI. If the mic is unavailable (in use by another app,
        // Bluetooth in bad state), retry with backoff and fall back to built-in
        // mic before giving up. Only transition to .recording on success.
        state = .preparing
        notifyStatusChange()

        Task { @MainActor [weak self] in
            guard let self else { return }

            let result = await self.startAudioCaptureWithRetry(meetingId: itemId)

            switch result {
            case .success:
                self.state = .recording
                UIApplication.shared.isIdleTimerDisabled = true
                self.startObservation()
                self.activateLockScreenControls()
                self.recordingStartDate = Date()
                self.captureContextSafely(for: itemId)
                self.notifyStatusChange()
                AppLog.event("audio", "Recording started — itemID=\(itemId.uuidString.prefix(8)) input=\(self.captureService.currentInputPortName)")

            case .permissionDenied:
                AppLog.warn("audio", "Recording blocked: microphone permission denied")
                self.errorMessage = "Microphone access is off. Turn it on in Settings to record audio."
                self.rollbackRecordingStart(item: item)

            case .diskFull:
                AppLog.error("audio", "Recording failed: disk full")
                self.errorMessage = "Not enough storage. Free up space and try again."
                self.rollbackRecordingStart(item: item)

            case .failed(let detail):
                AppLog.error("audio", "Recording start failed after 3 attempts: \(detail)")
                self.errorMessage = "Could not start recording. \(detail)"
                self.rollbackRecordingStart(item: item)
            }
        }
    }

    /// Pre-flight result for the recording start flow.
    private enum PreflightResult {
        case success
        case permissionDenied
        case diskFull
        case failed(String)
    }

    /// Attempt to start audio capture with retry and fallback.
    /// Tries up to 3 times: first two with the preferred input, third with
    /// built-in mic forced. Backoff: 300ms, 600ms between attempts.
    private func startAudioCaptureWithRetry(meetingId: UUID) async -> PreflightResult {
        let backoffNs: [UInt64] = [0, 300_000_000, 600_000_000]

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: backoffNs[attempt])
            }

            let forceBuiltIn = attempt == 2

            do {
                if forceBuiltIn {
                    AppLog.audio.info("Pre-flight attempt \(attempt + 1): forcing built-in mic")
                }

                try await captureService.startRecording(meetingId: meetingId)
                return .success
            } catch AudioCaptureError.permissionDenied {
                return .permissionDenied
            } catch AudioCaptureError.diskFull {
                return .diskFull
            } catch {
                AppLog.audio.warning("Pre-flight attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt == 2 {
                    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
                    return .failed(error.localizedDescription)
                }
            }
        }

        return .failed("Unknown error")
    }

    private func rollbackRecordingStart(item: KnowledgeItem) {
        state = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        observationTimer?.invalidate()
        observationTimer = nil
        nowPlayingController.deactivate()
        // Clean up files created by AudioFileWriter.startRecording() before the
        // engine start failed. Without this, orphaned meeting directories with
        // empty/partial segment files accumulate in the store.
        try? FileArtifactStore().deleteMeetingDirectory(for: item.id)
        rollbackItem(item, context: modelContext)
        notifyStatusChange()
    }

    /// Delete an item and its files. Files are deleted FIRST so that if removal
    /// fails, the SwiftData record remains intact — the item can still be recovered.
    /// Matches the canonical order in KnowledgeItemService.deleteItem().
    func deleteItem(_ itemId: UUID) {
        // 1. Delete files from disk FIRST — if this fails, abort
        let store = FileArtifactStore()
        do {
            try store.deleteMeetingDirectory(for: itemId)
        } catch {
            AppLog.storage.error("RecordingCoordinator: deleteItem file removal failed — \(itemId.uuidString): \(error.localizedDescription)")
            // Don't proceed — the SwiftData record is still valid
            return
        }

        // 2. Only after successful file removal, clean up SwiftData
        let context = modelContext
        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        if let item = try? context.fetch(descriptor).first {
            let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { $0.itemID == itemId })
            if let anns = try? context.fetch(annPred) {
                for ann in anns { context.delete(ann) }
            }
            context.delete(item)
            do {
                try context.save()
            } catch {
                AppLog.storage.error("RecordingCoordinator: deleteItem SwiftData save failed — \(itemId.uuidString): \(error.localizedDescription)")
            }
        }
    }

    func createItemFromImport(
        title: String,
        date: Date,
        duration: TimeInterval,
        projectID: UUID? = nil,
        languageCode: String? = nil
    ) -> KnowledgeItem? {
        let context = modelContext
        let item = KnowledgeItem(type: .audio, title: title, createdAt: date, updatedAt: date, status: .recorded, durationSeconds: duration)
        item.audioFileRelativePath = AppFileConstants.audioFileName
        item.isImported = true
        item.languageCode = languageCode
        if let pid = projectID {
            item.projectID = pid
            item.inboxDate = nil
        }
        context.insert(item)
        try? context.save()
        return item
    }

    func pauseRecording() {
        // Pause in any active state — the capture service handles the transition.
        // Guard only against truly inactive states (idle, stopped).
        let isFailed: Bool = if case .failed = state { true } else { false }
        guard state != .idle, state != .stopped, !isFailed else { return }

        captureService.pauseRecording()
        wasUserPaused = true
        state = .paused
        pauseStartDate = Date()
        observationTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
        notifyStatusChange()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        wasUserPaused = false
        // Try a simple engine resume first (user-initiated pause path).
        // If the engine is no longer running (route-loss / interruption), fall
        // back to retryRecordingRecovery() which retries up to 3 times.
        do {
            try captureService.resumeRecording()
        } catch {
            AppLog.warn("audio", "Simple resume threw — falling back to force recovery: \(error)")
            retryRecordingRecovery()
            return
        }
        if captureService.state == .recording {
            commitUIRecordingState()
        } else {
            // Engine didn't transition to .recording — route may have changed.
            // Force recovery handles Bluetooth re-establishment.
            retryRecordingRecovery()
        }
    }

    func stopRecording() {
        // Accept ANY active state. Only refuse idle and stopped.
        wasUserPaused = false
        guard state != .idle, state != .stopped else { return }
        let itemId = savedItemId
        AppLog.event(
            "audio", "Stopping recording — elapsed=\(elapsedTimeFormatted) pausedDur=\(Int(pausedDuration))s itemID=\(itemId?.uuidString.prefix(8) ?? "nil")")
        // Capture audio metadata BEFORE stopRecording() deactivates the session.
        let capturedSampleRate = captureService.captureSampleRate
        let capturedInputPortType = captureService.captureInputPortType
        let capturedInputPortName = captureService.currentInputPortName
        captureService.stopRecording()
        state = .stopped
        // Restore auto-lock — no longer recording.
        UIApplication.shared.isIdleTimerDisabled = false
        nowPlayingController.deactivate()
        observationTimer?.invalidate()
        observationTimer = nil
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil

        // Finalize manifest — capture a copy so the pipeline closure below
        // can still access it after the if-var scope closes.
        var finalizedManifest: RecordingManifest? = nil
        if var m = manifest, let meetingId = savedItemId {
            if let idx = m.segments.indices.last { m.segments[idx].endedAt = Date() }
            m.endedAt = Date()
            saveManifest(m, meetingId: meetingId)
            finalizedManifest = m
        }

        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }

        // Update item — validates audio, marks as recorded or failed
        updateItemOnStop(
            sampleRate: capturedSampleRate,
            inputPortType: capturedInputPortType,
            inputPortName: capturedInputPortName
        )
        notifyStatusChange()

        // Trigger pipeline AFTER concatenation and validation complete.
        // The Task is non-blocking for the UI (stop returns immediately),
        // but the pipeline is gated behind concat so audio.m4a is ready.
        if let itemId, let manifest = finalizedManifest {
            Task {
                // 1. Concatenate segments into audio.m4a (AAC) — file I/O, safe off MainActor
                let concatOK = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)

                // 2. All remaining steps touch MainActor-isolated state (modelContext,
                //    processingQueue, etc.) — run them on MainActor.
                await MainActor.run { [self] in
                    // 3. Debug validation report
                    logRecordingArtifactReport(itemId: itemId)

                    guard concatOK else {
                        AppLog.audio.error("RecordingCoordinator: concatenation failed — marking item as failed")
                        updateItemStatus(itemId: itemId, to: .failed)
                        return
                    }

                    // 4. Clear crash checkpoint — recording stopped successfully
                    AudioFileWriter.clearCrashCheckpoint()

                    // 5. Mark as queued so the detail view shows the right status
                    updateItemStatus(itemId: itemId, to: .queuedForTranscription)

                    // 6. Route through ProcessingQueue when available
                    if let queue = processingQueue {
                        AppLog.event("audio", "Enqueuing item \(itemId.uuidString.prefix(8)) into ProcessingQueue")
                        queue.enqueue(itemID: itemId, trigger: .newCapture)
                    } else if let pipeline = contentPipeline {
                        AppLog.event("audio", "Pipeline (direct) for item \(itemId.uuidString.prefix(8))")
                        pipeline.process(itemId, using: modelContext)
                    }
                }
            }
        }
    }

    // MARK: - Segments

    /// Save the manifest to disk. Called after each segment and at stop.
    /// Errors are logged but not propagated — a failed manifest write should not
    /// tear down the recording session. The manifest is re-saved at stop, giving
    /// another chance to persist.
    private func saveManifest(_ manifest: RecordingManifest, meetingId: UUID) {
        let store = FileArtifactStore()
        do {
            try store.writeRecordingManifest(manifest, for: meetingId)
        } catch {
            AppLog.storage.error("RecordingCoordinator: saveManifest failed — \(meetingId.uuidString): \(error.localizedDescription)")
        }
    }

    func returnToIdle() {
        wasUserPaused = false
        state = .idle
        elapsedTime = 0
        pausedDuration = 0
        audioLevel = 0
        isClipping = false
        clipCount = 0
        isAutoPaused = false
        silenceDetected = false
        savedItemId = nil
        errorMessage = nil
        manifest = nil
        captureService.resetToIdle()
    }

    // MARK: - State sync with capture service

    /// Atomically commit the UI to `.recording`. The capture service has already
    /// validated that the engine is running and buffers are arriving. This is
    /// the ONLY path that sets coordinator state to `.recording` from sync.
    private func commitUIRecordingState() {
        if let ps = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(ps)
            pauseStartDate = nil
        }
        state = .recording
        startObservation()
        // Re-activate lock screen controls — may have been deactivated by
        // pause timeout (engine stopped to save battery) or interruption.
        activateLockScreenControls()
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: true)
        notifyStatusChange()
    }

    /// Mirror the capture service's state. Simple 4-state mapping.
    private func syncCaptureState(_ captureState: AudioCaptureState) {
        switch captureState {
        case .recording:
            if state == .paused || state == .stopped {
                commitUIRecordingState()
            }
        case .paused:
            if state == .recording {
                state = .paused
                if pauseStartDate == nil { pauseStartDate = Date() }
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
                notifyStatusChange()
            }
        case .stopped:
            if state != .stopped {
                state = .stopped
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                nowPlayingController.deactivate()
                notifyStatusChange()
            }
        case .idle:
            break
        }
    }

    /// Force recovery using the built-in iPhone microphone.
    /// Call when Bluetooth fails and the user wants to fall back.
    func forceBuiltInMicRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureService.forceBuiltInMicRecovery()
            if self.captureService.state == .recording {
                self.commitUIRecordingState()
            }
        }
    }

    /// Manual retry when the user presses Resume after a route-loss interruption.
    /// Forces .recording intent with up to 3 attempts and progressive delay —
    /// Bluetooth devices take time to stabilize after connection.
    func retryRecordingRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                await self.captureService.attemptResume(forceRecording: true)

                if self.captureService.state == .recording {
                    self.commitUIRecordingState()
                    AppLog.audio.info("Recording resumed after \(attempt) attempt(s)")
                    return
                }

                // Don't retry if the failure is permanent (not a transient Bluetooth issue)
                let reason = self.captureService.audioInterruptionReason ?? ""
                if reason.contains("storage") || reason.contains("Internal error") {
                    break
                }

                if attempt < 3 {
                    let delayNs = UInt64(attempt) * 700_000_000
                    AppLog.audio.info("Resume attempt \(attempt) failed — retrying in \(delayNs / 1_000_000)ms")
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }

            // After 3 failed retries, try forceBuiltInMicRecovery as a last resort.
            // The iPhone built-in mic is the most reliable fallback — if it's available,
            // we should try it before giving up and showing an error.
            AppLog.audio.info("All retry attempts failed — attempting forceBuiltInMicRecovery")
            await self.captureService.forceBuiltInMicRecovery()
            if self.captureService.state == .recording || self.captureService.state == .paused {
                self.commitUIRecordingState()
                AppLog.audio.info("Recording resumed via built-in mic fallback")
                return
            }

            self.state = .paused
            self.errorMessage =
                self.captureService.audioInterruptionReason
                ?? "Could not resume recording. Try disconnecting Bluetooth or use iPhone mic."
            self.notifyStatusChange()
        }
    }

    /// Attempt to recover from audio interruptions when the app returns to the foreground.
    func onAppForeground() {
        guard state == .paused, !wasUserPaused else { return }
        AppLog.event("audio", "App returned to foreground — attempting recovery from system interruption")
        try? captureService.resumeRecording()
        if captureService.state == .recording {
            state = .recording
            startObservation()
            notifyStatusChange()
        } else if captureService.state == .paused {
            state = .paused
            notifyStatusChange()
        }
    }

    /// Remove any recording directories for items that are still in .recording status
    /// (abandoned from previous app termination). Call once at app startup.
    /// Uses a dedicated background context to avoid touching the main context during init.
    /// Attempts to recover from a crash using the recording checkpoint file.
    /// Called on app launch before cleanupOrphanedRecordings.
    /// Returns true if a checkpoint was found and recovery was attempted.
    @discardableResult
    func attemptCrashCheckpointRecovery() -> Bool {
        guard let (meetingId, segmentIndex, sampleRate) = AudioFileWriter.loadCrashCheckpoint() else {
            return false
        }
        AppLog.audio.info("Crash checkpoint found: meetingId=\(meetingId.uuidString.prefix(8)) segment=\(segmentIndex) sampleRate=\(sampleRate)Hz")

        // Ensure the item exists and is in a recoverable state
        let bgContext = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == meetingId })
        descriptor.fetchLimit = 1
        guard let item = try? bgContext.fetch(descriptor).first else {
            AppLog.audio.warning("Crash recovery: item \(meetingId.uuidString.prefix(8)) not found — discarding checkpoint")
            AudioFileWriter.clearCrashCheckpoint()
            return false
        }

        // Only recover items stuck in .recording state
        guard item.statusRaw == "recording" else {
            AppLog.audio.info("Crash recovery: item \(meetingId.uuidString.prefix(8)) already in state \(item.statusRaw) — discarding checkpoint")
            AudioFileWriter.clearCrashCheckpoint()
            return false
        }

        // Save the current manifest with the last known segment index
        var manifest = RecordingManifest(
            recordingId: meetingId,
            title: item.title,
            startedAt: item.createdAt,
            segments: (0...segmentIndex).map { i in
                RecordingSegment(
                    id: UUID(),
                    index: i,
                    fileName: String(format: "segment-%03d.wav", i),
                    startedAt: item.createdAt.addingTimeInterval(Double(i) * 60),
                    endedAt: nil,
                    inputPortName: "recovered",
                    inputPortType: "recovered",
                    routeChangeReason: "crash_recovery",
                    sampleRate: sampleRate
                )
            }
        )
        item.status = .recorded
        item.audioFileRelativePath = AppFileConstants.audioFileName
        let store = FileArtifactStore()
        saveManifest(manifest, meetingId: meetingId)

        // Attempt concatenation to produce a playable audio.m4a
        Task {
            let concatOK = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: meetingId)
            if concatOK {
                AppLog.audio.info("Crash recovery: concatenation succeeded for \(meetingId.uuidString.prefix(8))")
                item.status = .recorded
                try? bgContext.save()
            } else {
                AppLog.audio.warning("Crash recovery: concatenation failed — segments are still available as WAV")
                // Don't fail the item — WAV segments are still usable
                try? bgContext.save()
            }
        }

        try? bgContext.save()
        AudioFileWriter.clearCrashCheckpoint()
        AppLog.event("audio", "Crash checkpoint recovered: \(meetingId.uuidString.prefix(8)) segment=\(segmentIndex)")
        return true
    }

    /// Checks whether an M4A file is missing its moov atom (unplayable).
    /// Reads the first 8 bytes of the file: if the moov atom is missing and
    /// only ftyp + mdat exist, the file was interrupted during export.
    private func isM4ABroken(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4096)  // Read enough to see atom structure
        // Check for moov atom presence
        let moovRange = data.range(of: Data("moov".utf8))
        return moovRange == nil
    }

    func cleanupOrphanedRecordings() {
        // First, attempt crash checkpoint recovery
        let recovered = attemptCrashCheckpointRecovery()

        // Use a fresh context isolated from the main context used by SwiftUI views.
        // This is a read-delete-save driven by app init, not user interaction.
        do {
            let bgContext = ModelContext(modelContext.container)
            let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.statusRaw == "recording" })
            guard let orphans = try? bgContext.fetch(descriptor), !orphans.isEmpty else { return }

            AppLog.audio.info("Found \(orphans.count) interrupted recording(s) — recovering")
            var recoveredIds: [UUID] = []
            for item in orphans {
                AppLog.audio.info("Recovering interrupted recording: \(item.id)")
                item.status = .recorded
                let store = FileArtifactStore()
                guard store.audioFileExists(for: item.id) || store.recordingManifestExists(for: item.id) else {
                    item.status = .failed
                    continue
                }
                item.audioFileRelativePath = AppFileConstants.audioFileName
                recoveredIds.append(item.id)
            }

            // Also recover recorded items with broken M4A (concatenation was interrupted).
            // These items have status .recorded and WAV segments exist, but audio.m4a is
            // invalid (missing moov atom). Re-concatenating from WAV segments fixes them.
            let recordedDescriptor = FetchDescriptor<KnowledgeItem>(
                predicate: #Predicate {
                    $0.statusRaw == "recorded" && $0.audioFileRelativePath != nil
                })
            let recordedItems = (try? bgContext.fetch(recordedDescriptor)) ?? []
            var repairedIds: [UUID] = []
            for item in recordedItems {
                let store = FileArtifactStore()
                let audioURL = store.audioFileURL(for: item.id)
                guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
                if isM4ABroken(at: audioURL) {
                    AppLog.audio.warning("Found broken M4A for item \(item.id.uuidString.prefix(8)) — re-concatenating from WAV segments")
                    // Re-concatenate from WAV segments if manifest exists.
                    // Use Task because concatenate() is async but cleanupOrphanedRecordings is sync.
                    if let manifest = try? store.readRecordingManifest(for: item.id) {
                        let itemId = item.id
                        Task { @MainActor [weak self] in
                            let ok = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
                            if ok {
                                AppLog.audio.info("Repaired broken M4A for item \(itemId.uuidString.prefix(8))")
                                // Access processingQueue at execution time, not capture time (it's nil during init)
                                if let queue = self?.processingQueue {
                                    queue.enqueue(itemID: itemId, trigger: .backgroundBackfill)
                                } else {
                                    AppLog.audio.warning("Cannot re-enqueue repaired item — processingQueue is nil")
                                }
                            } else {
                                AppLog.audio.error("Failed to repair broken M4A for item \(itemId.uuidString.prefix(8))")
                            }
                        }
                    }
                }
            }

            try bgContext.save()
            AppLog.audio.info("Recovered \(recoveredIds.count)/\(orphans.count) interrupted recording(s), repaired \(repairedIds.count) broken M4A(s)")

            // Trigger pipeline for successfully recovered items so they get
            // transcribed and analyzed. Without this, crash-recovered items
            // remain stuck in .recorded state forever.
            if !recoveredIds.isEmpty {
                for itemId in recoveredIds {
                    AppLog.event("audio", "Enqueuing recovered item \(itemId.uuidString.prefix(8)) for pipeline processing")
                    // Use Task to avoid blocking app init — pipeline runs async.
                    Task { @MainActor in
                        // Concatenate segments first (essential for multi-segment recordings)
                        if let m = try? FileArtifactStore().readRecordingManifest(for: itemId) {
                            await AudioSegmentConcatenator.concatenate(manifest: m, meetingId: itemId)
                        }
                        if let queue = processingQueue {
                            queue.enqueue(itemID: itemId, trigger: .newCapture)
                        } else if let pipeline = contentPipeline {
                            pipeline.process(itemId, using: modelContext)
                        }
                    }
                }
            }
            // Notify views that items may have changed state so they can refresh.
            // The bgContext save doesn't automatically update the main context used
            // by SwiftUI views — they'd otherwise keep showing stale .recording status.
            if !recoveredIds.isEmpty {
                NotificationCenter.default.post(name: .wawaOrphanedRecordingsCleanedUp, object: nil)
            }
        } catch {
            AppLog.audio.error("Orphan cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Status

    func currentStatus() -> RecordingStatus {
        RecordingStatus(
            state: stateString,
            elapsedTime: elapsedTime - pausedDuration,
            audioLevel: audioLevel,
            errorMessage: errorMessage,
            recordingTitle: recordingTitle,
            isActive: state == .recording || state == .paused
        )
    }

    private var stateString: String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .recording: return "recording"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    private func notifyStatusChange() {
        let status = currentStatus()
        onStatusChange?(status)
        if let shared = UserDefaults(suiteName: "group.com.wawa-note") {
            shared.set(status.state, forKey: "recordingState")
            shared.set(status.elapsedTime, forKey: "elapsedTime")
            shared.set(status.isActive, forKey: "isActive")
            shared.set(status.recordingTitle, forKey: "recordingTitle")
        }
    }

    // MARK: - Lock screen controls

    private func activateLockScreenControls() {
        nowPlayingController.onPlay = { [weak self] in
            DispatchQueue.main.async { self?.resumeRecording() }
        }
        nowPlayingController.onPause = { [weak self] in
            DispatchQueue.main.async { self?.pauseRecording() }
        }
        nowPlayingController.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        nowPlayingController.onTogglePlayPause = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.state == .recording {
                    self.pauseRecording()
                } else if self.state == .paused {
                    self.resumeRecording()
                }
            }
        }
        nowPlayingController.activate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: 0, isPlaying: true)
    }

    // MARK: - Observation

    private func startObservation() {
        // Timer.scheduledTimer MUST be created on the main thread — otherwise
        // it fires on a background run loop and triggers BUG IN CLIENT OF LIBDISPATCH
        // in MPNowPlayingInfoCenter, which asserts on the main-thread requirement.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startObservation() }
            return
        }

        observationTimer?.invalidate()
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in  // 10Hz — smooth enough for UI, half the CPU of 20Hz
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            if let start = self.recordingStartDate {
                self.elapsedTime = Date().timeIntervalSince(start)
            }
            self.audioLevel = self.captureService.audioLevel
            // Clipping detection (hysteresis: on at > 0.95, off at < 0.85)
            let level = self.captureService.audioLevel
            if level > 0.95 && !self.isClipping {
                self.isClipping = true
                self.clipCount += 1
            } else if level < 0.85 && self.isClipping {
                self.isClipping = false
            }
            // Sync input port info (may change on route switch)
            // Segments are handled by onRouteChangeNewSegment callback
            let portName = self.captureService.currentInputPortName
            if self.currentInputPortName != portName, !portName.isEmpty {
                self.currentInputPortName = portName
                self.currentInputIcon = self.captureService.currentInputPortIcon
            }
            // Sync silence detection (from adaptive threshold in capture service)
            let captureSilent = self.captureService.silenceDetected
            if self.silenceDetected != captureSilent {
                self.silenceDetected = captureSilent
            }
            // Refresh sample rate badge (may change on route switch)
            self.updateSampleRateBadge()
            if self.captureService.state == .stopped {
                self.state = .stopped
                self.nowPlayingController.deactivate()
                self.observationTimer?.invalidate()
                self.observationTimer = nil
                self.nowPlayingTimer?.invalidate()
                self.nowPlayingTimer = nil
            } else if self.captureService.state == .paused && self.state != .paused {
                self.state = .paused
                self.pauseStartDate = Date()  // Freeze elapsed time
                self.notifyStatusChange()
            }
        }

        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            guard self.state == .recording || self.state == .paused else { return }
            let effective = self.elapsedTime - self.pausedDuration
            self.nowPlayingController.update(
                title: self.recordingTitle,
                elapsedTime: effective,
                isPlaying: self.state == .recording
            )
        }
    }

    // MARK: - Context capture

    private func captureContextSafely(for itemId: UUID) {
        let sensors = contextCaptureService
        let annotSvc = annotationService
        Task.detached {
            let captured = await sensors.captureAll()
            guard !captured.isEmpty else { return }
            await MainActor.run {
                do {
                    try annotSvc.upsert(captured, itemID: itemId, source: "recording_context")
                    AppLog.general.info("Context: \(captured.count) annotations for item \(itemId)")
                } catch {
                    AppLog.error("general", "Context capture save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func rollbackItem(_ item: KnowledgeItem, context: ModelContext) {
        context.delete(item)
        do {
            try context.save()
        } catch {
            AppLog.error("audio", "Failed to rollback item after recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Debug

    /// Log a structured recording artifact report. Mandatory until route switching is stable.
    /// Called on every Finish after concatenation completes.
    private func logRecordingArtifactReport(itemId: UUID) {
        let store = FileArtifactStore()
        let report = store.debugRecordingArtifacts(meetingId: itemId)
        AppLog.audio.info("RecordingArtifactValidation:\n\(report)")
    }

    // MARK: - Save

    /// Validate that at least one segment in the manifest has a real file with audio data.
    private func hasValidAudioData(meetingId: UUID) -> Bool {
        let store = FileArtifactStore()
        guard store.recordingManifestExists(for: meetingId),
            let manifest = try? store.readRecordingManifest(for: meetingId)
        else {
            // Legacy: check audio.m4a directly
            return store.audioFileExists(for: meetingId)
        }
        for seg in manifest.segments {
            let url = store.segmentURL(for: meetingId, fileName: seg.fileName)
            if FileManager.default.fileExists(atPath: url.path),
                let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
                size > 0
            {
                return true
            }
        }
        return false
    }

    private func updateItemStatus(itemId: UUID, to status: ItemStatus) {
        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? modelContext.fetch(descriptor).first else { return }
        item.status = status
        try? modelContext.save()
    }

    private func updateItemOnStop(
        sampleRate: Double,
        inputPortType: String,
        inputPortName: String
    ) {
        let context = modelContext
        guard let itemId = savedItemId else { return }

        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? context.fetch(descriptor).first else { return }

        let effectiveDuration = elapsedTime - pausedDuration
        let hasAudio = hasValidAudioData(meetingId: itemId)

        if hasAudio {
            item.status = .preparingAudio
            item.durationSeconds = effectiveDuration
            item.audioFileRelativePath = AppFileConstants.audioFileName
            // Persist audio capture metadata for UI display and diagnostics
            item.audioSampleRate = sampleRate > 0 ? sampleRate : nil
            item.audioChannelCount = 1  // Always mono in current implementation
            item.audioInputPortType = inputPortType
            item.audioInputPortName = inputPortName.isEmpty ? nil : inputPortName
            AppLog.audio.info("Item finalized: \(item.id) hasAudio=true duration=\(effectiveDuration)s sampleRate=\(Int(sampleRate))Hz input=\(inputPortType)")
        } else {
            // No valid audio data found — mark as failed, don't pretend it was recorded
            item.status = .failed
            AppLog.audio.warning("Item finalized: \(item.id) hasAudio=false — marking as failed")
        }

        do {
            try context.save()
            AppLog.audio.info("Item updated: \(item.id)")
        } catch {
            AppLog.error("audio", "Failed to save item update: \(error.localizedDescription)")
        }
    }
}
