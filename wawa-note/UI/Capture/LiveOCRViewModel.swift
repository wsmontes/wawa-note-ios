import AVFoundation
import CoreMotion
import SwiftData
import SwiftUI
import Vision
import WawaNoteCore

// Related JIRA: KAN-542

// MARK: - Motion State

enum MotionState: String {
  case stable, panning, shifting
}

// MARK: - Tracked Region

struct TrackedRegion: Equatable {
  let normalizedRect: CGRect
  var text: String
  var confidence: Float
  var lastSeenFrame: Int
  var stabilityCount: Int
  var center: CGPoint { CGPoint(x: normalizedRect.midX, y: normalizedRect.midY) }
  func iou(with other: TrackedRegion) -> CGFloat {
    let i = normalizedRect.intersection(other.normalizedRect)
    guard !i.isNull else { return 0 }
    let u = normalizedRect.union(other.normalizedRect)
    guard u.width * u.height > 0 else { return 0 }
    return (i.width * i.height) / (u.width * u.height)
  }
}

// MARK: - Document Section

struct DocumentSection: Identifiable {
  let id = UUID()
  var lines: [String] = []
  var capturedAt: Date
}

private struct OCRCandidate: Sendable {
  let normalizedRect: CGRect
  let text: String
  let confidence: Float
}

// MARK: - Live OCR ViewModel

@MainActor
final class LiveOCRViewModel: ObservableObject {
  @Published var accumulatedText: String = ""
  @Published var sections: [DocumentSection] = []
  @Published var wordCount = 0
  @Published var charCount = 0
  @Published var latestSegment: String?
  @Published var isScanning = false
  @Published var isPaused = false
  @Published var motionState: MotionState = .stable
  @Published var error: String?

  private let captureController = LiveOCRCaptureController()
  private var isReady = false

  var session: AVCaptureSession { captureController.session }

  // Tracking — accessed only on MainActor now
  private var trackedRegions: [TrackedRegion] = []
  private var frameCount = 0
  private let iouThreshold: CGFloat = 0.4
  private let stabilityThreshold = 3
  private var lastProcessTime: Date = .distantPast
  private let processInterval: TimeInterval = 0.2

  // Motion
  private let motionManager = CMMotionManager()
  private var lastAccel: CMAcceleration = CMAcceleration(x: 0, y: 0, z: 0)
  private let stableG: Double = 0.02
  private let shiftG: Double = 0.15

  // MARK: - Setup

