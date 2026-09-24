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
    var drainWatts: Double?
    var chargeWatts: Double?
    var temperatureCelsius: Double?
    var voltageVolts: Double?
    var maxCapacityMAh: Int?
    var designCapacityMAh: Int?
    var cycleCount: Int?
    var manufactureDate: Date?
    var condition: String?
    var adapterWatts: Int?
    var adapterName: String?
    var batteryIsPresent: Bool = true

    var healthPercent: Double? {
        guard let maxCapacityMAh, let designCapacityMAh, designCapacityMAh > 0 else { return nil }
        return Double(maxCapacityMAh) / Double(designCapacityMAh) * 100
    }
}

struct ProcessImpact: Codable, Sendable, Identifiable {
    var id: Int { pid }
    var pid: Int
    var name: String
    var cpuPercent: Double
    var estimatedShare: Double
}
