import AVFoundation
import PDFKit
import SwiftData
import SwiftUI

// MARK: - Import kind

enum ImportKind {
  case audio(ImportMetadata)
  case text(TextImportPreview)
}

struct TextImportPreview {
  let formatIdentifier: String
  let displayName: String
  let suggestedTitle: String
  let fileSize: Int64
  let creationDate: Date?
  let textSnippet: String
}

extension ImportKind: Equatable {
  static func == (lhs: ImportKind, rhs: ImportKind) -> Bool {
    switch (lhs, rhs) {
    case (.audio, .audio): return true
    case (.text, .text): return true
    default: return false
    }
  }
}

// MARK: - Import form

struct ImportFormView: View {
  @EnvironmentObject private var coordinator: RecordingCoordinator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let sourceURL: URL
  let kind: ImportKind
  let textImporter: (any FormatImporter)?
  let onComplete: (KnowledgeItem) -> Void
  let isFromShareExtension: Bool

  @State private var title: String
  @State private var date: Date
  @State private var selectedLocale = TranscriptionLocaleProvider.bestGuessLocale
  @State private var isConverting = false
  @State private var conversionPhase: String?
  @State private var errorMessage: String?
  @State private var player: AVAudioPlayer?

  private let importService = AudioImportService()
  private let artifactStore = FileArtifactStore()

