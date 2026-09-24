import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                Text("\(Int(snapshot.percentage.rounded()))%")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text(snapshot.state.label)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for battery data")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }
}
