import Speech
import SwiftUI

/// Shows on-device speech model availability and guides the user through download.
///
/// Guideline: "Implemente uma etapa 'ensure model installed'. Antes de iniciar
/// transcrição, garanta que o asset do idioma está presente."
///
/// The model is managed by Apple — downloaded automatically when the device
/// is on Wi-Fi and the SFSpeechRecognizer is first used. This view:
/// 1. Checks if the model is available for the selected locale
/// 2. Shows download status and guidance if not
/// 3. Provides a way to trigger the download
struct ModelDownloadView: View {
  let locale: Locale
  let onReady: () -> Void

  @State private var availability: LocalTranscriptionAvailability = .hardwareUnsupported
  @State private var isChecking = true
  @State private var checkTimer: Timer?

  var body: some View {
    VStack(spacing: 20) {
      switch availability {
      case .available:
        // Model is ready — show success briefly then call onReady
        VStack(spacing: 12) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.green)
          Text("Ready")
            .font(.headline)
          Text("On-device speech recognition is ready for \(locale.identifier).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onReady()
          }
        }

      case .modelMissing:
        VStack(spacing: 16) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 48))
            .foregroundStyle(.blue)

          Text("Download Required")
            .font(.headline)

          Text(
            "The on-device speech model for **\(locale.identifier)** needs to be downloaded first."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

          Text(
            "This happens automatically when your device is connected to Wi-Fi. Make sure you're online and try again."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

          if isChecking {
            ProgressView("Checking availability...")
          }

          Button("Check Again") {
            checkAvailability()
          }
          .buttonStyle(.borderedProminent)
        }

      case .localeUnsupported:
        VStack(spacing: 12) {
          Image(systemName: "globe.slash")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
          Text("Language Not Supported")
            .font(.headline)
          Text("On-device speech recognition is not available for \(locale.identifier).")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Try English Instead") {
            checkAvailability()
          }
          .buttonStyle(.bordered)
        }

      case .permissionDenied:
        VStack(spacing: 12) {
          Image(systemName: "mic.slash")
            .font(.system(size: 48))
            .foregroundStyle(.red)
          Text("Permission Required")
            .font(.headline)
          Text("Enable Speech Recognition in Settings > Privacy.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          }
          .buttonStyle(.bordered)
        }

      case .hardwareUnsupported:
        VStack(spacing: 12) {
          Image(systemName: "xmark.circle")
            .font(.system(size: 48))
            .foregroundStyle(.red)
          Text("Not Available")
            .font(.headline)
          Text("On-device speech recognition is not supported on this device.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

      case .failed(let msg):
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
          Text("Error")
            .font(.headline)
          Text(msg)
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Retry") { checkAvailability() }
            .buttonStyle(.bordered)
        }
      }

      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      checkAvailability()
      // Auto-retry every 5 seconds for model download
      checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        checkAvailability()
      }
    }
    .onDisappear {
      checkTimer?.invalidate()
    }
  }

  private func checkAvailability() {
    isChecking = true

    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      availability = .localeUnsupported(locale: locale)
      isChecking = false
      return
    }

    if !recognizer.isAvailable {
      availability = .modelMissing(locale: locale)
    } else if !recognizer.supportsOnDeviceRecognition {
      availability = .hardwareUnsupported
    } else {
      availability = .available(localeIdentifier: locale.identifier)
    }
    isChecking = false
  }
}

// MARK: - Preview

#Preview {
  ModelDownloadView(locale: Locale(identifier: "pt-BR"), onReady: {})
}
