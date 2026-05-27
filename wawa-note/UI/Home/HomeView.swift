import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct HomeView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var showRecording = false
    @State private var navigateToMeeting: MeetingModel?
    @State private var showFilePicker = false
    @State private var pendingImport: ImportPending?
    @State private var importError: String?

    private let importService = AudioImportService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(.wawaSymbolGradient)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)

                Text(AppCopy.homeValueProp)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PrimaryActionButton(
                    title: AppCopy.startRecordingButton,
                    systemImage: "record.circle.fill"
                ) {
                    showRecording = true
                }
                .padding(.horizontal, 32)
                .tint(.red)

                Button {
                    showFilePicker = true
                } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)

                Spacer()
            }
            .fullScreenCover(isPresented: $showRecording) {
                RecordView(coordinator: coordinator) { meeting in
                    showRecording = false
                    navigateToMeeting = meeting
                }
            }
            .navigationDestination(item: $navigateToMeeting) { meeting in
                MeetingDetailView(meeting: meeting)
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: AudioImportService.supportedUTTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
            .sheet(item: $pendingImport) { item in
                ImportFormView(sourceURL: item.url, metadata: item.metadata, isFromShareExtension: item.isFromShareExtension) { meeting in
                    pendingImport = nil
                    navigateToMeeting = meeting
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .alert("Import Error", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - File picker

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importError = "No file was selected."
                return
            }

            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            guard importService.canRead(url: url) else {
                importError = "This file format is not supported. Use MP3, WAV, M4A, MP4, or MOV files."
                return
            }

            // Copy to temp NOW while security scope is still active.
            // Task closures run later; the defer would have already released the scope.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                importError = "Could not copy file: \(error.localizedDescription)"
                return
            }

            Task {
                do {
                    let metadata = try await importService.extractMetadata(url: tempURL)
                    await MainActor.run {
                        pendingImport = ImportPending(url: tempURL, metadata: metadata, isFromShareExtension: false)
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    // MARK: - Incoming URL (from Share Extension)

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "wawanote" else { return }

        let shared = UserDefaults(suiteName: "group.com.wawa-note")
        guard let filename = shared?.string(forKey: "pendingImportFile") else {
            AppLog.general.info("No pending import file in App Group")
            return
        }

        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else {
            importError = "Could not access shared storage."
            return
        }

        let fileURL = containerURL.appendingPathComponent("shared").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            importError = "Shared file no longer available."
            shared?.removeObject(forKey: "pendingImportFile")
            return
        }

        guard importService.canRead(url: fileURL) else {
            importError = "This file format is not supported. Try converting to MP3 or M4A first."
            try? FileManager.default.removeItem(at: fileURL)
            shared?.removeObject(forKey: "pendingImportFile")
            return
        }

        Task {
            do {
                let metadata = try await importService.extractMetadata(url: fileURL)
                await MainActor.run {
                    pendingImport = ImportPending(url: fileURL, metadata: metadata, isFromShareExtension: true)
                    shared?.removeObject(forKey: "pendingImportFile")
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                }
            }
        }
    }
}

struct ImportPending: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: ImportMetadata
    let isFromShareExtension: Bool
}
