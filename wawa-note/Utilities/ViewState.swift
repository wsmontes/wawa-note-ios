import Foundation

/// Standard view state for all feature screens.
///
/// Guideline: "Modele UX como estados, não como telas soltas.
/// Tenha um ViewState explícito. Em SwiftUI, isso evita lógica ilegível."
enum ViewState<T: Sendable>: Sendable {
    case idle
    case loading(LoadingKind)
    case loaded(T)
    case empty(EmptyReason)
    case error(ErrorInfo)
    case permissionDenied(PermissionInfo)
    case offline

    enum LoadingKind: Sendable {
        case initial        // First load — use skeleton or branded spinner
        case refreshing      // Pull-to-refresh or background update
        case processing(String) // "Generating summary...", "Transcribing..."
    }

    struct EmptyReason: Sendable {
        let title: String
        let message: String
        let action: String?
        let icon: String
    }

    struct ErrorInfo: Sendable {
        let title: String
        let message: String
        let recoveryAction: String?
    }

    struct PermissionInfo: Sendable {
        let title: String
        let message: String
        let settingName: String
    }
}

// MARK: - Haptics Helper

import UIKit

/// Semantic haptics for key actions.
///
/// Guideline: "Use haptics do sistema pelo significado.
/// Haptic para confirmação, impacto ou erro."
@MainActor
enum Haptics {
    /// Recording started, item created, operation completed.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Recording stopped, item deleted, warning state.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Error, operation failed, permission denied.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Item selected, switch toggled, state changed.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Light impact — button press, tap confirmation.
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium impact — drag, snap, modal present.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Heavy impact — destructive action, force touch, major state change.
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}

// MARK: - Accessibility Modifiers

import SwiftUI
// Related JIRA: KAN-10


extension View {
    /// Standard hit target for interactive elements (44pt minimum per HIG).
    func standardHitTarget() -> some View {
        self
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// Hide decorative elements from accessibility.
    func decorative() -> some View {
        self.accessibilityHidden(true)
    }

    /// Add a semantic accessibility label and optional hint.
    func accessible(label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    /// Group card contents into a single accessibility element.
    func accessibleCard(label: String) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }

    /// Respect Reduce Motion accessibility setting.
    /// Replaces spring/bouncy animations with simple opacity transitions.
    func respectReduceMotion(animation: Animation = .default) -> some View {
        self.animation(UIAccessibility.isReduceMotionEnabled ? .none : animation, value: true)
    }
}

