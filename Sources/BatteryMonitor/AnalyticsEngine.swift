import Foundation

struct HistoryMetrics: Sendable {
    var batteryConsumedPercent: Double
    var averageDailyDrainPercent: Double
    var averageDischargePercentPerHour: Double?
    var estimatedBatteryLifeHours: Double?
    var chargingSessionCount: Int
    var averageChargeStartPercent: Double?
    var pluggedInHours: Double
    var above80PercentHours: Double
    var cycleCountChange: Int?
    /// macOS does not expose a dependable screen-on history to this app.
    var screenOnHours: Double? = nil
}

struct BatteryForecast: Sendable {
    var currentHours: Double?
    var lightUsageHours: Double?
    var heavyUsageHours: Double?
    var basis: String
}

struct DrainContributor: Sendable, Identifiable {
    var id: String { title }
    var title: String
    var explanation: String
}

struct DrainEpisode: Sendable, Identifiable {
    var id: Date { start }
    var start: Date
    var end: Date
    var percentLost: Double
    var averageWatts: Double?
    var contributors: [DrainContributor]
}

struct DailyBatteryUse: Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var consumedPercent: Double
    var observedHours: Double
}

struct BatteryHealthPoint: Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var healthPercent: Double
}

struct ChargingCurvePoint: Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var minutesFromStart: Double
    var percentage: Double
    var watts: Double?
}

struct ExperimentComparison: Sendable {
    var firstAverageWatts: Double
    var secondAverageWatts: Double
    /// Positive means the second interval drew less power.
    var wattsSaved: Double
    var percentSaved: Double
    var firstSampleCount: Int
    var secondSampleCount: Int
}

struct BatteryAnalytics: Sendable {
    var metrics: HistoryMetrics
    var forecast: BatteryForecast
    var drainEpisodes: [DrainEpisode]
    var dailyUse: [DailyBatteryUse]
    var healthTrend: [BatteryHealthPoint]
}

enum AnalyticsEngine {
    static func summarize(_ history: BatteryHistory, current: BatterySnapshot? = nil,
                          now: Date = .now, calendar: Calendar = .current) -> BatteryAnalytics {
        BatteryAnalytics(
            metrics: metrics(history, now: now),
            forecast: forecast(current: current ?? history.snapshots.last, history: history),
            drainEpisodes: drainEpisodes(history),
            dailyUse: dailyUse(history, calendar: calendar),
            healthTrend: healthTrend(history, calendar: calendar)
        )
    }

