import SwiftUI

struct HomeView: View {
    @State private var showRecording = false
    @State private var navigateToMeeting: MeetingModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Brand symbol — subtle, per design guide §9.1
                Image(.wawaSymbolGradient)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)

                Text(AppCopy.homeValueProp)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PrimaryActionButton(
                    title: AppCopy.startRecordingButton,
                    systemImage: "record.circle.fill"
                ) {
                    showRecording = true
                }
                .padding(.horizontal, 32)
                .tint(.red)

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
            .fullScreenCover(isPresented: $showRecording) {
                RecordView { meeting in
                    showRecording = false
                    navigateToMeeting = meeting
                }
            }
            .navigationDestination(item: $navigateToMeeting) { meeting in
                MeetingDetailView(meeting: meeting)
            }
        }
    }
}

#Preview {
    HomeView()
}
