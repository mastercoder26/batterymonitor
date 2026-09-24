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
    var dailyUse: [DailyBatteryUse]
    var healthTrend: [BatteryHealthPoint]
}

enum AnalyticsEngine {
    static func summarize(_ history: BatteryHistory, current: BatterySnapshot? = nil,
                          now: Date = .now, calendar: Calendar = .current) -> BatteryAnalytics {
        BatteryAnalytics(
            metrics: metrics(history, now: now),
            forecast: forecast(current: current ?? history.snapshots.last, history: history),
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

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}