  func setup() async {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized: break
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        error = "Camera access denied"
        return
      }
    case .denied, .restricted:
      error = "Camera access denied. Enable in Settings > Privacy > Camera."
      return
    @unknown default:
      error = "Camera not available"
      return
    }

    do {
      try await captureController.configure()
      isReady = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - Control

  func startScanning() {
    guard isReady else { return }
    accumulatedText = ""
    sections = []
    wordCount = 0
    charCount = 0
    latestSegment = nil
    trackedRegions = []
    frameCount = 0
    isPaused = false
    error = nil

    let delegate = OCRVideoDelegate { [weak self] observations in
      Task { @MainActor [weak self] in
        self?.processFrame(observations)
      }
    }
    startMotion()
    captureController.start(delegate: delegate)
    isScanning = true
  }

  func stopScanning() {
    motionManager.stopDeviceMotionUpdates()
    captureController.stop()
    isScanning = false
  }

  func togglePause() { isPaused.toggle() }

  func clear() {
    accumulatedText = ""
    sections = []
    wordCount = 0
    charCount = 0
    latestSegment = nil
    trackedRegions = []
  }

  // MARK: - Motion

  private func startMotion() {
    guard motionManager.isDeviceMotionAvailable else { return }
    motionManager.deviceMotionUpdateInterval = 0.1
    motionManager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
      guard let self, let accel = m?.userAcceleration else { return }
      let delta = sqrt(
        pow(accel.x - self.lastAccel.x, 2) + pow(accel.y - self.lastAccel.y, 2)
          + pow(accel.z - self.lastAccel.z, 2))
      self.lastAccel = CMAcceleration(x: accel.x, y: accel.y, z: accel.z)
      let new: MotionState =
        delta < self.stableG ? .stable : delta < self.shiftG ? .panning : .shifting
      if new != self.motionState {
        self.motionState = new
        if new == .shifting && !self.accumulatedText.isEmpty {
          if !self.accumulatedText.hasSuffix("\n\n---\n\n") {
            self.accumulatedText += "\n\n---\n\n"
          }
        }
      }
    }
  }

  // MARK: - Frame Processing (runs on MainActor via Task)

  private func processFrame(_ observations: [OCRCandidate]) {
    guard !isPaused else { return }
    let now = Date()
    guard now.timeIntervalSince(lastProcessTime) >= processInterval else { return }
    lastProcessTime = now
    frameCount += 1

    let candidates: [TrackedRegion] = observations.map { observation in
      return TrackedRegion(
        normalizedRect: observation.normalizedRect,
        text: observation.text,
        confidence: observation.confidence,
        lastSeenFrame: frameCount, stabilityCount: 1)
    }

    var newLines: [String] = []

    for c in candidates {
      var bestIdx: Int?
      var bestIOU: CGFloat = 0
      for j in 0..<trackedRegions.count {
        let iou = c.iou(with: trackedRegions[j])
        if iou > bestIOU, iou >= iouThreshold {
          bestIOU = iou
          bestIdx = j
        }
      }
      if let idx = bestIdx {
        let old = trackedRegions[idx].text
        trackedRegions[idx].text = c.text
        trackedRegions[idx].confidence = c.confidence
        trackedRegions[idx].lastSeenFrame = frameCount
        trackedRegions[idx].stabilityCount += 1
        if c.text != old, trackedRegions[idx].stabilityCount >= stabilityThreshold {
          newLines.append(c.text)
        }
      } else {
        trackedRegions.append(c)
      }
    }

    trackedRegions.removeAll { frameCount - $0.lastSeenFrame > 15 }

    guard !newLines.isEmpty else { return }

    let state = motionState
    for line in newLines {
      let recent = String(accumulatedText.suffix(500))
      switch state {
      case .shifting:
        if !accumulatedText.contains(line) { accumulatedText += line + "\n" }
      case .panning:
        if !accumulatedText.contains(line) { accumulatedText += line + "\n" }
      case .stable:
        if !recent.contains(line) { accumulatedText += line + "\n" }
      }
    }

    if sections.isEmpty {
      sections.append(DocumentSection(lines: newLines, capturedAt: Date()))
    } else {
      sections[sections.count - 1].lines.append(contentsOf: newLines)
    }

    latestSegment = newLines.first
    updateCounts()
  }

  private func updateCounts() {
    let t = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    wordCount = t.isEmpty ? 0 : t.split(separator: " ").count
    charCount = t.count
  }

  // MARK: - Output

  func buildDocument() -> String {
    var lines: [String] = []
    lines.append("# Live OCR — \(Date().formatted(date: .complete, time: .standard))")
    lines.append("")
    if sections.count > 1 {
      lines.append("\(sections.count) sections detected via motion context switching")
      lines.append("")
    }
    lines.append(accumulatedText)
    lines.append("")
    lines.append("---")
    lines.append("\(wordCount) words · \(charCount) characters · \(sections.count) section(s)")
    return lines.joined(separator: "\n")
  }

  func saveAsKnowledgeItem(title: String?, context: ModelContext) -> KnowledgeItem? {
    guard !accumulatedText.isEmpty else { return nil }
    let svc = KnowledgeItemService(context: context)
    let t = title ?? "Live OCR — \(Date().formatted(date: .abbreviated, time: .shortened))"
    let body = buildDocument()
    guard
      let item = try? svc.createItem(
        type: .note, title: t, bodyText: body, tags: ["ocr", "live-scan"], inboxDate: Date())
    else { return nil }
    let dir = FileArtifactStore().itemDirectoryURL(for: item.id)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let md: [String: Any] = [
      "wordCount": wordCount, "charCount": charCount, "sectionCount": sections.count,
      "capturedAt": Date().ISO8601Format(),
    ]
    if let d = try? JSONSerialization.data(withJSONObject: md, options: .prettyPrinted),
      let j = String(data: d, encoding: .utf8)
    {
      try? j.write(
        to: dir.appendingPathComponent("ocr_metadata.json"), atomically: true, encoding: .utf8)
    }
    return item
  }
}

