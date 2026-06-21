import SwiftUI

struct ColorPickerView: View {
    @Binding var selectedHex: String
    @Environment(\.dismiss) private var dismiss

    private let colors: [(String, Color)] = [
        ("#007AFF", .blue), ("#FF3B30", .red), ("#34C759", .green),
        ("#FF9500", .orange), ("#FFCC00", .yellow), ("#AF52DE", .purple),
        ("#FF2D55", .pink), ("#00C7BE", .teal), ("#8E8E93", .gray),
        ("#000000", .black), ("#FFFFFF", .white), ("#8B5A2B", .brown)
    ]

    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(colors, id: \.0) { hex, color in
                        ZStack {
                            if hex == "#FFFFFF" {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 50, height: 50)
                                    .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            } else {
                                Circle()
                                    .fill(color)
                                    .frame(width: 50, height: 50)
                            }
                        }
                        .overlay(
                            Circle()
                                .stroke(selectedHex == hex ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        .onTapGesture {
                            selectedHex = hex
                            dismiss()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Choose Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
