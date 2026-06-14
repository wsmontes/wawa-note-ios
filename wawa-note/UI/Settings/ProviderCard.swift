import SwiftUI

struct ProviderCard: View {
    let template: ProviderTemplate
    let isConnected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                iconView

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isConnected {
                    AppStatusBadge(
                        title: "Connected",
                        systemImage: "checkmark.circle.fill",
                        tone: .success
                    )
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(iconBackgroundColor)
                .frame(width: 44, height: 44)

            Image(systemName: template.systemImageName)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(iconForegroundColor)
        }
    }

    private var iconBackgroundColor: Color {
        if isConnected {
            return AppColor.success.opacity(0.12)
        }
        switch template.category {
        case .cloud:
            return Color.accentColor.opacity(0.10)
        case .local:
            return AppColor.privacy.opacity(0.10)
        }
    }

    private var iconForegroundColor: Color {
        if isConnected {
            return AppColor.success
        }
        switch template.category {
        case .cloud:
            return Color.accentColor
        case .local:
            return AppColor.privacy
        }
    }
}

// MARK: - Preview

#Preview("Cloud - not connected") {
    List {
        if let t = ProviderTemplate.openAI {
            ProviderCard(template: t, isConnected: false, action: {})
        }
        if let t = ProviderTemplate.anthropic {
            ProviderCard(template: t, isConnected: false, action: {})
        }
    }
}

#Preview("Cloud - connected") {
    List {
        if let t = ProviderTemplate.openAI {
            ProviderCard(template: t, isConnected: true, action: {})
        }
    }
}

#Preview("Local") {
    List {
        if let t = ProviderTemplate.lmStudio {
            ProviderCard(template: t, isConnected: false, action: {})
        }
        if let t = ProviderTemplate.ollama {
            ProviderCard(template: t, isConnected: true, action: {})
        }
    }
}
