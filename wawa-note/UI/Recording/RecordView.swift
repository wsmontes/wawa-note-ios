import SwiftUI

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                AppStatusBadge(title: "Ready", systemImage: "mic", tone: .neutral)

                Text("00:00")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                HStack(spacing: 24) {
                    Button {
                        // TODO: Start recording
                    } label: {
                        Label("Start", systemImage: "record.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Spacer()
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    RecordView()
}