  init(
    sourceURL: URL,
    kind: ImportKind,
    textImporter: (any FormatImporter)? = nil,
    isFromShareExtension: Bool = false,
    onComplete: @escaping (KnowledgeItem) -> Void
  ) {
    self.sourceURL = sourceURL
    self.kind = kind
    self.textImporter = textImporter
    self.isFromShareExtension = isFromShareExtension
    self.onComplete = onComplete

    let defaultTitle: String
    let defaultDate: Date?

    switch kind {
    case .audio(let meta):
      defaultTitle = meta.suggestedTitle
      defaultDate = meta.creationDate
    case .text(let preview):
      defaultTitle = preview.suggestedTitle
      defaultDate = preview.creationDate
    }

    _title = State(initialValue: defaultTitle)
    _date = State(initialValue: defaultDate ?? Date())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title)
          DatePicker("Date", selection: $date)
          if isAudio {
            Picker("Language", selection: $selectedLocale) {
              ForEach(availableLocales, id: \.id) { locale in
                Text(locale.name).tag(locale.id)
              }
            }
          }
        } header: {
          Text(isAudio ? "Audio Info" : "Note Info")
        }

        Section("File Info") {
          fileInfoContent
        }

        Section("Preview") {
          previewContent
        }

        if let error = errorMessage {
          Section {
            Text(error)
              .foregroundStyle(.red)
              .font(.caption)
          }
        }

        Section {
          Button {
            performImport()
          } label: {
            if isConverting {
              HStack {
                ProgressView()
                Text(conversionPhase ?? "Processing...")
                  .padding(.leading, 8)
              }
              .frame(maxWidth: .infinity)
            } else {
              Label(confirmLabel, systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
            }
          }
          .disabled(title.isEmpty || isConverting)
        }
      }
      .navigationTitle(navTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear {
        if isAudio {
          player = importService.previewPlayer(for: sourceURL)
        }
      }
      .onDisappear {
        player?.stop()
      }
    }
  }

  // MARK: - Labels

  private var isAudio: Bool {
    if case .audio = kind { return true }
    return false
  }

  private var navTitle: String {
    isAudio ? "Import Audio" : "Import Note"
  }

  private var confirmLabel: String {
    isAudio ? "Import Audio" : "Import Note"
  }

  // MARK: - File info

  @ViewBuilder
  private var fileInfoContent: some View {
    switch kind {
    case .audio(let meta):
      LabeledContent("Duration", value: formatDuration(meta.duration))
      LabeledContent("Format", value: meta.format)
      LabeledContent(
        "Size", value: ByteCountFormatter.string(fromByteCount: meta.fileSize, countStyle: .file))

    case .text(let preview):
      LabeledContent("Type", value: preview.displayName)
      LabeledContent(
        "Size", value: ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file)
      )
    }
  }

  // MARK: - Preview

  @ViewBuilder
  private var previewContent: some View {
    switch kind {
    case .audio:
      Button {
        togglePreview()
      } label: {
        Label(
          player?.isPlaying == true ? "Stop" : "Play",
          systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
      }
      .disabled(player == nil)

    case .text(let preview):
      VStack(alignment: .leading, spacing: 4) {
        Text(preview.textSnippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(12)
        if !preview.textSnippet.isEmpty {
          Text("First \(preview.textSnippet.count) characters")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func togglePreview() {
    guard let player else { return }
    if player.isPlaying { player.pause() } else { player.play() }
  }

  // MARK: - Import

  private func performImport() {
    switch kind {
    case .audio:
      performAudioImport()
    case .text:
      performTextImport()
    }
  }

  private func performAudioImport() {
    isConverting = true
    errorMessage = nil
    conversionPhase = "Preparing file..."

    guard case .audio(let meta) = kind else { return }

    guard
      let item = coordinator.createItemFromImport(
        title: title,
        date: date,
        duration: meta.duration,
        languageCode: selectedLocale
      )
    else {
      errorMessage = "Could not create item."
      isConverting = false
      return
    }

    let itemId = item.id
    AppLog.transcription.info(
      "🔤 ImportFormView: created item \(itemId.uuidString.prefix(8)) with languageCode=\(selectedLocale)"
    )

    Task { @MainActor in
      do {
        if !importService.isNativeM4ACompatible(sourceURL) {
          conversionPhase = "Converting to app format..."
        }
        try await importService.storeAudio(
          sourceURL: sourceURL, itemID: itemId, using: artifactStore)

        cleanupSourceFiles(sourceURL: sourceURL, isFromShareExtension: isFromShareExtension)

        isConverting = false
        conversionPhase = nil
        onComplete(item)
        dismiss()
      } catch {
        coordinator.deleteItem(itemId)
        errorMessage = error.localizedDescription
        isConverting = false
        conversionPhase = nil
      }
    }
  }

  private func performTextImport() {
    guard let importer = textImporter else {
      errorMessage = "No importer available for this file type."
      return
    }

    isConverting = true
    conversionPhase = "Reading file..."
    errorMessage = nil

    Task {
      do {
        // Use the FormatImporter to properly transform content
        let result = try await importer.importFromURL(sourceURL)
        let item = result.knowledgeItem

        // Apply user's edits on top of importer result
        item.title = title
        item.createdAt = date

        await MainActor.run {
          modelContext.insert(item)
          try? modelContext.save()

          isConverting = false
          conversionPhase = nil
          onComplete(item)
          dismiss()
        }
      } catch {
        await MainActor.run {
          errorMessage = "Import failed: \(error.localizedDescription)"
          isConverting = false
          conversionPhase = nil
        }
      }
    }
  }

  // MARK: - Locale data

  private var availableLocales: [(id: String, name: String)] {
    TranscriptionLocaleProvider.availableLocales
  }

  // MARK: - Helpers

  private func cleanupSourceFiles(sourceURL: URL, isFromShareExtension: Bool) {
    if sourceURL.path.contains(NSTemporaryDirectory()) {
      try? FileManager.default.removeItem(at: sourceURL)
    }
    if isFromShareExtension {
      try? FileManager.default.removeItem(at: sourceURL)
      let shared = UserDefaults(suiteName: "group.com.wawa-note")
      shared?.removeObject(forKey: "pendingImportFiles")
    }
  }

  private func formatDuration(_ interval: TimeInterval) -> String {
    let m = Int(interval) / 60
    let s = Int(interval) % 60
    return "\(m)m \(s)s"
  }
}
