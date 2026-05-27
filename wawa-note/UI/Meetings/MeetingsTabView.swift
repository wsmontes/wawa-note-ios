import SwiftUI

enum MeetingsViewMode: String, CaseIterable {
    case list
    case calendar
}

struct MeetingsTabView: View {
    @State private var mode: MeetingsViewMode = .list

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    Label("List", systemImage: "list.bullet").tag(MeetingsViewMode.list)
                    Label("Calendar", systemImage: "calendar").tag(MeetingsViewMode.calendar)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                switch mode {
                case .list:
                    MeetingsListView()
                case .calendar:
                    CalendarContainerView()
                }
            }
        }
    }
}
