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

enum TimelineEventKind: String, Codable, Sendable {
    case chargerConnected, chargerDisconnected, sleep, wake, highDrain, lowBattery, fullCharge, processSpike, highTemperature, healthDrop
    var label: String {
        switch self {
        case .chargerConnected: "Charger connected"
        case .chargerDisconnected: "Charger disconnected"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke up"
        case .highDrain: "High power usage"
        case .lowBattery: "Battery reached 20%"
        case .fullCharge: "Full charge reached"
        case .processSpike: "App activity spike"
        case .highTemperature: "High battery temperature"
        case .healthDrop: "Battery health threshold reached"
        }
    }
}

struct TimelineEvent: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var kind: TimelineEventKind
    var detail: String?
}

struct ChargingSession: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var start: Date
    var end: Date?
    var startPercent: Double
    var endPercent: Double
    var peakWatts: Double?
    var averageWatts: Double?
}

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "Week", month = "Month"
    var id: String { rawValue }
    var interval: TimeInterval {
        switch self { case .today: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 }
    }
}

struct AppSettings: Codable, Sendable {
    enum MenuStyle: String, CaseIterable, Codable, Sendable {
        case percentage, percentageTime, percentageWatts, time, icon
        var label: String {
            switch self {
            case .percentage: "82%"
            case .percentageTime: "82% • 5h 12m"
            case .percentageWatts: "82% • 7.4 W"
            case .time: "5h 12m"
            case .icon: "Icon only"
            }
        }
    }
    var menuStyle: MenuStyle = .percentageWatts
    var lowBatteryAlert = true
    var fullChargeAlert = true
    var highDrainAlert = true
    var highTemperatureAlert = true
    var healthAlert = true
    var chargerDisconnectedAlert = false
    var chargeTargetAlert = false
    var chargeTargetPercent = 80
    var highTemperatureThreshold = 45.0
    var highDrainThreshold = 20.0
    var healthThreshold = 80.0
}
