import IOKit
import IOKit.ps
import SwiftUI

/// Compatibility value retained for the existing pure charge-percentage tests.
/// Production UI reads one immutable `BatterySnapshot` instead.
struct BatteryStatus {
    var isPresent: Bool = false
    var isCharging: Bool = false
    var powerSource: String = "Unknown"
    var currentCapacity: Int = 0
    var maxCapacity: Int = 0
    var designCapacity: Int = 0
    var cycleCount: Int? = .none
    var voltage: Int = 0
    var amperage: Int = 0
    var hasVoltageReading = false
    var hasAmperageReading = false
}

struct ChargeDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let chargeLevel: Double
    let isCharging: Bool
    let temperature: Double?
}

protocol BatteryTelemetryReading {
    func read() -> BatterySnapshot?
}

protocol BatteryTemperatureReading {
    func readBatteryTemperatureCelsius() -> Double?
}

enum BatteryCapacityModel {
    static func maximumCapacity(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> Int? {
        valid(integer(registry?["AppleRawMaxCapacity"]))
            ?? valid(integer(batteryData?["FullChargeCapacity"]))
            ?? valid(integer(registry?["NominalChargeCapacity"]))
            ?? valid(integer(batteryData?["NominalChargeCapacity"]))
    }

    static func designCapacity(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> Int? {
        valid(integer(registry?["DesignCapacity"]))
            ?? valid(integer(batteryData?["DesignCapacity"]))
    }

    static func capacities(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> (maximum: Int?, design: Int?) {
        (
            maximum: maximumCapacity(registry: registry, batteryData: batteryData),
            design: designCapacity(registry: registry, batteryData: batteryData)
        )
    }

    static func valid(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65535 else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

private struct BatteryReadValues {
    let present: Bool
    let isACConnected: Bool
    let isCharging: Bool
    let isFullyCharged: Bool
    let stateOfChargePercent: Double?
    let currentCapacityMAh: Int?
    let maxCapacityMAh: Int?
    let designCapacityMAh: Int?
    let cycleCount: Int?
    let voltageMillivolts: Int?
    let currentMilliamps: Int?
    let temperatureCelsius: Double?
    let timeToEmptyMinutes: Int?
    let timeToFullMinutes: Int?
}

struct NativeBatteryTelemetryReader: BatteryTelemetryReading {
    private let temperatureReader: any BatteryTemperatureReading

    init(temperatureReader: any BatteryTemperatureReading = AppleSMCReadOnlyReader()) {
        self.temperatureReader = temperatureReader
    }

    func read() -> BatterySnapshot? {
        let powerSource = Self.readPowerSource()
        let registry = Self.readSmartBatteryProperties()
        return Self.makeSnapshot(
            powerSource: powerSource,
            registry: registry,
            batteryTemperatureCelsius: temperatureReader.readBatteryTemperatureCelsius()
        )
    }

    static func makeSnapshot(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        batteryTemperatureCelsius: Double?
    ) -> BatterySnapshot? {
        guard powerSource != nil || registry != nil else { return nil }
        let values = Self.readValues(
            powerSource: powerSource,
            registry: registry,
            batteryTemperatureCelsius: batteryTemperatureCelsius
        )
        return BatterySnapshot(
            timestamp: .now,
            availability: .valid,
            source: registry == nil ? .powerSources : .ioRegistry,
            present: values.present,
            isACConnected: values.isACConnected,
            isCharging: values.isCharging,
            isFullyCharged: values.isFullyCharged,
            stateOfChargePercent: values.stateOfChargePercent,
            currentCapacityMAh: values.currentCapacityMAh,
            maxCapacityMAh: values.maxCapacityMAh,
            designCapacityMAh: values.designCapacityMAh,
            healthPercent: BatteryPowerModel.healthPercent(
                maxCapacityMAh: values.maxCapacityMAh,
                designCapacityMAh: values.designCapacityMAh
            ),
            cycleCount: values.cycleCount,
            voltageMillivolts: values.voltageMillivolts,
            currentMilliamps: values.currentMilliamps,
            powerWatts: BatteryPowerModel.watts(
                voltageMillivolts: values.voltageMillivolts,
                currentMilliamps: values.currentMilliamps
            ),
            temperatureCelsius: values.temperatureCelsius,
            timeToEmptyMinutes: values.timeToEmptyMinutes,
            timeToFullMinutes: values.timeToFullMinutes,
            temperatureSource: values.temperatureCelsius == nil ? nil : .appleSMC
        )
    }
}

private extension NativeBatteryTelemetryReader {
    static func readValues(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        batteryTemperatureCelsius: Double?
    ) -> BatteryReadValues {
        let batteryData = registry?["BatteryData"] as? [String: Any]
        let present = Self.bool(registry?["BatteryInstalled"]) ?? (powerSource != nil)
        let powerSourceState = Self.string(powerSource?[kIOPSPowerSourceStateKey])
        let isACConnected = Self.bool(registry?["ExternalConnected"])
            ?? (powerSourceState == "AC Power")
        let isCharging = Self.bool(registry?["IsCharging"])
            ?? Self.bool(powerSource?[kIOPSIsChargingKey])
            ?? false
        let isFullyCharged = Self.bool(registry?["FullyCharged"])
            ?? Self.bool(powerSource?["Fully Charged"])
            ?? false

        let currentCapacityMAh = Self.integer(registry?["AppleRawCurrentCapacity"])
        let capacities = BatteryCapacityModel.capacities(
            registry: registry,
            batteryData: batteryData
        )
        let stateOfChargePercent = Self.chargePercent(
            powerSource: powerSource,
            registry: registry,
            currentCapacityMAh: currentCapacityMAh,
            maxCapacityMAh: capacities.maximum
        )

        let voltageMillivolts = Self.integer(registry?["Voltage"])
            ?? Self.integer(registry?["AppleRawBatteryVoltage"])
            ?? Self.integer(powerSource?[kIOPSVoltageKey])
        let currentMilliamps = Self.integer(registry?["InstantAmperage"])
            ?? Self.integer(registry?["Amperage"])
            ?? Self.integer(powerSource?[kIOPSCurrentKey])
        let timeToEmptyMinutes = Self.validMinutes(Self.integer(registry?["AvgTimeToEmpty"]))
            ?? Self.validMinutes(Self.integer(registry?["TimeRemaining"]))
        let timeToFullMinutes = Self.validMinutes(Self.integer(registry?["AvgTimeToFull"]))

        return BatteryReadValues(
            present: present,
            isACConnected: isACConnected,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            stateOfChargePercent: stateOfChargePercent,
            currentCapacityMAh: currentCapacityMAh,
            maxCapacityMAh: capacities.maximum,
            designCapacityMAh: capacities.design,
            cycleCount: Self.integer(registry?["CycleCount"]),
            voltageMillivolts: voltageMillivolts,
            currentMilliamps: currentMilliamps,
            temperatureCelsius: batteryTemperatureCelsius,
            timeToEmptyMinutes: timeToEmptyMinutes,
            timeToFullMinutes: timeToFullMinutes
        )
    }

    static func readPowerSource() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
              as? [String: Any]
        else {
            return nil
        }
        return description
    }

    static func readSmartBatteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties
        else {
            return nil
        }
        return properties.takeRetainedValue() as? [String: Any]
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func chargePercent(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        currentCapacityMAh: Int?,
        maxCapacityMAh: Int?
    ) -> Double? {
        if let current = integer(powerSource?[kIOPSCurrentCapacityKey]),
           let maximum = integer(powerSource?[kIOPSMaxCapacityKey]),
           maximum > 0 {
            return min(max(Double(current) / Double(maximum) * 100, 0), 100)
        }
        if let currentCapacityMAh, let maxCapacityMAh, maxCapacityMAh > 0 {
            return min(max(Double(currentCapacityMAh) / Double(maxCapacityMAh) * 100, 0), 100)
        }
        if let batteryData = registry?["BatteryData"] as? [String: Any],
           let stateOfCharge = integer(batteryData["StateOfCharge"]) {
            return min(max(Double(stateOfCharge), 0), 100)
        }
        return nil
    }

    static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65535 else { return nil }
        return value
    }
}
