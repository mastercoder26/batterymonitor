import Foundation

@main
struct RuntimeTests {
    @MainActor
    static func main() async {
        testBatteryReaderWhenHardwareIsAvailable()
        testSettingsRoundTrip()
        await testAppModelLoadsHistoryWithoutRefreshing()
        print("Runtime checks passed")
    }

    private static func testBatteryReaderWhenHardwareIsAvailable() {
        guard let snapshot = BatteryReader().read() else {
            print("No internal battery telemetry is available on this Mac; skipped telemetry range checks")
            return
        }

        precondition(snapshot.percentage.isFinite && (0...100).contains(snapshot.percentage),
                     "Battery percentage must be finite and between 0 and 100")
        if let minutes = snapshot.timeToFullMinutes {
            precondition(minutes >= 0 && minutes < 65_535, "Time to full must be a valid IOPS duration")
        }
        if let minutes = snapshot.timeRemainingMinutes {
            precondition(minutes >= 0 && minutes < 65_535, "Time remaining must be a valid IOPS duration")
        }
        if let watts = snapshot.drainWatts {
            precondition(watts.isFinite && watts > 0 && watts < 900, "Drain power must be finite and plausible")
        }
        if let watts = snapshot.chargeWatts {
            precondition(watts.isFinite && watts > 0 && watts < 900, "Charge power must be finite and plausible")
        }
        if let temperature = snapshot.temperatureCelsius {
            precondition(temperature.isFinite && (-20...100).contains(temperature),
                         "Battery temperature must be within the reader's accepted range")
        }
        if let voltage = snapshot.voltageVolts {
            precondition(voltage.isFinite && voltage >= 0, "Voltage must be finite and nonnegative")
        }
        if let capacity = snapshot.maxCapacityMAh {
            precondition(capacity > 0, "Maximum capacity must be positive")
        }
        if let capacity = snapshot.designCapacityMAh {
            precondition(capacity > 0, "Design capacity must be positive")
        }
        if let cycles = snapshot.cycleCount {
            precondition(cycles >= 0, "Cycle count must be nonnegative")
        }
    }

    @MainActor
    private static func testSettingsRoundTrip() {
        // AppModel reads the existing settings from UserDefaults; this test never assigns them.
        let settings = AppModel().settings
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: data)
        precondition(decoded.menuStyle == settings.menuStyle)
        precondition(decoded.lowBatteryAlert == settings.lowBatteryAlert)
        precondition(decoded.fullChargeAlert == settings.fullChargeAlert)
        precondition(decoded.highDrainAlert == settings.highDrainAlert)
        precondition(decoded.highTemperatureAlert == settings.highTemperatureAlert)
        precondition(decoded.healthAlert == settings.healthAlert)
        precondition(decoded.chargerDisconnectedAlert == settings.chargerDisconnectedAlert)
        precondition(decoded.chargeTargetAlert == settings.chargeTargetAlert)
        precondition(decoded.chargeTargetPercent == settings.chargeTargetPercent)
        precondition(decoded.highTemperatureThreshold == settings.highTemperatureThreshold)
        precondition(decoded.highDrainThreshold == settings.highDrainThreshold)
        precondition(decoded.healthThreshold == settings.healthThreshold)
    }

    @MainActor
    private static func testAppModelLoadsHistoryWithoutRefreshing() async {
        let model = AppModel()
        precondition(model.snapshot == nil, "A fresh model should not claim a live reading before refresh")
        precondition(model.menuBarTitle == "Battery")
        precondition(model.menuBarSymbol == "battery.0percent")

        // Changing the in-memory period triggers AppModel's normal read-only history load.
        // Do not call refresh(): it can persist a real sample or issue a notification.
        model.selectedPeriod = .month
        for _ in 0..<100 where model.analytics == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.analytics != nil, "AppModel should load analytics for the selected history period")
        precondition(model.samples.allSatisfy { $0.percentage.isFinite && (0...100).contains($0.percentage) },
                     "Loaded history should contain valid battery percentages")
        precondition(model.events.allSatisfy { $0.date <= .now.addingTimeInterval(60) },
                     "Loaded timeline events should have plausible timestamps")
    }
}
