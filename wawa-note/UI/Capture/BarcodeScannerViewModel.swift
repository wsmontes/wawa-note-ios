import AVFoundation
import SwiftData
import SwiftUI
import WawaNoteCore

// Related JIRA: KAN-542

// MARK: - Barcode Scanner ViewModel

@MainActor
final class BarcodeScannerViewModel: ObservableObject {
  @Published var scannedCodes: [ScannedCode] = []
  @Published var latestCode: ScannedCode?
  @Published var isScanning = false
  @Published var error: String?
  @Published var flashOn = false

  private let captureController = BarcodeCaptureController()
  private var scannedValues: Set<String> = []
  private var scanCooldown: [String: Date] = [:]
  private let cooldownInterval: TimeInterval = 3.0
  private var isReady = false

  var session: AVCaptureSession { captureController.session }

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
    scannedCodes = []
    scannedValues = []
    scanCooldown = [:]
    latestCode = nil
    error = nil

    let delegate = CaptureSessionDelegate { [weak self] value, symbology in
      Task { @MainActor [weak self] in
        self?.handleDetection(value: value, symbology: symbology)
      }
    }
    captureController.start(delegate: delegate)
    isScanning = true
  }

  func stopScanning() {
    captureController.stop()
    isScanning = false
  }

  func toggleFlash() {
    let requestedState = !flashOn
    Task {
      flashOn = await captureController.setTorch(enabled: requestedState)
    }
  }

  // MARK: - Detection

  private func handleDetection(value: String, symbology: String) {
    let now = Date()
    guard !scannedValues.contains(value) else { return }
    if let last = scanCooldown[value], now.timeIntervalSince(last) < cooldownInterval { return }

    scannedValues.insert(value)
    scanCooldown[value] = now

    let type: ScannedCode.CodeType = {
      switch symbology {
      case "org.iso.QRCode": return .qr
      case let s where s.contains("EAN") || s.contains("Code") || s.contains("UPCE"):
        return .barcode
      default: return .other
      }
    }()

    let code = ScannedCode(
      value: value, type: type, symbology: symbology, index: scannedCodes.count + 1)
    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
      scannedCodes.append(code)
      latestCode = code
    }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  // MARK: - Output

  func buildSession() -> ScanSession {
    var s = ScanSession()
    for code in scannedCodes { s.add(code) }
    s.finish()
    return s
  }

  func saveAsKnowledgeItem(title: String?, context: ModelContext) -> KnowledgeItem? {
    let count = scannedCodes.count
    guard count > 0 else { return nil }
    let svc = KnowledgeItemService(context: context)
    let itemTitle = title ?? "Scanned \(count) code\(count == 1 ? "" : "s")"
    let body = buildSession().toTextDocument()
    let json = buildSession().toJSON()

    guard
      let item = try? svc.createItem(
        type: .note, title: itemTitle, bodyText: body, tags: ["scanned", "barcode"],
        inboxDate: Date())
    else { return nil }

    let dir = FileArtifactStore().itemDirectoryURL(for: item.id)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? json.write(to: dir.appendingPathComponent("codes.json"), atomically: true, encoding: .utf8)
    return item
  }
}

// MARK: - Capture Session Controller

private enum BarcodeCaptureError: LocalizedError {
  case cameraUnavailable
  case inputUnavailable
  case cannotAddInput
  case cannotAddOutput

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable: "Camera not available"
    case .inputUnavailable: "Cannot create camera input"
    case .cannotAddInput: "Cannot add camera input"
    case .cannotAddOutput: "Cannot add metadata output"
    }
  }
}

/// Owns all AVCaptureSession mutation on one serial queue. The preview layer may
/// read `session`, but configuration, start/stop, delegate setup, and torch
/// changes never race each other.
private final class BarcodeCaptureController: @unchecked Sendable {
  let session = AVCaptureSession()

  private let output = AVCaptureMetadataOutput()
  private let queue = DispatchQueue(label: "com.wawa-note.barcode.capture", qos: .userInitiated)
  private var isConfigured = false
  private var sessionDelegate: CaptureSessionDelegate?

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

  func start(delegate: CaptureSessionDelegate) {
    queue.async { [self] in
      sessionDelegate = delegate
      output.setMetadataObjectsDelegate(delegate, queue: queue)
      guard isConfigured, !session.isRunning else { return }
      session.startRunning()
    }
  }

  func stop() {
    queue.async { [self] in
      if session.isRunning {
        session.stopRunning()
      }
      output.setMetadataObjectsDelegate(nil, queue: nil)
      sessionDelegate = nil
    }
  }

  func setTorch(enabled: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        guard
          let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back),
          device.hasTorch
        else {
          continuation.resume(returning: false)
          return
        }

        do {
          try device.lockForConfiguration()
          defer { device.unlockForConfiguration() }
          device.torchMode = enabled ? .on : .off
          continuation.resume(returning: device.torchMode == .on)
        } catch {
          continuation.resume(returning: false)
        }
      }
    }
  }

  private func configureIfNeeded() throws {
    guard !isConfigured else { return }
    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else {
      throw BarcodeCaptureError.cameraUnavailable
    }

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch {
      throw BarcodeCaptureError.inputUnavailable
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    guard session.canAddInput(input) else { throw BarcodeCaptureError.cannotAddInput }
    session.addInput(input)

    guard session.canAddOutput(output) else { throw BarcodeCaptureError.cannotAddOutput }
    session.addOutput(output)

    let requestedTypes: [AVMetadataObject.ObjectType] = [
      .qr, .aztec, .code128, .code39, .code39Mod43, .code93,
      .dataMatrix, .ean8, .ean13, .itf14, .pdf417, .upce,
    ]
    output.metadataObjectTypes = requestedTypes.filter(output.availableMetadataObjectTypes.contains)
    isConfigured = true
  }
}

// MARK: - Delegate

private final class CaptureSessionDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate,
  @unchecked Sendable
{
  let onDetection: @Sendable (String, String) -> Void
  init(onDetection: @escaping @Sendable (String, String) -> Void) {
    self.onDetection = onDetection
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput objects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
      let value = obj.stringValue, !value.isEmpty
    else { return }
    onDetection(value, obj.type.rawValue)
  }
}
