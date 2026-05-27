import SwiftUI

struct EventPreviewSheet: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss

    let event: CalendarEvent

    @State private var shouldStartRecording = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text(event.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    Label(event.startDate.formatted(date: .long, time: .shortened),
                          systemImage: "clock")
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location")
                    }
                    if let attendees = event.attendees, !attendees.isEmpty {
                        Label("\(attendees.count) participants", systemImage: "person.2")
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    shouldStartRecording = true
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 32)
            }
            .padding(.vertical, 24)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $shouldStartRecording) {
                RecordView(coordinator: coordinator, prefillEvent: event)
            }
        }
    }
}
