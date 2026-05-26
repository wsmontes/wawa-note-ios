import SwiftUI

enum BadgeTone {
    case neutral
    case success
    case warning
    case error
    case privacy
    case recording

    var color: Color {
        switch self {
        case .neutral: AppColor.neutral
        case .success: AppColor.success
        case .warning: AppColor.warning
        case .error: AppColor.error
        case .privacy: AppColor.privacy
        case .recording: AppColor.recording
        }
    }
}

struct AppStatusBadge: View {
    let title: String
    let systemImage: String?
    let tone: BadgeTone

    init(title: String, systemImage: String? = nil, tone: BadgeTone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.15))
        .foregroundStyle(tone.color)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

#Preview {
    VStack(spacing: 8) {
        AppStatusBadge(title: "Ready", systemImage: "mic", tone: .neutral)
        AppStatusBadge(title: "Saved", systemImage: "checkmark", tone: .success)
        AppStatusBadge(title: "Transcribing", tone: .warning)
        AppStatusBadge(title: "Failed", systemImage: "xmark", tone: .error)
        AppStatusBadge(title: "Local", systemImage: "iphone", tone: .privacy)
        AppStatusBadge(title: "Recording", systemImage: "record.circle", tone: .recording)
    }
    .padding()
}
