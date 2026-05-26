import SwiftUI

struct HomeView: View {
    @State private var showRecording = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)

                    Text("Capture meetings, turn them into\nsummaries, and ask questions\nabout what was said.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                PrimaryActionButton(
                    title: "Start Meeting",
                    systemImage: "mic.circle.fill"
                ) {
                    showRecording = true
                }
                .padding(.horizontal, 32)

                Button {
                    // TODO: Import audio
                } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("Wawa Note")
            .fullScreenCover(isPresented: $showRecording) {
                RecordView()
            }
        }
    }
}

#Preview {
    HomeView()
}
