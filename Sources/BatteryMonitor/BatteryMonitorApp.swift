import SwiftUI

@main
struct BatteryMonitorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 680)
                .task { await model.run() }
        }
        .defaultSize(width: 1180, height: 800)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            if model.settings.menuStyle == .icon {
                Image(systemName: model.menuBarSymbol)
                    .accessibilityLabel(model.snapshot.map { "Battery \(Int($0.percentage.rounded())) percent, \($0.state.label)" } ?? "Battery data unavailable")
                    .task { await model.run() }
            } else {
                Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
                    .task { await model.run() }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        if let snapshot = model.snapshot {
            Text("Battery \(Int(snapshot.percentage.rounded()))% • \(snapshot.state.label)")
            if let watts = snapshot.source == .battery ? snapshot.drainWatts : snapshot.chargeWatts {
                Text("\(watts, specifier: "%.1f") W \(snapshot.source == .battery ? "drain" : "charging")")
            }
            if let minutes = snapshot.source == .battery ? snapshot.timeRemainingMinutes : snapshot.timeToFullMinutes {
                Text("\(minutes / 60)h \(minutes % 60)m \(snapshot.source == .battery ? "remaining" : "until full")")
            }
        } else {
            Text("Battery data unavailable")
        }
        Divider()
        Button("Open Battery Monitor") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Refresh") { Task { await model.refresh() } }
        Divider()
        Button("Quit Battery Monitor") { NSApp.terminate(nil) }
    }
}
