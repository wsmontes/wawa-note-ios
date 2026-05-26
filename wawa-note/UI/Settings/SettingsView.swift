import SwiftUI

struct SettingsView: View {
    @State private var useRemoteTranscription = UserDefaults.standard.bool(forKey: "use_remote_transcription")

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProviderPickerView()
                    } label: {
                        Label("AI Services", systemImage: "brain.head.profile")
                    }
                } header: {
                    Text("AI & Transcription")
                }

                Section {
                    Toggle("Whisper via API", isOn: $useRemoteTranscription)
                        .onChange(of: useRemoteTranscription) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "use_remote_transcription")
                        }

                    if !useRemoteTranscription {
                        HStack {
                            Label("Apple Speech", systemImage: "text.alignleft")
                            Spacer()
                            Text("On-device")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    if useRemoteTranscription {
                        Text("Uses your connected AI service to transcribe audio via Whisper API. Audio is sent to the provider.")
                    } else {
                        Text("Transcription happens on this iPhone. Nothing is sent anywhere.")
                    }
                }

                Section {
                    HStack {
                        Label("Privacy mode", systemImage: "lock.shield")
                        Spacer()
                        Text("Local first")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
