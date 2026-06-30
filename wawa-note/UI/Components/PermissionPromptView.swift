import SwiftUI

struct PermissionPromptView: View {
  let systemImage: String
  let title: String
  let description: String
  let actionLabel: String
  let onRequestPermission: () -> Void
  var onOpenSettings: (() -> Void)?

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: systemImage)
        .font(.system(size: 48))
        .foregroundStyle(.secondary)

      Text(title)
        .font(.headline)

      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      Button(action: onRequestPermission) {
        Text(actionLabel)
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal, 32)

      if let onOpenSettings {
        Button("Open Settings", action: onOpenSettings)
          .font(.subheadline)
      }
    }
    .padding()
  }
}

extension PermissionPromptView {
  static func calendar(onRequest: @escaping () -> Void) -> PermissionPromptView {
    PermissionPromptView(
      systemImage: "calendar",
      title: String(localized: "Connect Your Calendar"),
      description: String(
        localized:
          "Wawa Note shows your calendar events so you can start recordings with the right meeting context."
      ),
      actionLabel: String(localized: "Connect Calendar"),
      onRequestPermission: onRequest,
      onOpenSettings: {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
      }
    )
  }

  static func reminders(onRequest: @escaping () -> Void) -> PermissionPromptView {
    PermissionPromptView(
      systemImage: "checklist",
      title: String(localized: "Connect Reminders"),
      description: String(
        localized:
          "Wawa Note creates reminders from your meeting action items so you can track follow-ups."),
      actionLabel: String(localized: "Connect Reminders"),
      onRequestPermission: onRequest,
      onOpenSettings: {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
      }
    )
  }

  static func microphone(onRequest: @escaping () -> Void) -> PermissionPromptView {
    PermissionPromptView(
      systemImage: "mic.fill",
      title: String(localized: "Microphone Access"),
      description: String(
        localized: "Wawa Note uses the microphone to record meetings you choose to capture."),
      actionLabel: String(localized: "Enable Microphone"),
      onRequestPermission: onRequest,
      onOpenSettings: {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
      }
    )
  }

  static func speechRecognition(onRequest: @escaping () -> Void) -> PermissionPromptView {
    PermissionPromptView(
      systemImage: "waveform",
      title: String(localized: "Speech Recognition"),
      description: String(
        localized:
          "Speech recognition is used to turn your recorded meetings into a searchable transcript."),
      actionLabel: String(localized: "Enable Speech Recognition"),
      onRequestPermission: onRequest,
      onOpenSettings: {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
      }
    )
  }
}

#Preview {
  PermissionPromptView.calendar(onRequest: {})
}
