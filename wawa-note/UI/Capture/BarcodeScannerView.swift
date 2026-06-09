import SwiftUI
import AVFoundation

// MARK: - Barcode Scanner View

/// Full-screen barcode/QR scanner with live camera preview and scanned code overlay.
struct BarcodeScannerView: View {
    @StateObject private var viewModel = BarcodeScannerViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var titleText = ""
    @State private var showSaveSheet = false
    @State private var savedItem: KnowledgeItem?
    @State private var copiedCodeID: UUID?
    @State private var copiedSheetCodeID: UUID?

    var body: some View {
        ZStack {
            // Camera preview
            BarcodeCameraPreview(session: viewModel.session)
                .ignoresSafeArea()

            // Dim overlay with cutout
            scannerOverlay

            // UI overlay
            VStack(spacing: 0) {
                topBar
                Spacer()
                scannedCodePanel
                bottomBar
            }
        }
        .statusBarHidden()
        .task {
            await viewModel.setup()
            viewModel.startScanning()
            titleText = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        .onDisappear { viewModel.stopScanning() }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                viewModel.stopScanning()
                if viewModel.scannedCodes.isEmpty { dismiss() }
                else { showSaveSheet = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text(viewModel.scannedCodes.isEmpty ? "Cancel" : "Done")
                }
                .font(.body).fontWeight(.medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Counter badge
            if viewModel.isScanning {
                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                    Text("\(viewModel.scannedCodes.count)")
                        .font(.title3).fontWeight(.bold).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .animation(.default, value: viewModel.scannedCodes.count)
            }

            Spacer()

            // Flash toggle
            Button {
                viewModel.toggleFlash()
            } label: {
                Image(systemName: viewModel.flashOn ? "bolt.fill" : "bolt.slash")
                    .font(.body)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Scanner Overlay (dim with cutout)

    private var scannerOverlay: some View {
        GeometryReader { geo in
            let cutoutSize: CGFloat = min(geo.size.width, geo.size.height) * 0.6
            let rect = CGRect(
                x: (geo.size.width - cutoutSize) / 2,
                y: (geo.size.height - cutoutSize) / 2,
                width: cutoutSize,
                height: cutoutSize
            )

            ZStack {
                // Dim layer with cutout
                Canvas { context, size in
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.5))
                    )
                    context.blendMode = .destinationOut
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 16),
                        with: .color(.white)
                    )
                }
                .compositingGroup()

                // Corner brackets
                cornerBrackets(rect: rect)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cornerBrackets(rect: CGRect) -> some View {
        let w: CGFloat = 3
        let len: CGFloat = 30
        let color = Color.green

        Canvas { context, size in
            let path = Path { p in
                // Top-left
                p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
                // Top-right
                p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
                // Bottom-left
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))
                // Bottom-right
                p.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
            }
            context.stroke(path, with: .color(color), lineWidth: w)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Scanned Code Panel

    private var scannedCodePanel: some View {
        VStack(spacing: 0) {
            if let latest = viewModel.latestCode {
                let isURL = latest.detectedDataType == .url || latest.detectedDataType == .uri
                Button {
                    if isURL, let url = URL(string: latest.value) {
                        UIApplication.shared.open(url)
                    } else {
                        UIPasteboard.general.string = latest.value
                        copiedCodeID = latest.id
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedCodeID = nil }
                    }
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: isURL ? "safari" : latest.type.icon)
                                .font(.title3).foregroundStyle(isURL ? .blue : .green)
                            Text(latest.symbologyName)
                                .font(.caption).fontWeight(.semibold)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                            Text(latest.detectedDataType.label)
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.ultraThinMaterial, in: Capsule())
                            Spacer()
                            if copiedCodeID == latest.id {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                    Text("Copied")
                                }
                                .font(.caption2).fontWeight(.medium).foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                            } else {
                                HStack(spacing: 3) {
                                    Image(systemName: isURL ? "arrow.up.forward.app" : "doc.on.doc")
                                    Text(isURL ? "Tap to open" : "Tap to copy")
                                }
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        Text(latest.value)
                            .font(.subheadline).fontWeight(.medium)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.scannedCodes.count > 1 {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("+\(viewModel.scannedCodes.count - 1) more scanned")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .animation(.spring(response: 0.3), value: viewModel.latestCode?.id)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Spacer()

            // Preview last scan
            if viewModel.scannedCodes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.scannedCodes.suffix(5)) { code in
                            Text(code.value)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: 120)
            }

            Spacer()

            // Done button
            if !viewModel.scannedCodes.isEmpty {
                Button {
                    viewModel.stopScanning()
                    showSaveSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Finish")
                            .fontWeight(.semibold)
                        Text("(\(viewModel.scannedCodes.count))")
                            .font(.caption).monospacedDigit()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }

    // MARK: - Save Sheet

    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section("Session Info") {
                    LabeledContent("Codes Scanned", value: "\(viewModel.scannedCodes.count)")
                    if let first = viewModel.scannedCodes.first {
                        LabeledContent("First Scan", value: first.scannedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let last = viewModel.scannedCodes.last {
                        LabeledContent("Last Scan", value: last.scannedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }

                Section("Item Title") {
                    TextField("Title", text: $titleText)
                }

                Section {
                    ForEach(viewModel.scannedCodes.prefix(10)) { code in
                        Button {
                            UIPasteboard.general.string = code.value
                            copiedSheetCodeID = code.id
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedSheetCodeID = nil }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: code.type.icon)
                                    .font(.caption).foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(code.value)
                                        .font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    Text("[\(code.index)] \(code.symbologyName) · \(code.detectedDataType.label)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if copiedSheetCodeID == code.id {
                                    HStack(spacing: 3) {
                                        Image(systemName: "checkmark")
                                        Text("Copied!")
                                    }
                                    .font(.caption2).fontWeight(.medium).foregroundStyle(.green)
                                    .transition(.scale.combined(with: .opacity))
                                } else {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if viewModel.scannedCodes.count > 10 {
                        Text("+ \(viewModel.scannedCodes.count - 10) more codes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Scanned Codes — tap to copy")
                }
            }
            .navigationTitle("Save Scan Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.startScanning()
                        showSaveSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        savedItem = viewModel.saveAsKnowledgeItem(
                            title: titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : titleText,
                            context: modelContext
                        )
                        showSaveSheet = false
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(viewModel.scannedCodes.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Camera Preview (UIKit bridge)

struct BarcodeCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> BarcodePreviewView {
        let view = BarcodePreviewView()
        view.session = session
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: BarcodePreviewView, context: Context) {}
}

final class BarcodePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoGravity: AVLayerVideoGravity {
        get { (layer as! AVCaptureVideoPreviewLayer).videoGravity }
        set { (layer as! AVCaptureVideoPreviewLayer).videoGravity = newValue }
    }

    var session: AVCaptureSession? {
        get { (layer as! AVCaptureVideoPreviewLayer).session }
        set { (layer as! AVCaptureVideoPreviewLayer).session = newValue }
    }
}
