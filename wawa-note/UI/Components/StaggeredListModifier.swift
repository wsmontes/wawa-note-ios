import SwiftUI

// MARK: - Staggered Appear Modifier

/// Animates items into view with a cascading fade-in + slide-up effect.
/// Apply to items inside a LazyVStack, List, or ScrollView.
///
/// Usage:
/// ```swift
/// ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
///   ItemRow(item)
///     .staggeredAppear(index: index)
/// }
/// ```
struct StaggeredAppear: ViewModifier {
  let index: Int
  let baseDelay: TimeInterval
  let maxItems: Int
  @State private var hasAppeared = false

  /// - Parameters:
  ///   - index: Zero-based position in the list
  ///   - baseDelay: Delay per item (default 0.04s matches Feedmine)
  ///   - maxItems: Cap the cascade at this many items (default 8) so the
  ///     last items don't wait too long
  init(index: Int, baseDelay: TimeInterval = 0.04, maxItems: Int = 8) {
    self.index = index
    self.baseDelay = baseDelay
    self.maxItems = maxItems
  }

  func body(content: Content) -> some View {
    content
      .opacity(hasAppeared ? 1 : 0)
      .offset(y: hasAppeared ? 0 : 16)
      .animation(
        .easeOut(duration: 0.4).delay(Double(min(index, maxItems)) * baseDelay),
        value: hasAppeared
      )
      .onAppear { hasAppeared = true }
  }
}

extension View {
  /// Applies a staggered appear animation to list items.
  ///
  /// Items fade in from below with a cascading delay — the first 8 items
  /// each wait 0.04s more than the previous, creating a wave effect.
  /// Items beyond the 8th all share the same delay so the tail doesn't lag.
  func staggeredAppear(index: Int, baseDelay: TimeInterval = 0.04, maxItems: Int = 8) -> some View {
    modifier(StaggeredAppear(index: index, baseDelay: baseDelay, maxItems: maxItems))
  }
}