// MARK: - Capture Session Controller

private enum LiveOCRCaptureError: LocalizedError {
  case cameraUnavailable
  case inputUnavailable
  case cannotAddInput
  case cannotAddOutput

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable: "Camera not available"
    case .inputUnavailable: "Cannot create camera input"
    case .cannotAddInput: "Cannot add camera input"
    case .cannotAddOutput: "Cannot add video output"
    }
  }
}

/// Serializes every AVCaptureSession mutation and owns the video delegate for
/// the lifetime of the running session.
private final class LiveOCRCaptureController: @unchecked Sendable {
  let session = AVCaptureSession()

  private let videoOutput = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "com.wawa-note.ocr.capture", qos: .userInitiated)
  private var isConfigured = false
  private var ocrDelegate: OCRVideoDelegate?

  func configure() async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          try configureIfNeeded()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func start(delegate: OCRVideoDelegate) {
    queue.async { [self] in
      ocrDelegate = delegate
      videoOutput.setSampleBufferDelegate(delegate, queue: queue)
      guard isConfigured, !session.isRunning else { return }
      session.startRunning()
    }
  }

  func stop() {
    queue.async { [self] in
      if session.isRunning {
        session.stopRunning()
      }
      videoOutput.setSampleBufferDelegate(nil, queue: nil)
      ocrDelegate = nil
    }
  }

  private func configureIfNeeded() throws {
    guard !isConfigured else { return }
    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else {
      throw LiveOCRCaptureError.cameraUnavailable
    }

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch {
      throw LiveOCRCaptureError.inputUnavailable
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .high

    guard session.canAddInput(input) else { throw LiveOCRCaptureError.cannotAddInput }
    session.addInput(input)

    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    guard session.canAddOutput(videoOutput) else { throw LiveOCRCaptureError.cannotAddOutput }
    session.addOutput(videoOutput)

    if device.isFocusModeSupported(.continuousAutoFocus) {
      do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.focusMode = .continuousAutoFocus
        if device.isAutoFocusRangeRestrictionSupported {
          device.autoFocusRangeRestriction = .near
        }
      } catch {
        // Focus tuning is optional; the capture session remains usable.
      }
    }

    isConfigured = true
  }
}

// MARK: - OCR Video Delegate

private final class OCRVideoDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  let onObservations: @Sendable ([OCRCandidate]) -> Void
  private var lastTime: TimeInterval = 0

  init(onObservations: @escaping @Sendable ([OCRCandidate]) -> Void) {
    self.onObservations = onObservations
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let now = CACurrentMediaTime()
    guard now - lastTime >= 0.2 else { return }
    lastTime = now

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let request = VNRecognizeTextRequest { [weak self] req, err in
      guard err == nil, let obs = req.results as? [VNRecognizedTextObservation] else { return }
      let candidates = obs.compactMap { observation -> OCRCandidate? in
        guard let top = observation.topCandidates(1).first, top.confidence > 0.3 else {
          return nil
        }
        let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return OCRCandidate(
          normalizedRect: observation.boundingBox,
          text: text,
          confidence: top.confidence)
      }
      self?.onObservations(candidates)
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US", "pt-BR", "es-ES"]

    try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
  }
}
