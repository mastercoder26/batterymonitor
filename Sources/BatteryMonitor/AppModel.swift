import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    private let reader = BatteryReader()
    private let processReader = ProcessReader()
    private let store = HistoryStore()
    private var pollingTask: Task<Void, Never>?
    private var lastRecordedAt: Date = .distantPast
    private var refreshInProgress = false

    var snapshot: BatterySnapshot?
    var historyError: String?
    var collectProcessActivity: Bool = UserDefaults.standard.object(forKey: "collectProcessActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(collectProcessActivity, forKey: "collectProcessActivity")
            if !collectProcessActivity { processes = [] }
        }
    }
    var samples: [BatterySnapshot] = []
    var events: [TimelineEvent] = []
    var processes: [ProcessImpact] = []
    var sessions: [ChargingSession] = []
    var analytics: BatteryAnalytics?
    var selectedPeriod: HistoryPeriod = .today {
        didSet { Task { await loadHistory() } }
    }
    var settings: AppSettings = AppModel.loadSettings() {
        didSet { Self.saveSettings(settings) }
    }

    var menuBarTitle: String {
        guard let snapshot else { return "Battery" }
        let percent = "\(Int(snapshot.percentage.rounded()))%"
        let timeText: String? = {
            if snapshot.state == .full { return "Full" }
            if snapshot.state == .paused { return "Paused" }
            let time = snapshot.source == .battery ? snapshot.timeRemainingMinutes : snapshot.timeToFullMinutes
            return time.map { "\($0 / 60)h \($0 % 60)m" }
        }()
        switch settings.menuStyle {
        case .percentage: return percent
        case .percentageTime: return timeText.map { "\(percent) • \($0)" } ?? percent
        case .percentageWatts:
            let watts = snapshot.source == .battery ? snapshot.drainWatts : snapshot.chargeWatts
            return watts.map { String(format: "%@ • %.1f W", percent, $0) } ?? percent
        case .time: return timeText ?? percent
        case .icon: return ""
        }
    }

    var menuBarSymbol: String {
        guard let snapshot else { return "battery.0percent" }
        if snapshot.source == .charger { return "battery.100percent.bolt" }
        let level = Int((snapshot.percentage / 25).rounded()) * 25
        return "battery.\(min(100, max(0, level)))percent"
    }

    func run() async {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.initialize()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func initialize() async {
        await loadHistory()
        await refresh()
    }

    func refresh() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        guard let current = reader.read() else {
            snapshot = nil
            return
        }
        snapshot = current
        processes = collectProcessActivity ? processReader.sample() : []
        if current.date.timeIntervalSince(lastRecordedAt) >= 60 {
            await store.record(snapshot: current, processes: processes)
            lastRecordedAt = current.date
            await loadHistory()
        }
    }

    private func loadHistory() async {
        let history = await store.history(for: selectedPeriod)
        samples = history.snapshots
        events = history.events
        sessions = history.chargingSessions
        analytics = AnalyticsEngine.summarize(history, current: snapshot)
        historyError = await store.lastPersistenceError
    }

    func clearHistory() async {
        await store.clear()
        historyError = await store.lastPersistenceError
        if historyError == nil {
            lastRecordedAt = .distantPast
        }
        await loadHistory()
    }

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    private static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: "appSettings")
    }
}
