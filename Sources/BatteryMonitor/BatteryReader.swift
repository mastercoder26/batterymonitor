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

        let registry = batteryProperties()
        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        let sourceName = source[kIOPSPowerSourceStateKey as String] as? String
        let isOnCharger = sourceName == (kIOPSACPowerValue as String)
        let isCharging = bool(source[kIOPSIsChargingKey as String]) ?? false
        let isFull = bool(source[kIOPSIsChargedKey as String]) ?? false
        let percentage = number(source[kIOPSCurrentCapacityKey as String])?.doubleValue
        guard let percentage, percentage.isFinite else { return nil }

        let state: BatteryState
        if !isOnCharger {
            state = .onBattery
        } else if isCharging {
            state = .charging
        } else if isFull {
            state = .full
        } else if bool(registry["ChargingPaused"]) == true || bool(registry["OptimizedBatteryChargingPaused"]) == true {
            state = .paused
        } else {
            // AC power with no charging indication can also mean a charge limit or weak adapter.
            state = .pluggedIn
        }

        let millivolts = number(registry["Voltage"])?.doubleValue
        let milliamps = number(registry["Amperage"])?.doubleValue
        let watts: Double? = {
            guard let millivolts, let milliamps,
                  (5_000...30_000).contains(millivolts), abs(milliamps) < 30_000 else { return nil }
            return abs(millivolts * milliamps) / 1_000_000
        }()
        let temperature: Double? = {
            guard let raw = number(registry["Temperature"] ?? batteryData["Temperature"])?.doubleValue
                    ?? descendantTemperatureRaw() else { return nil }
            // AppleSmartBattery reports this value in hundredths of a degree Celsius.
            let celsius = raw / 100
            return (-20...100).contains(celsius) ? celsius : nil
        }()

        let adapter = adapterProperties()
        let adapterWatts = number(adapter["Watts"])?.intValue
        let manufactureDate = packedManufactureDate(number(registry["ManufactureDate"] ?? batteryData["ManufactureDate"])?.intValue)

        return BatterySnapshot(
            date: Date(),
            percentage: min(100, max(0, percentage)),
            state: state,
            source: sourceName == (kIOPSBatteryPowerValue as String) ? .battery : (isOnCharger ? .charger : .unknown),
            // IOPS can return zero while AC is connected and charging is paused.
            timeToFullMinutes: validTimeToFull(source[kIOPSTimeToFullChargeKey as String], isFull: isFull),
            timeRemainingMinutes: validMinutes(source[kIOPSTimeToEmptyKey as String]),
            // A negative battery current is a measured drain even with an adapter attached.
            drainWatts: (milliamps ?? 0) < 0 ? watts : nil,
            chargeWatts: isCharging && (milliamps ?? 0) > 0 ? watts : nil,
            temperatureCelsius: temperature,
            voltageVolts: millivolts.map { $0 / 1_000 },
            // Top-level MaxCapacity is often 100 (percent), not mAh.
            maxCapacityMAh: positiveInt(batteryData["FullChargeCapacity"] ?? batteryData["AppleRawMaxCapacity"] ?? registry["AppleRawMaxCapacity"]),
            designCapacityMAh: positiveInt(batteryData["DesignCapacity"] ?? registry["DesignCapacity"]),
            cycleCount: nonnegativeInt(registry["CycleCount"]),
            manufactureDate: manufactureDate,
            condition: source[kIOPSBatteryHealthKey as String] as? String,
            adapterWatts: isOnCharger ? adapterWatts : nil,
            adapterName: isOnCharger ? (adapter["Name"] as? String) : nil,
            batteryIsPresent: bool(source[kIOPSIsPresentKey as String]) ?? true
        )
    }

    private func batteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private func adapterProperties() -> [String: Any] {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private func descendantTemperatureRaw() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return temperatureRaw(inChildrenOf: service, depth: 0)
    }

    private func temperatureRaw(inChildrenOf entry: io_registry_entry_t, depth: Int) -> Double? {
        guard depth < 4 else { return nil }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let values = properties?.takeRetainedValue() as? [String: Any] {
                let batteryData = values["BatteryData"] as? [String: Any]
                if let raw = number(values["Temperature"] ?? batteryData?["Temperature"])?.doubleValue {
                    return raw
                }
            }
            if let raw = temperatureRaw(inChildrenOf: child, depth: depth + 1) { return raw }
        }
        return nil
    }

    private func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
    private func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
    private func positiveInt(_ value: Any?) -> Int? {
        guard let number = number(value)?.intValue, number > 0 else { return nil }
        return number
    }
    private func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = number(value)?.intValue, number >= 0 else { return nil }
        return number
    }
    private func validMinutes(_ value: Any?) -> Int? {
        guard let minutes = number(value)?.intValue, minutes >= 0, minutes < 65_535 else { return nil }
        return minutes
    }

    private func validTimeToFull(_ value: Any?, isFull: Bool) -> Int? {
        guard let minutes = validMinutes(value), minutes > 0 || isFull else { return nil }
        return minutes
    }

    private func packedManufactureDate(_ raw: Int?) -> Date? {
        // Some Macs use an undocumented wider format. Only decode the standard 16-bit date.
        guard let raw, raw > 0, raw <= 0xffff else { return nil }
        let day = raw & 0x1f
        let month = (raw >> 5) & 0x0f
        let year = 1980 + ((raw >> 9) & 0x7f)
        guard (1...31).contains(day), (1...12).contains(month), year <= Calendar.current.component(.year, from: Date()) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }
}
