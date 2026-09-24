import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    private let reader = BatteryReader()
    private let processReader = ProcessReader()
    private let store = HistoryStore()
    private var pollingTask: Task<Void, Never>?
    private var lastRecordedAt: Date = .distantPast
    private var lastEventAt: [TimelineEventKind: Date] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingSleepAt: Date?
    private var refreshInProgress = false
    /// Retain the last valid reading across temporary sensor failures so a
    /// recovered sensor does not look like a fresh threshold crossing.
    private var lastSensorSnapshot: BatterySnapshot?

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
        observeSleepAndWake()
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
        let recentEvents = await store.events(for: .month)
        for event in recentEvents { lastEventAt[event.kind] = event.date }
        let recentSnapshots = await store.snapshots(for: .month)
        if let latest = recentSnapshots.last,
           Date.now.timeIntervalSince(latest.date) >= 0,
           Date.now.timeIntervalSince(latest.date) <= 2 * 60 {
            lastSensorSnapshot = latest
        }
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
        let previous = lastSensorSnapshot
        let previousProcesses = processes
        snapshot = current
        processes = collectProcessActivity ? processReader.sample() : []
        lastSensorSnapshot = current
        let recordedEvent = await detectEvents(previous: previous, current: current, previousProcesses: previousProcesses)
        if current.date.timeIntervalSince(lastRecordedAt) >= 60 {
            await store.record(snapshot: current, processes: processes)
            lastRecordedAt = current.date
            await loadHistory()
        } else if recordedEvent {
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
            lastEventAt.removeAll()
            lastSensorSnapshot = nil
            lastRecordedAt = .distantPast
        }
        await loadHistory()
    }


    private func detectEvents(previous: BatterySnapshot?, current: BatterySnapshot, previousProcesses: [ProcessImpact]) async -> Bool {
        var detected: [(TimelineEventKind, String?)] = []
        if let previous, previous.source != .unknown, current.source != .unknown, previous.source != current.source {
            if current.source == .charger { detected.append((.chargerConnected, nil)) }
            if current.source == .battery { detected.append((.chargerDisconnected, nil)) }
        }
        if current.percentage <= 20 && (previous?.percentage ?? 21) > 20 {
            detected.append((.lowBattery, nil))
        }
        if previous?.state != .full && current.state == .full {
            detected.append((.fullCharge, nil))
        }
        if current.source == .battery, (previous == nil || previous?.source == .battery),
           let drain = current.drainWatts,
           drain >= settings.highDrainThreshold,
           (previous?.drainWatts ?? 0) < settings.highDrainThreshold {
            detected.append((.highDrain, String(format: "%.1f W drain", drain)))
        }
        if collectProcessActivity, let top = processes.first, top.cpuPercent >= 120,
           (previousProcesses.first(where: { $0.pid == top.pid })?.cpuPercent ?? 0) < 120 {
            detected.append((.processSpike, "\(top.name) reached \(Int(top.cpuPercent))% CPU"))
        }
        if let temp = current.temperatureCelsius,
           temp >= settings.highTemperatureThreshold,
           (previous?.temperatureCelsius ?? 0) < settings.highTemperatureThreshold {
            detected.append((.highTemperature, String(format: "%.1f°C", temp)))
        }
        if let health = current.healthPercent, previous != nil,
           health <= settings.healthThreshold,
           (previous?.healthPercent ?? 101) > settings.healthThreshold {
            detected.append((.healthDrop, String(format: "%.0f%% health", health)))
        }
        var recorded = false
        for (kind, detail) in detected {
            recorded = await recordEvent(kind, at: current.date, detail: detail) || recorded
        }
        return recorded
    }

    private func observeSleepAndWake() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            let date = Date.now
            MainActor.assumeIsolated { self?.pendingSleepAt = date }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            let date = Date.now
            MainActor.assumeIsolated { self?.recordWake(at: date) }
        })
    }

    private func recordWake(at date: Date) {
        guard let sleepAt = pendingSleepAt, sleepAt < date else { return }
        pendingSleepAt = nil
        Task {
            _ = await recordEvent(.sleep, at: sleepAt, detail: nil)
            _ = await recordEvent(.wake, at: date, detail: nil)
            await loadHistory()
            await refresh()
        }
    }

    @discardableResult
    private func recordEvent(_ kind: TimelineEventKind, at date: Date, detail: String?) async -> Bool {
        let cooldown: TimeInterval = switch kind {
        case .highDrain, .highTemperature, .processSpike: 15 * 60
        case .healthDrop: 24 * 60 * 60
        default: 0
        }
        if date.timeIntervalSince(lastEventAt[kind] ?? .distantPast) < cooldown { return false }
        let event = TimelineEvent(date: date, kind: kind, detail: detail)
        lastEventAt[kind] = date
        await store.record(event: event)
        return true
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