    static func metrics(_ history: BatteryHistory, now: Date = .now) -> HistoryMetrics {
        let samples = history.snapshots.sorted { $0.date < $1.date }
        var consumed = 0.0
        var dischargeHours = 0.0
        var pluggedHours = 0.0
        var above80Hours = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let hours = b.date.timeIntervalSince(a.date) / 3_600
            guard hours > 0, hours <= 1 else { continue }
            if a.source == .battery && b.source == .battery {
                let loss = max(0, a.percentage - b.percentage)
                consumed += loss
                dischargeHours += hours
            }
            if a.source == .charger && b.source == .charger { pluggedHours += hours }
            if a.percentage > 80 && b.percentage > 80 { above80Hours += hours }
        }
        let rate = dischargeHours > 0 ? consumed / dischargeHours : nil
        let starts = history.chargingSessions.map(\.startPercent)
        let firstCycle = samples.compactMap(\.cycleCount).first
        let lastCycle = samples.compactMap(\.cycleCount).last
        let durationDays = max(1, (now.timeIntervalSince(samples.first?.date ?? now)) / 86_400)
        return HistoryMetrics(
            batteryConsumedPercent: consumed,
            averageDailyDrainPercent: consumed / durationDays,
            averageDischargePercentPerHour: rate,
            estimatedBatteryLifeHours: rate.flatMap { $0 > 0 ? 100 / $0 : nil },
            chargingSessionCount: history.chargingSessions.count,
            averageChargeStartPercent: starts.isEmpty ? nil : starts.reduce(0, +) / Double(starts.count),
            pluggedInHours: pluggedHours,
            above80PercentHours: above80Hours,
            cycleCountChange: firstCycle.flatMap { first in lastCycle.map { max(0, $0 - first) } }
        )
    }

    static func forecast(current: BatterySnapshot?, history: BatteryHistory) -> BatteryForecast {
        guard let current, current.source == .battery, current.percentage > 0 else {
            return BatteryForecast(currentHours: nil, lightUsageHours: nil, heavyUsageHours: nil,
                                   basis: "Available while running on battery")
        }
        let watts = history.snapshots.compactMap { sample -> Double? in
            guard sample.source == .battery, let draw = sample.drainWatts,
                  draw > 0, draw.isFinite else { return nil }
            return draw
        }.sorted()
        let capacityWh: Double? = {
            guard let mAh = current.maxCapacityMAh, mAh > 0,
                  let volts = current.voltageVolts, volts > 0 else { return nil }
            return Double(mAh) * volts / 1_000 * current.percentage / 100
        }()
        if let capacityWh, !watts.isEmpty {
            let light = percentile(watts, 0.20)
            let heavy = percentile(watts, 0.80)
            let currentDraw = (current.drainWatts ?? 0) > 0 ? current.drainWatts! : percentile(watts, 0.50)
            return BatteryForecast(currentHours: capacityWh / currentDraw,
                                   lightUsageHours: capacityWh / light,
                                   heavyUsageHours: capacityWh / heavy,
                                   basis: "Measured battery draw and recent workload")
        }
        let rate = metrics(history).averageDischargePercentPerHour
        let derived = rate.flatMap { $0 > 0 ? current.percentage / $0 : nil }
        let os = current.timeRemainingMinutes.map { Double($0) / 60 }
        return BatteryForecast(currentHours: derived ?? os,
                               lightUsageHours: nil, heavyUsageHours: nil,
                               basis: derived == nil ? "System estimate" : "Observed discharge rate")
    }

    static func drainEpisodes(_ history: BatteryHistory, minimumDrop: Double = 10) -> [DrainEpisode] {
        let samples = history.snapshots.sorted { $0.date < $1.date }
        var groups: [[BatterySnapshot]] = []
        var group: [BatterySnapshot] = []
        for sample in samples {
            if sample.source != .battery {
                if group.count > 1 { groups.append(group) }
                group = []
                continue
            }
            if let previous = group.last, sample.date.timeIntervalSince(previous.date) > 30 * 60 {
                if group.count > 1 { groups.append(group) }
                group = []
            }
            group.append(sample)
        }
        if group.count > 1 { groups.append(group) }
        struct Candidate {
            let start: Int
            let end: Int
            let score: Double
        }
        var episodes: [DrainEpisode] = []
        for run in groups {
            var candidates: [Candidate] = []
            for start in 0..<(run.count - 1) {
                var best: Candidate?
                for end in (start + 1)..<run.count {
                    let seconds = run[end].date.timeIntervalSince(run[start].date)
                    if seconds > 2 * 3_600 { break }
                    if seconds < 10 * 60 { continue }
                    let loss = run[start].percentage - run[end].percentage
                    guard loss >= minimumDrop else { continue }
                    // Balance total loss against duration, so a short spike is not
                    // hidden inside an otherwise ordinary all-day discharge.
                    let score = loss / sqrt(max(0.25, seconds / 3_600))
                    if score > (best?.score ?? 0) { best = Candidate(start: start, end: end, score: score) }
                }
                if let best { candidates.append(best) }
            }
            candidates.sort { $0.score > $1.score }
            var selected: [Candidate] = []
            for candidate in candidates {
                guard !selected.contains(where: { candidate.start <= $0.end && candidate.end >= $0.start }) else { continue }
                selected.append(candidate)
                if selected.count == 3 { break }
            }
            for candidate in selected {
                let first = run[candidate.start]
                let last = run[candidate.end]
                let draws = run[candidate.start...candidate.end].compactMap(\.drainWatts)
                    .filter { $0 > 0 && $0.isFinite }
                episodes.append(DrainEpisode(start: first.date, end: last.date,
                    percentLost: first.percentage - last.percentage,
                    averageWatts: draws.isEmpty ? nil : draws.reduce(0, +) / Double(draws.count),
                    contributors: contributors(from: history, start: first.date, end: last.date)))
            }
        }
        return episodes.sorted { $0.end > $1.end }.prefix(12).map { $0 }
    }

    static func dailyUse(_ history: BatteryHistory, calendar: Calendar = .current) -> [DailyBatteryUse] {
        let samples = history.snapshots.sorted { $0.date < $1.date }
        var totals: [Date: (consumed: Double, hours: Double)] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let hours = b.date.timeIntervalSince(a.date) / 3_600
            guard hours > 0, hours <= 1, a.source == .battery, b.source == .battery else { continue }
            let day = calendar.startOfDay(for: a.date)
            let prior = totals[day] ?? (0, 0)
            totals[day] = (prior.consumed + max(0, a.percentage - b.percentage), prior.hours + hours)
        }
        return totals.map { DailyBatteryUse(date: $0.key, consumedPercent: $0.value.consumed,
                                            observedHours: $0.value.hours) }.sorted { $0.date < $1.date }
    }

    static func healthTrend(_ history: BatteryHistory, calendar: Calendar = .current) -> [BatteryHealthPoint] {
        var days: [Date: BatteryHealthPoint] = [:]
        for snapshot in history.snapshots.sorted(by: { $0.date < $1.date }) {
            guard let health = snapshot.healthPercent, health.isFinite else { continue }
            let day = calendar.startOfDay(for: snapshot.date)
            days[day] = BatteryHealthPoint(date: day, healthPercent: health)
        }
        return days.values.sorted { $0.date < $1.date }
    }

    static func chargingCurve(for session: ChargingSession, history: BatteryHistory) -> [ChargingCurvePoint] {
        let end = session.end ?? .distantFuture
        return history.snapshots.filter { $0.date >= session.start && $0.date <= end }
            .map { ChargingCurvePoint(date: $0.date,
                minutesFromStart: $0.date.timeIntervalSince(session.start) / 60,
                percentage: $0.percentage, watts: $0.chargeWatts) }
    }

    static func compareExperiment(first: [BatterySnapshot], second: [BatterySnapshot]) -> ExperimentComparison? {
        let a = first.compactMap { $0.source == .battery ? $0.drainWatts : nil }.filter { $0 > 0 && $0.isFinite }
        let b = second.compactMap { $0.source == .battery ? $0.drainWatts : nil }.filter { $0 > 0 && $0.isFinite }
        guard a.count >= 3, b.count >= 3 else { return nil }
        let firstMean = a.reduce(0, +) / Double(a.count)
        let secondMean = b.reduce(0, +) / Double(b.count)
        let saved = firstMean - secondMean
        return ExperimentComparison(firstAverageWatts: firstMean, secondAverageWatts: secondMean,
                                    wattsSaved: saved, percentSaved: saved / firstMean * 100,
                                    firstSampleCount: a.count, secondSampleCount: b.count)
    }

    private static func contributors(from history: BatteryHistory, start: Date, end: Date) -> [DrainContributor] {
        let processSamples = history.processSamples.filter { $0.date >= start && $0.date <= end }
        var byName: [String: (share: Double, dates: [Date])] = [:]
        for sample in processSamples {
            for process in sample.processes where process.estimatedShare > 0 {
                var prior = byName[process.name] ?? (0, [])
                prior.share += process.estimatedShare
                prior.dates.append(sample.date)
                byName[process.name] = prior
            }
        }
        var result = byName.sorted {
            $0.value.share / Double($0.value.dates.count) > $1.value.share / Double($1.value.dates.count)
        }.prefix(3).map { name, value in
            let count = value.dates.count
            let meanShare = Int((value.share / Double(count)).rounded())
            let observedMinutes = (value.dates.max()?.timeIntervalSince(value.dates.min() ?? .distantPast) ?? 0) / 60
            let evidence: String
            if count >= 3 && observedMinutes >= 5 {
                evidence = "Repeated readings across \(Int(observedMinutes.rounded())) min make this a plausible contributor"
            } else if count >= 2 {
                evidence = "Seen in only \(count) readings, so evidence is limited"
            } else {
                evidence = "Seen in one reading; this is a low-confidence lead"
            }
            return DrainContributor(title: name,
                explanation: "Seen in \(count) process readings across \(Int(observedMinutes.rounded())) min; average share of sampled CPU activity \(meanShare)%. \(evidence). This is CPU activity, not measured app wattage.")
        }
        let interval = history.snapshots.filter { $0.date >= start && $0.date <= end }
        let hot = interval.compactMap(\.temperatureCelsius).max()
        if let hot, hot >= 45 {
            result.append(DrainContributor(title: "Elevated temperature",
                explanation: "Battery temperature reached \(Int(hot.rounded()))°C during this interval"))
        }
        if history.events.contains(where: { $0.kind == .highDrain && $0.date >= start && $0.date <= end }) {
            result.append(DrainContributor(title: "High power draw",
                explanation: "Power draw crossed the high usage threshold during this interval"))
        }

        let nearbyEvents = history.events.filter {
            $0.date >= start.addingTimeInterval(-30 * 60) && $0.date <= end.addingTimeInterval(30 * 60)
        }
        let sleepWake = nearbyEvents.filter { $0.kind == .sleep || $0.kind == .wake }
        if !sleepWake.isEmpty {
            let labels = sleepWake.map { $0.kind.label.lowercased() }.joined(separator: " and ")
            result.append(DrainContributor(title: "Sleep / wake context",
                explanation: "Recorded \(labels) within 30 min of this episode. This timing is context only and does not establish that sleep caused the drain."))
        }

        let chargerEvents = nearbyEvents.filter { $0.kind == .chargerConnected || $0.kind == .chargerDisconnected }
        if !chargerEvents.isEmpty {
            let labels = chargerEvents.map { $0.kind.label.lowercased() }.joined(separator: " and ")
            result.append(DrainContributor(title: "Charger-state context",
                explanation: "Recorded charger transition: \(labels), within 30 min of this battery drain. The timing is context, not a measured cause."))
        }

        let batterySnapshots = interval.filter { $0.source == .battery }.sorted { $0.date < $1.date }
        if batterySnapshots.count >= 2 {
            let spanMinutes = batterySnapshots.last!.date.timeIntervalSince(batterySnapshots.first!.date) / 60
            if spanMinutes >= 5 {
                result.append(DrainContributor(title: "Observed on battery",
                    explanation: "Battery-powered readings span \(Int(spanMinutes.rounded())) min in this episode; the drain is based on the recorded percentage change."))
            }
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}
