import Foundation

@main
struct AnalyticsHarness {
    static func main() async throws {
        try await testFlatDischargeAndPersistence()
        try await testShortDrainEpisode()
        try await testChargingSession()
        try await testClearPersistsEmptyHistory()
        try await testClearPersistenceFailurePreservesHistory()
        try await testClearRemovesRecoveryBackupsOnly()
        try await testCorruptHistoryIsQuarantinedBeforeRecoveryWrite()
        testForecastAndExperiment()
        print("Analytics and persistence checks passed")
    }

    private static func testFlatDischargeAndPersistence() async throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for minute in 0...60 {
            await store.record(snapshot: makeSnapshot(date: base.addingTimeInterval(Double(minute * 60)),
                                                      percentage: 100 - Double(minute / 6), drainWatts: 10))
        }
        let end = base.addingTimeInterval(3_600)
        let history = await store.history(for: .today, now: end)
        precondition(history.snapshots.count == 61, "Flat readings must be retained")
        let report = AnalyticsEngine.summarize(history, now: end)
        assertClose(report.metrics.batteryConsumedPercent, 10)
        assertClose(report.metrics.averageDischargePercentPerHour, 10)
        assertClose(report.metrics.estimatedBatteryLifeHours, 10)
        precondition(report.dailyUse.count == 1)
        assertClose(report.dailyUse[0].consumedPercent, 10)
        await store.record(event: TimelineEvent(date: base.addingTimeInterval(1_800),
                                               kind: .chargerDisconnected, detail: nil))
        let reopened = HistoryStore(fileURL: file)
        let loaded = await reopened.history(for: .today, now: end)
        precondition(loaded.snapshots.count == 61 && loaded.events.count == 1,
                     "Snapshots and events must survive a restart")
        precondition(loaded.events[0].kind == .chargerDisconnected)
        let persistenceError = await reopened.lastPersistenceError
        precondition(persistenceError == nil)
    }

    private static func testShortDrainEpisode() async throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let base = Date(timeIntervalSince1970: 1_800_100_000)
        for (index, percent) in [90.0, 89, 80, 70, 69].enumerated() {
            let date = base.addingTimeInterval(Double(index * 600))
            let process = ProcessImpact(pid: 101, name: "Chrome", cpuPercent: 80, estimatedShare: 65)
            await store.record(snapshot: makeSnapshot(date: date, percentage: percent,
                drainWatts: index == 0 || index == 4 ? 8 : 24,
                temperatureCelsius: index == 2 ? 47 : 35),
                processes: index == 0 || index == 4 ? [] : [process])
        }
        await store.record(event: TimelineEvent(date: base.addingTimeInterval(1_200),
                                               kind: .highDrain, detail: nil))
        let history = await HistoryStore(fileURL: file).history(for: .today,
                                                                now: base.addingTimeInterval(2_400))
        precondition(history.processSamples.count == 3, "Process readings must persist")
        guard let episode = AnalyticsEngine.drainEpisodes(history).first else {
            preconditionFailure("Short drain spike must be detected")
        }
        precondition(episode.end.timeIntervalSince(episode.start) <= 1_800)
        precondition(episode.percentLost >= 19)
        precondition(episode.contributors.contains { $0.title == "Chrome" })
        precondition(episode.contributors.contains { $0.title == "Elevated temperature" })
        precondition(episode.contributors.contains { $0.title == "High power draw" })
        guard let chrome = episode.contributors.first(where: { $0.title == "Chrome" }) else {
            preconditionFailure("Chrome should include process evidence")
        }
        precondition(chrome.explanation.contains("3 process readings")
            && chrome.explanation.contains("20 min"),
            "Contributor explanation must report observed reading count and duration")
        precondition(!chrome.explanation.contains("(count)")
            && !chrome.explanation.contains("(Int("),
            "Contributor explanation must not expose unexpanded interpolation")
    }

    private static func testChargingSession() async throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let base = Date(timeIntervalSince1970: 1_800_200_000)
        await store.record(snapshot: makeSnapshot(date: base.addingTimeInterval(-60), percentage: 24, drainWatts: 8))
        for (minute, percent, watts) in [(0, 24.0, 30.0), (15, 30, 40)] {
            await store.record(snapshot: makeSnapshot(date: base.addingTimeInterval(Double(minute * 60)),
                percentage: percent, source: .charger, state: .charging, chargeWatts: watts))
        }
        let reopened = HistoryStore(fileURL: file)
        for (minute, percent, watts) in [(45, 60.0, 60.0), (60, 83, 50)] {
            await reopened.record(snapshot: makeSnapshot(date: base.addingTimeInterval(Double(minute * 60)),
                percentage: percent, source: .charger, state: .charging, chargeWatts: watts))
        }
        await reopened.record(snapshot: makeSnapshot(date: base.addingTimeInterval(3_900),
                                                      percentage: 82, drainWatts: 8))
        let history = await HistoryStore(fileURL: file).history(for: .today,
                                                                now: base.addingTimeInterval(3_900))
        precondition(history.chargingSessions.count == 1, "Charging session must persist")
        let session = history.chargingSessions[0]
        precondition(session.start == base && session.end == base.addingTimeInterval(3_900))
        assertClose(session.startPercent, 24)
        assertClose(session.endPercent, 83)
        assertClose(session.peakWatts, 60)
        assertClose(session.averageWatts, 45)
        let curve = AnalyticsEngine.chargingCurve(for: session, history: history)
        precondition(curve.count >= 4)
        assertClose(curve[0].minutesFromStart, 0)
        assertClose(curve[3].minutesFromStart, 60)
        let metrics = AnalyticsEngine.metrics(history, now: base.addingTimeInterval(3_900))
        precondition(metrics.chargingSessionCount == 1)
        assertClose(metrics.averageChargeStartPercent, 24)
        assertClose(metrics.pluggedInHours, 1)
    }

    private static func testForecastAndExperiment() {
        let base = Date(timeIntervalSince1970: 1_800_300_000)
        let samples = [5.0, 5, 10, 20, 20].enumerated().map { index, draw in
            makeSnapshot(date: base.addingTimeInterval(Double(index * 60)),
                         percentage: 50, drainWatts: draw)
        }
        let history = BatteryHistory(snapshots: samples, events: [], processSamples: [], chargingSessions: [])
        let forecast = AnalyticsEngine.forecast(current: samples[2], history: history)
        assertClose(forecast.currentHours, 3)
        assertClose(forecast.lightUsageHours, 6)
        assertClose(forecast.heavyUsageHours, 1.5)
        let plugged = makeSnapshot(date: base, percentage: 50, source: .charger,
                                   state: .charging, chargeWatts: 20)
        precondition(AnalyticsEngine.forecast(current: plugged, history: history).currentHours == nil)

        let first = [10.0, 12, 14].enumerated().map { index, draw in
            makeSnapshot(date: base.addingTimeInterval(Double(index * 60)), percentage: 50, drainWatts: draw)
        }
        let second = [6.0, 8, 10].enumerated().map { index, draw in
            makeSnapshot(date: base.addingTimeInterval(Double((index + 3) * 60)),
                         percentage: 50, drainWatts: draw)
        }
        guard let result = AnalyticsEngine.compareExperiment(first: first, second: second) else {
            preconditionFailure("Three samples per phase should permit comparison")
        }
        assertClose(result.firstAverageWatts, 12)
        assertClose(result.secondAverageWatts, 8)
        assertClose(result.wattsSaved, 4)
        assertClose(result.percentSaved, 100 / 3)
        precondition(AnalyticsEngine.compareExperiment(first: Array(first.prefix(2)), second: second) == nil)
    }

    private static func testClearPersistsEmptyHistory() async throws {
        let (store, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let base = Date(timeIntervalSince1970: 1_800_400_000)
        await store.record(snapshot: makeSnapshot(date: base, percentage: 50,
            source: .charger, state: .charging, chargeWatts: 20),
            processes: [ProcessImpact(pid: 42, name: "Browser", cpuPercent: 20, estimatedShare: 10)])
        await store.record(snapshot: makeSnapshot(date: base.addingTimeInterval(60), percentage: 51,
            source: .charger, state: .charging, chargeWatts: 22))
        await store.record(event: TimelineEvent(date: base, kind: .chargerConnected, detail: nil))

        await store.clear()
        let cleared = await store.history(for: .today, now: base.addingTimeInterval(120))
        precondition(cleared.snapshots.isEmpty && cleared.events.isEmpty
            && cleared.processSamples.isEmpty && cleared.chargingSessions.isEmpty,
            "Clear must remove every retained history category")
        let clearError = await store.lastPersistenceError
        precondition(clearError == nil, "Successful clear must clear persistence errors")

        let reopened = HistoryStore(fileURL: file)
        let persisted = await reopened.history(for: .today, now: base.addingTimeInterval(120))
        precondition(persisted.snapshots.isEmpty && persisted.events.isEmpty
            && persisted.processSamples.isEmpty && persisted.chargingSessions.isEmpty,
            "Clear must persist across restart")
    }

    private static func testClearPersistenceFailurePreservesHistory() async throws {
        let (store, file) = makeStore()
        let base = Date(timeIntervalSince1970: 1_800_500_000)
        await store.record(snapshot: makeSnapshot(date: base, percentage: 70, drainWatts: 9))
        await store.record(event: TimelineEvent(date: base, kind: .highDrain, detail: nil))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file) }

        await store.clear()
        let afterFailure = await store.history(for: .today, now: base.addingTimeInterval(60))
        precondition(afterFailure.snapshots.count == 1 && afterFailure.events.count == 1,
            "Failed clear must not report success by discarding the in-memory archive")
        let error = await store.lastPersistenceError
        precondition(error?.contains("Could not save battery history") == true,
            "Failed clear must expose its persistence error")
    }

    private static func testCorruptHistoryIsQuarantinedBeforeRecoveryWrite() async throws {
        let (_, file) = makeStore()
        let corruptData = Data("{ this is not valid history json".utf8)
        try corruptData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let store = HistoryStore(fileURL: file)
        let initialError = await store.lastPersistenceError
        precondition(initialError?.contains("preserved the unreadable file") == true,
            "Unreadable history must produce a visible recovery message")
        let siblings = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
                                                                   includingPropertiesForKeys: nil)
        guard let quarantined = siblings.first(where: { $0.lastPathComponent.hasPrefix("\(file.lastPathComponent).corrupt-") }) else {
            preconditionFailure("Unreadable history must be quarantined before future writes")
        }
        defer { try? FileManager.default.removeItem(at: quarantined) }
        let preservedData = try Data(contentsOf: quarantined)
        precondition(preservedData == corruptData,
            "Quarantine must preserve the original bytes")

        let date = Date(timeIntervalSince1970: 1_800_600_000)
        await store.record(snapshot: makeSnapshot(date: date, percentage: 65, drainWatts: 8))
        let recoveredError = await store.lastPersistenceError
        precondition(recoveredError == nil, "A successful recovery write should clear the warning")
        let recovered = HistoryStore(fileURL: file)
        let history = await recovered.history(for: .today, now: date.addingTimeInterval(60))
        precondition(history.snapshots.count == 1, "New history should load after the recovery write")
    }

    private static func testClearRemovesRecoveryBackupsOnly() async throws {
        let (store, file) = makeStore()
        let backup = file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".corrupt-test-copy")
        let unrelated = file.deletingLastPathComponent().appendingPathComponent("other-history.json.corrupt-keep")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: unrelated)
        }
        try Data("old battery data".utf8).write(to: backup)
        try Data("unrelated data".utf8).write(to: unrelated)
        await store.record(snapshot: makeSnapshot(date: Date(timeIntervalSince1970: 1_800_700_000),
                                                   percentage: 60, drainWatts: 8))

        await store.clear()

        precondition(!FileManager.default.fileExists(atPath: backup.path),
            "Clear must delete recovery backups for this history file")
        precondition(FileManager.default.fileExists(atPath: unrelated.path),
            "Clear must preserve files outside the exact recovery backup prefix")
        let error = await store.lastPersistenceError
        precondition(error == nil, "Successful history and backup cleanup should report no persistence error")
    }

    private static func makeStore() -> (HistoryStore, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("battery-monitor-test-\(UUID().uuidString).json")
        return (HistoryStore(fileURL: file), file)
    }

    private static func makeSnapshot(date: Date, percentage: Double, source: PowerSource = .battery,
                                     state: BatteryState = .onBattery, drainWatts: Double? = nil,
                                     chargeWatts: Double? = nil,
                                     temperatureCelsius: Double = 35) -> BatterySnapshot {
        BatterySnapshot(date: date, percentage: percentage, state: state, source: source,
                        timeToFullMinutes: nil, timeRemainingMinutes: nil, drainWatts: drainWatts,
                        chargeWatts: chargeWatts, temperatureCelsius: temperatureCelsius, voltageVolts: 12,
                        maxCapacityMAh: 5_000, designCapacityMAh: 5_500, cycleCount: 100,
                        manufactureDate: nil, condition: nil, adapterWatts: nil, adapterName: nil)
    }

    private static func assertClose(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001) {
        guard let actual, actual.isFinite, abs(actual - expected) <= tolerance else {
            preconditionFailure("Expected \(expected), got \(String(describing: actual))")
        }
    }
}
