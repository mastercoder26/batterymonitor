import Foundation

/// A timestamped process reading. Process share is an estimate, not metered app wattage.
struct ProcessSample: Codable, Sendable {
    var date: Date
    var processes: [ProcessImpact]
}

struct BatteryHistory: Sendable {
    var snapshots: [BatterySnapshot]
    var events: [TimelineEvent]
    var processSamples: [ProcessSample]
    var chargingSessions: [ChargingSession]
}

actor HistoryStore {
    private struct Archive: Codable {
        var snapshots: [BatterySnapshot] = []
        var events: [TimelineEvent] = []
        var processSamples: [ProcessSample] = []
        var chargingSessions: [ChargingSession] = []
    }

    private let fileURL: URL
    private var archive: Archive
    private(set) var lastPersistenceError: String?

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatteryMonitor", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = decoded
        } else {
            archive = Archive()
        }
    }

    func record(snapshot: BatterySnapshot, processes: [ProcessImpact] = []) {
        let previous = archive.snapshots.last
        guard previous == nil || snapshot.date > previous!.date else { return }
        archive.snapshots.append(snapshot)
        if !processes.isEmpty {
            archive.processSamples.append(ProcessSample(date: snapshot.date, processes: processes))
        }
        persist()
    }

    func record(event: TimelineEvent) {
        archive.events.append(event)
        archive.events.sort { $0.date < $1.date }
        persist()
    }

    func snapshots(for period: HistoryPeriod, now: Date = .now) -> [BatterySnapshot] {
        archive.snapshots.filter { $0.date >= now.addingTimeInterval(-period.interval) && $0.date <= now }
    }

    func events(for period: HistoryPeriod, now: Date = .now) -> [TimelineEvent] {
        archive.events.filter { $0.date >= now.addingTimeInterval(-period.interval) && $0.date <= now }
    }

    func processSamples(for period: HistoryPeriod, now: Date = .now) -> [ProcessSample] {
        archive.processSamples.filter { $0.date >= now.addingTimeInterval(-period.interval) && $0.date <= now }
    }

    func chargingSessions(for period: HistoryPeriod, now: Date = .now) -> [ChargingSession] {
        let start = now.addingTimeInterval(-period.interval)
        return archive.chargingSessions.filter { $0.start <= now && ($0.end ?? now) >= start }
    }

    func history(for period: HistoryPeriod, now: Date = .now) -> BatteryHistory {
        BatteryHistory(
            snapshots: snapshots(for: period, now: now),
            events: events(for: period, now: now),
            processSamples: processSamples(for: period, now: now),
            chargingSessions: chargingSessions(for: period, now: now)
        )
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(archive)
            try data.write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Could not save battery history: \(error.localizedDescription)"
        }
    }
}
