import SwiftUI

struct RecordView: View {
    var body: some View {
        NavigationStack {
            Text("Record a meeting")
                .navigationTitle("Record")
        }
    }
}

#Preview {
    RecordView()
}
