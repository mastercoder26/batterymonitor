import Charts
import SwiftUI

private enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
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
