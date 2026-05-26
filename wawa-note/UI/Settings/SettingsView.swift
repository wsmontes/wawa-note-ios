import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Providers") {
                    Text("No provider configured")
                        .foregroundStyle(.secondary)
                }

                Section("Transcription") {
                    Text("Apple Speech")
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Text("Local first")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
