import Charts
import SwiftUI

private enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case timeline = "Timeline"
    case insights = "Insights"
    case health = "Health"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .timeline: "chart.xyaxis.line"
        case .insights: "sparkle.magnifyingglass"
        case .health: "heart.text.square"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DashboardPage? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardPage.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol)
                    .tag(page)
                    .padding(.vertical, 5)
            }
            .listStyle(.sidebar)
            .navigationTitle("Battery Monitor")
            .frame(minWidth: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let historyError = model.historyError {
                        Label(historyError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    }
                    switch selection ?? .overview {
                    case .overview: overview
                    case .timeline: timeline
                    case .insights: insights
                    case .health: health
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 650)
        .tint(.green)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text((selection ?? .overview).rawValue)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = model.snapshot {
                Label(snapshot.state.label, systemImage: snapshot.source == .charger ? "bolt.fill" : "battery.100percent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(snapshot.source == .charger ? Color.green : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: Capsule())
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .help("Refresh battery data")
                .accessibilityLabel("Refresh battery data")
        }
    }

    private var headerSubtitle: String {
        guard let date = model.snapshot?.date else { return "Waiting for battery data" }
        return "Last updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let snapshot = model.snapshot {
                HStack(alignment: .top, spacing: 18) {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("LIVE BATTERY")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: snapshot.source == .charger ? "battery.100percent.bolt" : "battery.100percent")
                                    .font(.system(size: 29, weight: .light))
                                    .foregroundStyle(batteryColor(snapshot.percentage))
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(snapshot.percentage, format: .number.precision(.fractionLength(0)))
                                    .font(.system(size: 78, weight: .bold, design: .rounded))
                                Text("%")
                                    .font(.system(size: 36, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(batteryColor(snapshot.percentage))
                            ProgressView(value: min(max(snapshot.percentage, 0), 100), total: 100)
                                .tint(batteryColor(snapshot.percentage))
                            HStack {
                                Label(snapshot.state.label, systemImage: snapshot.source == .charger ? "bolt.fill" : "bolt.slash.fill")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(snapshot.source == .charger ? "Charger" : snapshot.source == .battery ? "Battery" : "Source unknown")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("POWER RIGHT NOW", systemImage: "bolt.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(powerHeadline(snapshot))
                                .font(.system(size: 33, weight: .bold, design: .rounded))
                            Text(powerDetail(snapshot))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Divider()
                            MetricRow(name: "System estimate", value: systemTime(snapshot))
                            MetricRow(name: "Constant use estimate", value: constantUseTime(snapshot))
                        }
                    }
                }

                HStack(spacing: 18) {
                    DashboardCard { compactMetric("Temperature", value: format(snapshot.temperatureCelsius, suffix: "°C"), symbol: "thermometer.medium") }
                    DashboardCard { compactMetric("Voltage", value: format(snapshot.voltageVolts, suffix: "V"), symbol: "bolt.horizontal.circle") }
                    DashboardCard { compactMetric("Battery health", value: format(snapshot.healthPercent, suffix: "%", digits: 0), symbol: "heart") }
                    DashboardCard { compactMetric("Cycle count", value: snapshot.cycleCount.map(String.init) ?? "Unavailable", symbol: "arrow.triangle.2.circlepath") }
                }

                HStack(alignment: .top, spacing: 18) {
                    DashboardCard {
                        SectionHeading(title: "Battery today", detail: "Charge level over time")
                        HStack(spacing: 10) {
                            MetricPill(title: "Drained", value: String(format: "%.0f%%", todayMovement.drained))
                            MetricPill(title: "Charged", value: String(format: "%.0f%%", todayMovement.charged))
                        }
                        BatteryChart(samples: filteredSamples(.today), events: model.events.filter { $0.date >= Date().addingTimeInterval(-HistoryPeriod.today.interval) })
                            .frame(height: filteredSamples(.today).count > 1 ? 205 : 95)
                    }
                    DashboardCard {
                        SectionHeading(title: "App activity", detail: "Estimated share from current process activity")
                        processList(limit: 4)
                    }
                }
            } else {
                EmptyDashboard(message: "Battery readings will appear here as soon as your Mac reports them.", symbol: "battery.100percent")
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 18) {
            periodPicker
            DashboardCard {
                SectionHeading(title: "Battery timeline", detail: "Charge level and recorded events")
                BatteryChart(samples: filteredSamples(model.selectedPeriod), events: filteredEvents)
                    .frame(height: 310)
            }
            DashboardCard {
                SectionHeading(title: "Flight recorder", detail: "Events captured while Battery Monitor was running")
                let events = filteredEvents
                if events.isEmpty {
                    InlineEmpty(message: "No events recorded in this period.")
                } else {
                    ForEach(events.sorted { $0.date > $1.date }) { event in
                        HStack(spacing: 12) {
                            Image(systemName: eventSymbol(event.kind))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(event.kind == .highDrain || event.kind == .lowBattery ? .orange : .accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.kind.label).fontWeight(.medium)
                                if let detail = event.detail, !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(event.date.formatted(date: model.selectedPeriod == .today ? .omitted : .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var insights: some View {
        VStack(alignment: .leading, spacing: 18) {
            periodPicker
            HStack(alignment: .top, spacing: 18) {
                DashboardCard {
                    SectionHeading(title: "Real-time drain", detail: "Battery discharge at this moment")
                    if let snapshot = model.snapshot, let watts = snapshot.drainWatts, watts > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(watts, format: .number.precision(.fractionLength(1)))
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                            Text("W").font(.title2).foregroundStyle(.secondary)
                        }
                        Text(drainLabel(watts))
                            .font(.headline)
                            .foregroundStyle(watts >= model.settings.highDrainThreshold ? .orange : .green)
                        Text("The threshold is configurable in Settings. Constant use estimate: \(constantUseTime(snapshot)).")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        InlineEmpty(message: "Drain appears while running on battery.")
                    }
                }
                DashboardCard {
                    SectionHeading(title: "Today's efficiency", detail: "Experimental score from today's observed battery use")
                    if let efficiency = todayEfficiency {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(efficiency.score)")
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                            Text("/ 100").font(.title2).foregroundStyle(.secondary)
                        }
                        Text("Average measured drain: \(String(format: "%.1f", efficiency.averageWatts)) W" + (efficiency.averageTemperature.map { " · Temperature: \(String(format: "%.1f", $0))°C" } ?? ""))
                            .font(.subheadline)
                        Text("Lower sustained draw and temperature raise this experimental score. It does not measure battery health or per-app watts.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        InlineEmpty(message: "Needs at least five saved readings spanning ten minutes on battery today.")
                    }
                }
            }
            DashboardCard {
                SectionHeading(title: "What drained my battery?", detail: "Likely contributors from readings recorded during the drain")
                if let episode = model.analytics?.drainEpisodes.first {
                    Text("Battery dropped \(Int(episode.percentLost.rounded()))% between \(episode.start.formatted(date: .omitted, time: .shortened)) and \(episode.end.formatted(date: .omitted, time: .shortened)).")
                        .font(.headline)
                    if let average = episode.averageWatts {
                        Text("Average draw: \(String(format: "%.1f", average)) W")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(episode.contributors) { contributor in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contributor.title).fontWeight(.medium)
                            Text(contributor.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("These are correlations from sampled activity, not measured per-app battery watts.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let drop = largestDrop {
                    Text("Battery dropped \(Int(drop.amount.rounded()))% between \(drop.start.formatted(date: .omitted, time: .shortened)) and \(drop.end.formatted(date: .omitted, time: .shortened)).")
                        .font(.headline)
                    Text("A larger recorded interval is needed for contributor analysis.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    InlineEmpty(message: "More battery history is needed to identify a drain interval.")
                }
            }
            DashboardCard {
                SectionHeading(title: "App power usage", detail: "CPU-based activity estimate; per-app watts are not available from this source")
                processList(limit: 10)
            }
            DashboardCard {
                SectionHeading(title: "Battery forecast", detail: "Simple scenarios from observed discharge rates")
                forecastContent
            }
            DashboardCard {
                SectionHeading(title: "Usage history", detail: "Measured while Battery Monitor was running")
                if let metrics = model.analytics?.metrics {
                    HStack(spacing: 12) {
                        MetricPill(title: "Battery consumed", value: String(format: "%.0f%%", metrics.batteryConsumedPercent))
                        MetricPill(title: "Average discharge", value: metrics.averageDischargePercentPerHour.map { String(format: "%.1f%%/h", $0) } ?? "Unavailable")
                        MetricPill(title: "Charging sessions", value: "\(metrics.chargingSessionCount)")
                        MetricPill(title: "Plugged in", value: String(format: "%.1f h", metrics.pluggedInHours))
                    }
                    HStack(spacing: 12) {
                        MetricPill(title: "Above 80%", value: String(format: "%.1f h", metrics.above80PercentHours))
                        MetricPill(title: "Average charge start", value: metrics.averageChargeStartPercent.map { String(format: "%.0f%%", $0) } ?? "Unavailable")
                        MetricPill(title: "Cycle count change", value: metrics.cycleCountChange.map(String.init) ?? "Unavailable")
                        MetricPill(title: "Screen-on time", value: "Unavailable")
                    }
                } else {
                    InlineEmpty(message: "History totals will appear after readings are saved.")
                }
            }
            DashboardCard {
                SectionHeading(title: "Daily battery use", detail: "Color shows battery consumed while sampling was active")
                let useByDay = Dictionary(uniqueKeysWithValues: (model.analytics?.dailyUse ?? []).map { (Calendar.current.startOfDay(for: $0.date), $0) })
                if useByDay.isEmpty {
                    InlineEmpty(message: "Daily use will appear as history builds up.")
                } else {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { index in
                            Text(weekdayName(index))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 7) {
                        ForEach(0..<heatmapLeadingDays, id: \.self) { _ in
                            Color.clear.frame(height: 35)
                        }
                        ForEach(heatmapDates, id: \.self) { date in
                            let day = useByDay[date]
                            RoundedRectangle(cornerRadius: 6)
                                .fill(day.map { Color.green.opacity(min(0.9, max(0.15, $0.consumedPercent / 150))) } ?? Color(nsColor: .separatorColor).opacity(0.25))
                                .frame(height: 35)
                                .help(day.map { "\(date.formatted(date: .abbreviated, time: .omitted)): \(Int($0.consumedPercent.rounded()))% consumed over \(String(format: "%.1f", $0.observedHours)) h observed" } ?? "\(date.formatted(date: .abbreviated, time: .omitted)): no readings")
                        }
                    }
                }
            }
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 18) {
            periodPicker
            if let snapshot = model.snapshot {
                HStack(spacing: 18) {
                    DashboardCard { compactMetric("Battery health", value: format(snapshot.healthPercent, suffix: "%", digits: 0), symbol: "heart.fill") }
                    DashboardCard { compactMetric("Maximum capacity", value: snapshot.maxCapacityMAh.map { "\($0) mAh" } ?? "Unavailable", symbol: "battery.100percent") }
                    DashboardCard { compactMetric("Design capacity", value: snapshot.designCapacityMAh.map { "\($0) mAh" } ?? "Unavailable", symbol: "shippingbox") }
                    DashboardCard { compactMetric("Cycle count", value: snapshot.cycleCount.map(String.init) ?? "Unavailable", symbol: "arrow.triangle.2.circlepath") }
                }
                DashboardCard {
                    SectionHeading(title: "Capacity over time", detail: "Measured health from saved battery readings")
                    let points = healthSamples
                    if points.count > 1 {
                        let values = points.map(\.health)
                        let lower = max(0, (values.min() ?? 90) - 3)
                        let upper = min(110, (values.max() ?? 100) + 3)
                        Chart(points) { point in
                            AreaMark(x: .value("Date", point.date), yStart: .value("Chart baseline", lower), yEnd: .value("Health", point.health))
                                .foregroundStyle(.green.opacity(0.12))
                            LineMark(x: .value("Date", point.date), y: .value("Health", point.health))
                                .foregroundStyle(.green)
                                .lineStyle(StrokeStyle(lineWidth: 2.5))
                        }
                        .chartYScale(domain: lower...max(lower + 1, upper))
                        .frame(height: 250)
                        if let trend = healthMonthlyTrend {
                            Text(String(format: "Observed change: %+.2f percentage points per month", trend))
                                .font(.subheadline.weight(.medium))
                            Text("Based on observations at least a week apart. Short-term capacity readings can fluctuate.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        InlineEmpty(message: "Health history will appear after multiple readings are saved.")
                    }
                }
                DashboardCard {
                    SectionHeading(title: "Battery details", detail: "Values reported by macOS and the battery controller")
                    MetricRow(name: "Condition", value: snapshot.condition ?? "Unavailable")
                    MetricRow(name: "Manufactured", value: snapshot.manufactureDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unavailable")
                    MetricRow(name: "Battery age", value: batteryAge(snapshot.manufactureDate))
                    MetricRow(name: "Capacity lost", value: snapshot.healthPercent.map { String(format: "%.1f%%", max(0, 100 - $0)) } ?? "Unavailable")
                }
            } else {
                EmptyDashboard(message: "Battery health data is unavailable until the first reading.", symbol: "heart.text.square")
            }
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: Binding(get: { model.selectedPeriod }, set: { model.selectedPeriod = $0 })) {
            ForEach(HistoryPeriod.allCases) { period in Text(period.rawValue).tag(period) }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
    }

    @ViewBuilder private var forecastContent: some View {
        if let forecast = model.analytics?.forecast {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MetricPill(title: "Current workload", value: forecastHours(forecast.currentHours))
                    MetricPill(title: "Light observed use", value: forecastHours(forecast.lightUsageHours))
                    MetricPill(title: "Heavy observed use", value: forecastHours(forecast.heavyUsageHours))
                }
                Text(forecast.basis).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let draws = model.samples.compactMap(\.drainWatts).filter { $0 > 0 }
            let sorted = draws.sorted()
            HStack(spacing: 12) {
                MetricPill(title: "Current workload", value: model.snapshot.map(constantUseTime) ?? "Unavailable")
                MetricPill(title: "Light observed use", value: forecast(draw: sorted.isEmpty ? nil : sorted[sorted.count / 4]))
                MetricPill(title: "Heavy observed use", value: forecast(draw: sorted.isEmpty ? nil : sorted[sorted.count * 3 / 4]))
            }
        }
    }

    private var heatmapDates: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -34, to: .now) ?? .now)
        return (0..<35).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var heatmapLeadingDays: Int {
        guard let first = heatmapDates.first else { return 0 }
        let calendar = Calendar.current
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }

    private func weekdayName(_ index: Int) -> String {
        let calendar = Calendar.current
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return names[(calendar.firstWeekday - 1 + index) % 7]
    }

    private func forecastHours(_ hours: Double?) -> String {
        guard let hours, hours > 0, hours.isFinite else { return "Unavailable" }
        return "~" + duration(Int((hours * 60).rounded()))
    }

    private func compactMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processList(limit: Int) -> some View {
        let items = Array(model.processes.sorted { $0.estimatedShare > $1.estimatedShare }.prefix(limit))
        return VStack(alignment: .leading, spacing: 9) {
            if !model.collectProcessActivity {
                InlineEmpty(message: "Process activity collection is off. Turn it on in Settings to see app names and CPU-based estimates.")
            } else if items.isEmpty {
                InlineEmpty(message: "Process activity will appear after sampling.")
            } else {
                ForEach(items) { process in
                    HStack {
                        Image(systemName: "app.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(shareLabel(process.estimatedShare))
                            .fontWeight(.medium)
                        Text(impactLabel(process.estimatedShare))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.subheadline)
                    if process.id != items.last?.id { Divider() }
                }
            }
        }
    }

    private func shareLabel(_ share: Double) -> String {
        return String(format: "%.0f%% est.", min(max(share, 0), 100))
    }

    private func impactLabel(_ share: Double) -> String {
        switch share {
        case ..<10: "Low"
        case ..<25: "Moderate"
        case ..<50: "High"
        default: "Extreme"
        }
    }

    private var filteredEvents: [TimelineEvent] {
        model.events.filter { $0.date >= Date().addingTimeInterval(-model.selectedPeriod.interval) }
    }

    private var todayMovement: (drained: Double, charged: Double) {
        let points = filteredSamples(.today)
        var drained = 0.0
        var charged = 0.0
        for (a, b) in zip(points, points.dropFirst()) where b.date.timeIntervalSince(a.date) <= 3_600 {
            let change = b.percentage - a.percentage
            if change < 0 { drained -= change }
            else { charged += change }
        }
        return (drained, charged)
    }

    private func filteredSamples(_ period: HistoryPeriod) -> [BatterySnapshot] {
        model.samples.filter { $0.date >= Date().addingTimeInterval(-period.interval) }.sorted { $0.date < $1.date }
    }

    private var healthSamples: [HealthPoint] {
        model.samples.compactMap { snapshot in
            snapshot.healthPercent.map { HealthPoint(date: snapshot.date, health: $0) }
        }
    }

    private var healthMonthlyTrend: Double? {
        let points = healthSamples.sorted { $0.date < $1.date }
        guard let first = points.first, let last = points.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 7 else { return nil }
        return (last.health - first.health) / days * 30
    }

    private var largestDrop: (start: Date, end: Date, amount: Double)? {
        let samples = filteredSamples(model.selectedPeriod)
        guard samples.count > 1 else { return nil }
        var result: (Date, Date, Double)?
        for pair in zip(samples, samples.dropFirst()) where pair.0.source == .battery && pair.1.source == .battery {
            let delta = pair.0.percentage - pair.1.percentage
            if delta > (result?.2 ?? 0) { result = (pair.0.date, pair.1.date, delta) }
        }
        return result.map { (start: $0.0, end: $0.1, amount: $0.2) }
    }

    private var todayEfficiency: (score: Int, averageWatts: Double, averageTemperature: Double?)? {
        let readings = filteredSamples(.today).filter { $0.source == .battery && ($0.drainWatts ?? 0) > 0 }
        guard readings.count >= 5,
              let first = readings.first, let last = readings.last,
              last.date.timeIntervalSince(first.date) >= 600 else { return nil }
        let averageWatts = readings.compactMap(\.drainWatts).reduce(0, +) / Double(readings.count)
        let temperatures = readings.compactMap(\.temperatureCelsius)
        let averageTemperature = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
        let drawPenalty = max(0, averageWatts - 8) * 2
        let heatPenalty = max(0, (averageTemperature ?? 35) - 40) * 2
        let score = Int(max(0, min(100, 100 - drawPenalty - heatPenalty)).rounded())
        return (score, averageWatts, averageTemperature)
    }

    private func batteryColor(_ percentage: Double) -> Color {
        percentage <= 20 ? .orange : .green
    }

    private func drainLabel(_ watts: Double) -> String {
        watts >= model.settings.highDrainThreshold ? "High usage" : "Normal usage"
    }

    private func powerHeadline(_ snapshot: BatterySnapshot) -> String {
        if snapshot.source == .charger {
            if let watts = snapshot.chargeWatts, watts > 0 { return format(watts, suffix: "W") }
            if let watts = snapshot.drainWatts, watts > 0 { return "\(format(watts, suffix: "W")) drain" }
            if snapshot.state == .full { return "Fully charged" }
            if snapshot.state == .paused { return "Charging paused" }
            return "Not charging"
        }
        return format(snapshot.drainWatts, suffix: "W")
    }

    private func powerDetail(_ snapshot: BatterySnapshot) -> String {
        if snapshot.source == .charger {
            if let drain = snapshot.drainWatts, drain > 0 { return "Battery is discharging while the adapter is connected." }
            return snapshot.chargeWatts == nil ? "Plugged in; battery charge flow is not reported in this state." : "Battery charging power"
        }
        return "Current battery drain"
    }

    private func systemTime(_ snapshot: BatterySnapshot) -> String {
        if snapshot.source == .charger {
            if snapshot.state == .full { return "Full" }
            guard snapshot.state == .charging, let minutes = snapshot.timeToFullMinutes, minutes > 0 else { return "Unavailable" }
            return duration(minutes)
        }
        return duration(snapshot.timeRemainingMinutes)
    }

    private func constantUseTime(_ snapshot: BatterySnapshot) -> String {
        snapshot.source == .battery ? forecast(snapshot: snapshot, draw: snapshot.drainWatts) : "On battery only"
    }

    private func forecast(draw: Double?) -> String {
        guard let snapshot = model.snapshot else { return "Unavailable" }
        return forecast(snapshot: snapshot, draw: draw)
    }

    private func forecast(snapshot: BatterySnapshot, draw: Double?) -> String {
        guard snapshot.source == .battery,
              let draw, draw > 0,
              let capacity = snapshot.maxCapacityMAh,
              let voltage = snapshot.voltageVolts, voltage > 0 else { return "Unavailable" }
        let wattHours = Double(capacity) / 1000 * voltage * snapshot.percentage / 100
        let minutes = Int((wattHours / draw * 60).rounded())
        return minutes > 0 && minutes < 10_000 ? "~" + duration(minutes) : "Unavailable"
    }

    private func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "Unavailable" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func format(_ value: Double?, suffix: String, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.*f %@", digits, value, suffix)
    }

    private func batteryAge(_ date: Date?) -> String {
        guard let date else { return "Unavailable" }
        let months = Calendar.current.dateComponents([.month], from: date, to: .now).month ?? 0
        guard months >= 0 else { return "Unavailable" }
        return months >= 12 ? "\(months / 12)y \(months % 12)m" : "\(months)m"
    }

    private func eventSymbol(_ kind: TimelineEventKind) -> String {
        switch kind {
        case .chargerConnected: "powerplug.fill"
        case .chargerDisconnected: "powerplug"
        case .sleep: "moon.zzz.fill"
        case .wake: "sunrise.fill"
        case .highDrain: "bolt.trianglebadge.exclamationmark.fill"
        case .lowBattery: "battery.25percent"
        case .fullCharge: "battery.100percent"
        case .processSpike: "app.badge"
        case .highTemperature: "thermometer.high"
        case .healthDrop: "heart.slash"
        }
    }

private struct HealthPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let health: Double
}

private struct DashboardCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
    }
}

private struct SectionHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MetricRow: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyDashboard: View {
    let message: String
    let symbol: String
    var body: some View {
        ContentUnavailableView("No battery data yet", systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct InlineEmpty: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 90)
    }
}

private struct BatteryChart: View {
    let samples: [BatterySnapshot]
    var events: [TimelineEvent] = []
    var body: some View {
        if samples.count > 1 {
            Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Zero", 0), yEnd: .value("Battery", sample.percentage))
                        .foregroundStyle(.green.opacity(0.12))
                    LineMark(x: .value("Time", sample.date), y: .value("Battery", sample.percentage))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                ForEach(events) { event in
                    RuleMark(x: .value("Event", event.date))
                        .foregroundStyle(.orange.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 2) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                                .help("\(event.kind.label) · \(event.date.formatted(date: .abbreviated, time: .shortened))\(event.detail.map { " · \($0)" } ?? "")")
                        }
                }
            }
            .chartYScale(domain: 0...100)
        } else {
            InlineEmpty(message: "The timeline will appear after a few readings.")
        }
    }
}

}
