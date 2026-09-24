import Foundation

enum PowerSource: String, Codable, Sendable { case battery, charger, unknown }

enum BatteryState: String, Codable, Sendable {
    case charging, full, paused, onBattery, pluggedIn, unknown
    var label: String {
        switch self {
        case .charging: "Charging"
        case .full: "Fully charged"
        case .paused: "Charging paused"
        case .onBattery: "Running on battery"
        case .pluggedIn: "Plugged in"
        case .unknown: "Unavailable"
        }
    }
}

struct BatterySnapshot: Codable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var percentage: Double
    var state: BatteryState
    var source: PowerSource
    var timeToFullMinutes: Int?
    var timeRemainingMinutes: Int?
}
