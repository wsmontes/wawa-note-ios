import AVFoundation
import SwiftData
import SwiftUI

// MARK: - Barcode Scanner ViewModel

@MainActor
final class BarcodeScannerViewModel: ObservableObject {
    @Published var scannedCodes: [ScannedCode] = []
    @Published var latestCode: ScannedCode?
    @Published var isScanning = false
    @Published var error: String?
    @Published var flashOn = false

    let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private var scannedValues: Set<String> = []
    private var scanCooldown: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 3.0

    // Must be held strongly or the delegate callback never fires
    private var sessionDelegate: CaptureSessionDelegate?

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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            error = "Camera not available"
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            error = "Cannot create camera input"
            return
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            error = "Cannot add camera input"
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            error = "Cannot add metadata output"
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        output.metadataObjectTypes = [
            .qr, .aztec, .code128, .code39, .code39Mod43, .code93,
            .dataMatrix, .ean8, .ean13, .itf14, .pdf417, .upce,
        ]

        session.commitConfiguration()
    }

    // MARK: - Control

    func startScanning() {
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
        self.sessionDelegate = delegate
        output.setMetadataObjectsDelegate(delegate, queue: DispatchQueue(label: "barcode.queue"))

        // Capture session reference before async block
        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            s.startRunning()
            Task { @MainActor in }
        }
        isScanning = true
    }

    func stopScanning() {
        session.stopRunning()
        isScanning = false
    }

    func toggleFlash() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            device.hasTorch
        else { return }
        try? device.lockForConfiguration()
        flashOn.toggle()
        device.torchMode = flashOn ? .on : .off
        device.unlockForConfiguration()
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
            case let s where s.contains("EAN") || s.contains("Code") || s.contains("UPCE"): return .barcode
            default: return .other
            }
        }()

        let code = ScannedCode(value: value, type: type, symbology: symbology, index: scannedCodes.count + 1)
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

        guard let item = try? svc.createItem(type: .note, title: itemTitle, bodyText: body, tags: ["scanned", "barcode"], inboxDate: Date()) else { return nil }

        let dir = FileArtifactStore().itemDirectoryURL(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: dir.appendingPathComponent("codes.json"), atomically: true, encoding: .utf8)
        return item
    }
}

// MARK: - Delegate

private final class CaptureSessionDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let onDetection: (String, String) -> Void
    init(onDetection: @escaping (String, String) -> Void) { self.onDetection = onDetection }

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
