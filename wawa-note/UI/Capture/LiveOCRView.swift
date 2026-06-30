import SwiftData
import SwiftUI

// Related JIRA: KAN-136

// MARK: - Live OCR Scanner View

/// Real-time OCR: points camera at text and captures continuously.
/// Accumulates recognized text into a running document.
struct LiveOCRView: View {
    @StateObject private var viewModel = LiveOCRViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var titleText = ""
    @State private var showSaveSheet = false
    @State private var savedItem: KnowledgeItem?
    @State private var showClearConfirm = false
    @State private var textCopied = false

    var body: some View {
        ZStack {
            // Camera preview
            BarcodeCameraPreview(session: viewModel.session)
                .ignoresSafeArea()

            // Dim overlay with focus region
            scannerOverlay

            // UI overlay
            VStack(spacing: 0) {
                topBar
                Spacer()
                textAccumulationPanel
                bottomBar
            }
        }
        .statusBarHidden()
        .task {
            await viewModel.setup()
            viewModel.startScanning()
            titleText = "Live OCR — \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        .onDisappear { viewModel.stopScanning() }
        .alert("Clear All?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { viewModel.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                viewModel.stopScanning()
                if viewModel.accumulatedText.isEmpty { dismiss() } else { showSaveSheet = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text(viewModel.accumulatedText.isEmpty ? "Cancel" : "Done")
                }
                .font(.body).fontWeight(.medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Stats
            if viewModel.isScanning {
                HStack(spacing: 8) {
                    // Motion state indicator
                    VStack(spacing: 1) {
                        Image(systemName: motionIcon)
                            .font(.caption).foregroundStyle(motionColor)
                        Text(motionLabel)
                            .font(.system(size: 8)).foregroundStyle(motionColor)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(motionColor.opacity(0.12), in: Capsule())

                    // Word/char count
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.isPaused ? "pause.circle.fill" : "text.viewfinder")
                                .foregroundStyle(viewModel.isPaused ? .orange : .blue)
                                .font(.caption2)
                            Text("\(viewModel.wordCount)")
                                .font(.title3).fontWeight(.bold).monospacedDigit()
                                .contentTransition(.numericText())
                            Text("w")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if !viewModel.sections.isEmpty {
                            Text("\(viewModel.sections.count) section\(viewModel.sections.count == 1 ? "" : "s")")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // Pause
            Button {
                viewModel.togglePause()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.body)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Scanner Overlay

    private var scannerOverlay: some View {
        GeometryReader { geo in
            let h: CGFloat = geo.size.height * 0.55
            let rect = CGRect(
                x: 20,
                y: (geo.size.height - h) / 2,
                width: geo.size.width - 40,
                height: h
            )

            ZStack {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.4)))
                    context.blendMode = .destinationOut
                    context.fill(Path(roundedRect: rect, cornerRadius: 14), with: .color(.white))
                }
                .compositingGroup()

                // Guide text
                if viewModel.accumulatedText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 32)).foregroundStyle(.white.opacity(0.6))
                        Text("Point camera at text")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    .position(x: rect.midX, y: rect.midY)
                }

                // Border
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.3), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Latest Segment

    private var latestSegmentBanner: some View {
        Group {
            if let segment = viewModel.latestSegment, viewModel.isScanning, !viewModel.isPaused {
                Text(segment)
                    .font(.caption)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: viewModel.latestSegment)
            }
        }
    }

    // MARK: - Text Accumulation Panel

    private var textAccumulationPanel: some View {
        VStack(spacing: 8) {
            latestSegmentBanner

            if !viewModel.accumulatedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Captured Text")
                            .font(.caption).fontWeight(.semibold)
                        Spacer()
                        Button {
                            showClearConfirm = true
                        } label: {
                            Text("Clear").font(.caption2).foregroundStyle(.red)
                        }
                    }
                    ScrollView {
                        Text(viewModel.accumulatedText)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Spacer()

            if !viewModel.accumulatedText.isEmpty {
                Button {
                    viewModel.stopScanning()
                    showSaveSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Finish & Save")
                            .fontWeight(.semibold)
                        Text("(\(viewModel.wordCount)w)")
                            .font(.caption).monospacedDigit()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
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
                    LabeledContent("Words", value: "\(viewModel.wordCount)")
                    LabeledContent("Characters", value: "\(viewModel.charCount)")
                }

                Section("Item Title") {
                    TextField("Title", text: $titleText)
                }

                Section {
                    ZStack(alignment: .topTrailing) {
                        ScrollView {
                            Text(viewModel.accumulatedText.isEmpty ? "No text captured." : viewModel.accumulatedText)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = viewModel.accumulatedText
                            textCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                textCopied = false
                            }
                        }

                        if textCopied {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark")
                                Text("Copied!")
                            }
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3), value: textCopied)
                } header: {
                    HStack {
                        Text("Captured Text")
                        Spacer()
                        Text("Tap to copy").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Save OCR Session")
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
                    .disabled(viewModel.accumulatedText.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Motion state helpers

    private var motionIcon: String {
        switch viewModel.motionState {
        case .stable: "scope"
        case .panning: "hand.draw"
        case .shifting: "arrow.triangle.swap"
        }
    }

    private var motionColor: Color {
        switch viewModel.motionState {
        case .stable: .green
        case .panning: .blue
        case .shifting: .orange
        }
    }

    private var motionLabel: String {
        switch viewModel.motionState {
        case .stable: "Reading"
        case .panning: "Scanning"
        case .shifting: "Break"
        }
    }
}
