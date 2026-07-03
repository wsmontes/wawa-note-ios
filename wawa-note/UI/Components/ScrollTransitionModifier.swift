import SwiftUI

// MARK: - Feed-Style Scroll Transition (iOS 18+)

/// Applies a subtle scale+fade transition to items as they scroll
/// in and out of view, matching the Feedmine visual style.
///
/// - On iOS 18+: uses `.scrollTransition(.animated(.spring(duration: 0.4)))`
///   with opacity 0.5 and scale 0.95 for non-identity phases.
/// - On iOS 17: no-op (the modifier is transparent).
///
/// Usage:
/// ```swift
/// ForEach(items) { item in
///   ItemRow(item)
///     .feedScrollTransition()
/// }
/// ```
struct FeedScrollTransition: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      content
        .scrollTransition(.animated(.spring(duration: 0.4))) { content, phase in
          content
            .opacity(phase == .identity ? 1 : 0.5)
            .scaleEffect(phase == .identity ? 1 : 0.95)
        }
    } else {
      content
    }
  }
}

extension View {
  /// Applies the Feedmine-style scroll transition (iOS 18+).
  /// Nearby items gently fade and shrink as they leave the viewport.
  func feedScrollTransition() -> some View {
    modifier(FeedScrollTransition())
  }
}
