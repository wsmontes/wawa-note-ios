import SwiftUI
import UniformTypeIdentifiers

/// Settings view for anarlog folder sync configuration.
///
/// Allows the user to:
/// - Select a watched folder via document picker
/// - See sync status and statistics
/// - Toggle auto-import/export
/// - Trigger manual sync
/// - Import anarlog templates
/// - Export all items as anarlog .md files
struct AnarlogSyncSettingsView: View {
  @StateObject private var syncService = AnarlogSyncService()
  @State private var showingFolderPicker = false
  @State private var showingTemplateInfo = false
  @State private var statusMessage: String?

  var body: some View {
    List {
      // MARK: - Folder Selection
      Section {
        HStack {
          Label("Watched Folder", systemImage: "folder")
          Spacer()
          if syncService.hasWatchedFolder {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Text("Not set")
              .foregroundStyle(.secondary)
          }
        }

        Button {
          showingFolderPicker = true
        } label: {
          Label(
            syncService.hasWatchedFolder ? "Change Folder" : "Choose Folder",
            systemImage: "folder.badge.plus"
          )
        }

        if syncService.hasWatchedFolder {
          Button(role: .destructive) {
            syncService.clearBookmark()
          } label: {
            Label("Remove Folder", systemImage: "folder.badge.minus")
          }
        }
      } header: {
        Text("Shared Folder")
      } footer: {
        Text(
          "Choose the folder where anarlog stores its session notes. On desktop, this is typically ~/Documents/anarlog/. Sync this folder via iCloud Drive or Dropbox to access notes on both devices."
        )
      }

      // MARK: - Sync Status
      Section {
        HStack {
          Label("Last Sync", systemImage: "clock")
          Spacer()
          if let date = syncService.lastSyncDate {
            Text(date.formatted(date: .abbreviated, time: .shortened))
              .foregroundStyle(.secondary)
          } else {
            Text("Never")
              .foregroundStyle(.secondary)
          }
        }

        HStack {
          Label("Imported", systemImage: "arrow.down.circle")
          Spacer()
          Text("\(syncService.importedCount) notes")
            .foregroundStyle(.secondary)
        }

        HStack {
          Label("Exported", systemImage: "arrow.up.circle")
          Spacer()
          Text("\(syncService.exportedCount) notes")
            .foregroundStyle(.secondary)
        }

        if let error = syncService.syncError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }

        Button {
          Task { await syncService.scanAndImport() }
        } label: {
          HStack {
            Label("Scan Now", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            if syncService.isScanning {
              ProgressView()
            }
          }
        }
        .disabled(syncService.isScanning || !syncService.hasWatchedFolder)
      } header: {
        Text("Sync Status")
      }

      // MARK: - Auto Sync
      Section {
        Toggle("Auto-import new notes", isOn: $autoImport)
        Toggle("Auto-export changes", isOn: $autoExport)
      } header: {
        Text("Automation")
      } footer: {
        Text(
          "When enabled, Wawa Note will automatically import new .md files from the watched folder and export changes back."
        )
      }

      // MARK: - Templates
      Section {
        Button {
          showingTemplateInfo = true
        } label: {
          Label("Import anarlog Templates", systemImage: "doc.text.magnifyingglass")
        }
      } header: {
        Text("Templates")
      } footer: {
        Text(
          "Import Jinja2 templates from anarlog's enhance, title, and daily-summary prompts. They will be converted to Wawa Note editable prompts."
        )
      }

      // MARK: - Status Message
      if let message = statusMessage {
        Section {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Anarlog Sync")
    .sheet(isPresented: $showingFolderPicker) {
      FolderPicker { url in
        do {
          try syncService.saveBookmark(for: url)
          statusMessage = "Folder selected: \(url.lastPathComponent)"
          // Initial scan
          Task { await syncService.scanAndImport() }
        } catch {
          statusMessage = "Failed to save folder access: \(error.localizedDescription)"
        }
      }
    }
    .alert("Anarlog Templates", isPresented: $showingTemplateInfo) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        "Template import will be available when the anarlog shared folder is configured. Place .jinja template files in the templates/ subfolder of your anarlog directory."
      )
    }
  }

  // MARK: - Settings

  @AppStorage("anarlog_auto_import") private var autoImport = true
  @AppStorage("anarlog_auto_export") private var autoExport = false
}

// MARK: - Folder Picker (UIDocumentPickerViewController wrapper)

/// A UIKit wrapper for UIDocumentPickerViewController in directory mode.
/// Used to select the anarlog shared folder.
private struct FolderPicker: UIViewControllerRepresentable {
  let onPick: (URL) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.allowsMultipleSelection = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context)
  {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onPick: onPick)
  }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
      self.onPick = onPick
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      guard let url = urls.first else { return }
      onPick(url)
    }
  }
}
