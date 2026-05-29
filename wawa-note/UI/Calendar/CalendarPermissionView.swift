import SwiftUI

struct CalendarPermissionView: View {
    let onRequestPermission: () async -> Bool

    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("iPhone Calendar Not Connected")
                .font(.title3).fontWeight(.medium)
            Text("Connect your calendar to see your iPhone events alongside your Wawa Note activity. Your data stays on your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                isRequesting = true
                Task { _ = await onRequestPermission(); isRequesting = false }
            } label: {
                HStack {
                    if isRequesting {
                        ProgressView()
                    }
                    Text("Connect Calendar")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
            Spacer()
        }
    }
}
