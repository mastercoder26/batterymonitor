import Foundation
import IOKit
import IOKit.ps

struct BatteryReader {
    func read() -> BatterySnapshot? {
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.compactMap({ IOPSGetPowerSourceDescription(powerSources, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { ($0[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) })
        else { return nil }

        let sourceName = source[kIOPSPowerSourceStateKey as String] as? String
        let isOnCharger = sourceName == (kIOPSACPowerValue as String)
        let isCharging = (source[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue ?? false
        let isFull = (source[kIOPSIsChargedKey as String] as? NSNumber)?.boolValue ?? false
        guard let percentage = (source[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue,
              percentage.isFinite else { return nil }

        let state: BatteryState
        if !isOnCharger {
            state = .onBattery
        } else if isCharging {
            state = .charging
        } else if isFull {
            state = .full
        } else {
            state = .pluggedIn
        }

        return BatterySnapshot(
            date: Date(),
            percentage: min(100, max(0, percentage)),
            state: state,
            source: sourceName == (kIOPSBatteryPowerValue as String) ? .battery : (isOnCharger ? .charger : .unknown),
            timeToFullMinutes: validMinutes(source[kIOPSTimeToFullChargeKey as String]),
            timeRemainingMinutes: validMinutes(source[kIOPSTimeToEmptyKey as String])
        )
    }

    private func validMinutes(_ value: Any?) -> Int? {
        guard let minutes = (value as? NSNumber)?.intValue, minutes >= 0, minutes < 65_535 else { return nil }
        return minutes
    }
}
