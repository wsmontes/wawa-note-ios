import SwiftUI

// MARK: - Toast Style

enum ToastStyle: Sendable {
  case info
  case success
  case error
  case warning

  var icon: String {
    switch self {
    case .info: "info.circle.fill"
    case .success: "checkmark.circle.fill"
    case .error: "xmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch self {
    case .info: .blue
    case .success: .green
    case .error: .red
    case .warning: .orange
    }
  }
}

// MARK: - Toast Message

struct ToastMessage: Identifiable, Sendable {
  let id: UUID
  let message: String
  let style: ToastStyle
  let actionLabel: String?
  let action: (@MainActor @Sendable () -> Void)?
  let duration: TimeInterval

  init(
    id: UUID = UUID(),
    message: String,
    style: ToastStyle,
    actionLabel: String? = nil,
    action: (@MainActor @Sendable () -> Void)? = nil,
    duration: TimeInterval = 3.0
  ) {
    self.id = id
    self.message = message
    self.style = style
    self.actionLabel = actionLabel
    self.action = action
    // Toasts with actions persist until dismissed by the user
    self.duration = action != nil ? .infinity : duration
  }

  static func info(_ message: String) -> ToastMessage {
    ToastMessage(message: message, style: .info)
  }

  static func success(_ message: String) -> ToastMessage {
    ToastMessage(message: message, style: .success)
  }

  static func error(
    _ message: String, action: (@MainActor @Sendable () -> Void)? = nil, actionLabel: String? = nil
  ) -> ToastMessage {
    ToastMessage(message: message, style: .error, actionLabel: actionLabel, action: action)
  }

  static func warning(
    _ message: String, action: (@MainActor @Sendable () -> Void)? = nil, actionLabel: String? = nil
  ) -> ToastMessage {
    ToastMessage(message: message, style: .warning, actionLabel: actionLabel, action: action)
  }
}

// MARK: - Toast Queue

@MainActor
@Observable
final class ToastQueue: @unchecked Sendable {
  private(set) var currentToast: ToastMessage?
  private var pending: [ToastMessage] = []
  private var dismissTask: Task<Void, Never>?

  func enqueue(_ toast: ToastMessage) {
    if currentToast == nil {
      showToast(toast)
    } else {
      pending.append(toast)
    }
  }

  func dismissCurrent() {
    dismissTask?.cancel()
    dismissTask = nil
    withAnimation(.easeOut(duration: 0.3)) {
      currentToast = nil
    }
    // Show next after dismiss animation
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      showNextIfPending()
    }
  }

  private func showToast(_ toast: ToastMessage) {
    withAnimation(.easeOut(duration: 0.3)) {
      currentToast = toast
    }

    // Auto-dismiss for non-action toasts
    if toast.action == nil {
      dismissTask?.cancel()
      dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(toast.duration))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
          currentToast = nil
        }
        try? await Task.sleep(for: .milliseconds(350))
        showNextIfPending()
      }
    }
  }

  @MainActor private func showNextIfPending() {
    guard !pending.isEmpty else { return }
    let next = pending.removeFirst()
    showToast(next)
  }
}

// MARK: - Environment Key

struct ToastQueueKey: EnvironmentKey {
  // Safe: SwiftUI always reads environment values from the main thread.
  static let defaultValue: ToastQueue = MainActor.assumeIsolated {
    ToastQueue()
  }
}

extension EnvironmentValues {
  var toastQueue: ToastQueue {
    get { self[ToastQueueKey.self] }
    set { self[ToastQueueKey.self] = newValue }
  }
}

// MARK: - Toast Container

struct ToastContainer: View {
  @Environment(ToastQueue.self) private var queue

  var body: some View {
    if let toast = queue.currentToast {
      ToastBannerView(toast: toast, onDismiss: { queue.dismissCurrent() })
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
  }
}

// MARK: - Toast Banner

private struct ToastBannerView: View {
  let toast: ToastMessage
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: toast.style.icon)
        .font(.title3)
        .foregroundStyle(toast.style.color)
        .accessibilityHidden(true)

      Text(toast.message)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(2)

      Spacer(minLength: 8)

      if let actionLabel = toast.actionLabel, let action = toast.action {
        Button {
          action()
          onDismiss()
        } label: {
          Text(actionLabel)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.blue)
        }
        .accessibilityLabel(actionLabel)
        .accessibilityHint("Performs the action and dismisses this notification")
      }

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel("Dismiss notification")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
  }
}

// MARK: - View Extension (convenience)

extension View {
  /// Adds a toast container overlay positioned above the tab bar.
  /// Place this at the root ZStack level — typically in ContentView.
  func toastContainer() -> some View {
    self.overlay {
      VStack {
        Spacer()
        ToastContainer()
          .padding(.bottom, 84)  // Clear the tab bar (49pt) + bottom safe area (~35pt)
      }
    }
  }
}
