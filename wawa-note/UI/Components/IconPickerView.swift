import SwiftUI

struct IconPickerView: View {
    @Binding var selectedIcon: String
    @Environment(\.dismiss) private var dismiss

    private let icons = [
        "folder.fill", "briefcase.fill", "chart.bar.fill", "doc.text.fill",
        "brain.head.profile", "lightbulb.fill", "hammer.fill", "wrench.fill",
        "gearshape.fill", "star.fill", "heart.fill", "flag.fill",
        "bookmark.fill", "tag.fill", "calendar", "clock.fill",
        "person.3.fill", "building.2.fill", "globe", "trophy.fill"
    ]

    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(icons, id: \.self) { icon in
                        VStack {
                            Image(systemName: icon)
                                .font(.title)
                                .frame(width: 50, height: 50)
                                .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(icon.replacingOccurrences(of: ".fill", with: ""))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .onTapGesture {
                            selectedIcon = icon
                            dismiss()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
