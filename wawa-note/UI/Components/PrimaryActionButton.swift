import SwiftUI

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                }
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)
    }
}

#Preview {
    VStack(spacing: 16) {
        PrimaryActionButton(title: "Start Meeting", systemImage: "mic.circle.fill") {}
        PrimaryActionButton(title: "Save Provider", systemImage: "checkmark") {}
        PrimaryActionButton(title: "Loading...", isLoading: true) {}
    }
    .padding()
}
