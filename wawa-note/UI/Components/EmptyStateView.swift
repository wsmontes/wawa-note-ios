import SwiftUI

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?

    init(
        systemImage: String,
        title: String,
        message: String,
        primaryActionTitle: String? = nil,
        primaryAction: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.primaryActionTitle = primaryActionTitle
        self.primaryAction = primaryAction
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let primaryActionTitle, let primaryAction {
                PrimaryActionButton(
                    title: primaryActionTitle,
                    systemImage: nil,
                    action: primaryAction
                )
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            Spacer()
        }
    }
}

#Preview {
    EmptyStateView(
        systemImage: "list.bullet.rectangle",
        title: "No meetings yet",
        message: "Start a short test recording to see how summaries work.",
        primaryActionTitle: "Start Meeting",
        primaryAction: {}
    )
}
