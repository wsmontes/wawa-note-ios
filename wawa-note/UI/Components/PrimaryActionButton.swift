import SwiftUI

// Related JIRA: KAN-10

/// Floating action button for the primary action on each screen.
/// Follows HIG: large hit target, clear label, haptic feedback, Dynamic Type.
///
/// Variants:
/// - .record (red/mic) — primary capture action
/// - .primary (accent) — default main action
/// - .secondary (gray) — alternative
/// - .scan (blue) — document scan
/// - .note (yellow) — new note
/// - .destructive (red) — delete
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var variant: Variant = .primary
    let action: () -> Void

    enum Variant {
        case record, primary, secondary, scan, note, destructive
    }

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(foregroundColor)
                }
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .medium))
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)  // minHeight for Dynamic Type
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: shadowColor.opacity(0.25), radius: 6, y: 3)
        }
        .disabled(isLoading)
        .standardHitTarget()
        .accessible(label: title, hint: hintText)
        .respectReduceMotion(animation: .spring(response: 0.3, dampingFraction: 0.7))
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary, .secondary, .scan, .note: .white
        case .record, .destructive: .white
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .record: .red
        case .primary: .accentColor
        case .secondary: Color(.systemGray3)
        case .scan: .blue
        case .note: .yellow
        case .destructive: .red.opacity(0.9)
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .record: .red
        case .destructive: .red
        case .primary: .accentColor
        case .secondary: .gray
        case .scan: .blue
        case .note: .yellow
        }
    }

    private var hintText: String {
        switch variant {
        case .record: "Starts recording audio"
        case .primary: "Performs the main action"
        case .secondary: "Shows more options"
        case .scan: "Opens document scanner"
        case .note: "Creates a new note"
        case .destructive: "Deletes the item"
        }
    }
}

#Preview("Dynamic Type") {
    VStack(spacing: 16) {
        PrimaryActionButton(title: "Record Meeting", systemImage: "mic.fill", variant: .record) {}
        PrimaryActionButton(title: "New Note", systemImage: "square.and.pencil", variant: .note) {}
        PrimaryActionButton(title: "Scan Document", systemImage: "doc.viewfinder", variant: .scan) {}
        PrimaryActionButton(title: "Delete Item", systemImage: "trash", variant: .destructive) {}
        PrimaryActionButton(title: "Loading...", isLoading: true) {}
    }
    .padding()
}
