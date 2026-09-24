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
        var activeChargeWattSum: Double = 0
        var activeChargeWattCount: Int = 0
    }

    private let fileURL: URL
    private var archive: Archive
    private var lastCompaction: Date = .distantPast
    private(set) var lastPersistenceError: String?
    private var persistenceBlockedByRecoveryFailure = false

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatteryMonitor", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("history.json")
        do {
            let data = try Data(contentsOf: self.fileURL)
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            archive = Archive()
        } catch {
            archive = Archive()
            let loadError = error.localizedDescription
            do {
                let quarantineURL = self.fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(self.fileURL.lastPathComponent).corrupt-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: self.fileURL, to: quarantineURL)
                lastPersistenceError = "Could not load battery history; preserved the unreadable file at \(quarantineURL.path): \(loadError)"
            } catch {
                persistenceBlockedByRecoveryFailure = true
                lastPersistenceError = "Could not load battery history and could not preserve the unreadable file; writes are blocked: \(loadError). \(error.localizedDescription)"
            }
        }
    }

    func record(snapshot: BatterySnapshot, processes: [ProcessImpact] = []) {
        let previous = archive.snapshots.last
        guard previous == nil || snapshot.date > previous!.date else { return }

        updateChargingSession(with: snapshot, previous: previous)
        archive.snapshots.append(snapshot)
        if !processes.isEmpty {
            let last = archive.processSamples.last?.date ?? .distantPast
            if snapshot.date.timeIntervalSince(last) >= 30 {
                archive.processSamples.append(ProcessSample(date: snapshot.date, processes: processes))
            }
        }
        if snapshot.date.timeIntervalSince(lastCompaction) >= 15 * 60 {
            compact(now: snapshot.date)
            lastCompaction = snapshot.date
        }
        persist()
    }

    func record(event: TimelineEvent) {
        archive.events.append(event)
        archive.events.sort { $0.date < $1.date }
        compact(now: event.date)
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

    /// Removes all locally retained history. The in-memory archive is cleared
    /// only after the empty archive has been written successfully.
    func clear() {
        let previous = archive
        archive = Archive()
        if !persist() {
            archive = previous
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            let backupPrefix = fileURL.lastPathComponent + ".corrupt-"
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix(backupPrefix) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            lastPersistenceError = "Could not remove saved battery history backup: \(error.localizedDescription)"
        }
    }

    private func updateChargingSession(with snapshot: BatterySnapshot, previous: BatterySnapshot?) {
        let charging = snapshot.state == .charging || (snapshot.chargeWatts ?? 0) > 0
        let wasCharging = previous.map { $0.state == .charging || ($0.chargeWatts ?? 0) > 0 } ?? false
        if charging && !wasCharging {
            archive.chargingSessions.append(ChargingSession(start: snapshot.date, end: nil,
                startPercent: snapshot.percentage, endPercent: snapshot.percentage,
                peakWatts: snapshot.chargeWatts, averageWatts: snapshot.chargeWatts))
            archive.activeChargeWattSum = 0
            archive.activeChargeWattCount = 0
        }
        guard let index = archive.chargingSessions.indices.last, archive.chargingSessions[index].end == nil else { return }
        if charging {
            archive.chargingSessions[index].endPercent = snapshot.percentage
            if let watts = snapshot.chargeWatts, watts >= 0, watts.isFinite {
                archive.activeChargeWattSum += watts
                archive.activeChargeWattCount += 1
                archive.chargingSessions[index].peakWatts = max(archive.chargingSessions[index].peakWatts ?? 0, watts)
                archive.chargingSessions[index].averageWatts = archive.activeChargeWattSum / Double(archive.activeChargeWattCount)
            }
        } else {
            archive.chargingSessions[index].end = snapshot.date
            // The first unplugged reading may already have fallen below the
            // last charging reading. Keep the final charged percentage.
            archive.activeChargeWattSum = 0
            archive.activeChargeWattCount = 0
        }
    }

    private func compact(now: Date) {
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        archive.snapshots = downsample(archive.snapshots.filter { $0.date >= cutoff }, now: now) { $0.date }
        archive.processSamples = downsample(archive.processSamples.filter { $0.date >= cutoff }, now: now) { $0.date }
        archive.events.removeAll { $0.date < cutoff }
        archive.chargingSessions.removeAll { ($0.end ?? now) < cutoff }
    }

    /// Keeps every sample for two days, one per five minutes for two weeks,
    /// and one per hour thereafter. First and latest observations survive.
    private func downsample<T>(_ items: [T], now: Date, date: (T) -> Date) -> [T] {
        guard items.count > 2 else { return items }
        var result: [T] = []
        var lastBucket: Int?
        for (index, item) in items.enumerated() {
            let age = now.timeIntervalSince(date(item))
            let width: TimeInterval = age < 2 * 86_400 ? 0 : age < 14 * 86_400 ? 300 : 3_600
            let bucket = width == 0 ? nil : Int(date(item).timeIntervalSince1970 / width)
            if index == 0 || index == items.count - 1 || width == 0 || bucket != lastBucket {
                result.append(item)
            }
            lastBucket = bucket
        }
        return result
    }

    @discardableResult
    private func persist() -> Bool {
        guard !persistenceBlockedByRecoveryFailure else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(archive)
            try data.write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = "Could not save battery history: \(error.localizedDescription)"
            return false
        }
    }
}
