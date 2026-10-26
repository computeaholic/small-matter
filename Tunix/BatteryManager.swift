import IOKit
import IOKit.ps
import SwiftUI

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
    let voltageSource: TelemetrySource?
    let currentSource: TelemetrySource?
    let timeToEmptySource: TelemetrySource?
    let timeToFullSource: TelemetrySource?
    let temperatureSource: TelemetrySource?
}

private struct BatteryElectricalReadValues {
    let voltage: (value: Int, source: TelemetrySource)?
    let current: (value: Int, source: TelemetrySource)?
    let timeToEmpty: (value: Int, source: TelemetrySource)?
    let timeToFull: (value: Int, source: TelemetrySource)?
}

private struct BatteryStateReadValues {
    let present: Bool
    let isACConnected: Bool
    let isCharging: Bool
    let isFullyCharged: Bool
    let stateOfChargePercent: Double?
    let currentCapacityMAh: Int?
    let capacities: (maximum: Int?, design: Int?)
}

struct NativeBatteryTelemetryReader: BatteryTelemetryReading {
    private let temperatureReader: any BatteryTemperatureReading

    init(temperatureReader: any BatteryTemperatureReading = AppleSMCReadOnlyReader()) {
        self.temperatureReader = temperatureReader
    }

    func read() -> BatterySnapshot? {
        let powerSource = Self.readPowerSource()
        let registry = Self.readSmartBatteryProperties()
        let registryTemperature = Self.registryBatteryTemperature(registry)
        let fallbackTemperature = registryTemperature == nil
            ? temperatureReader.readBatteryTemperatureCelsius()
            : nil
        return Self.makeSnapshot(
            powerSource: powerSource,
            registry: registry,
            batteryTemperatureCelsius: registryTemperature ?? fallbackTemperature,
            batteryTemperatureSource: registryTemperature == nil
                ? (fallbackTemperature == nil ? nil : .appleSMC)
                : .ioRegistry
        )
    }

    static func makeSnapshot(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        batteryTemperatureCelsius: Double?,
        batteryTemperatureSource: TelemetrySource? = nil
    ) -> BatterySnapshot? {
        guard powerSource != nil || registry != nil else { return nil }
        let registryTemperature = Self.registryBatteryTemperature(registry)
        let observedTemperature = batteryTemperatureCelsius ?? registryTemperature
        let observedTemperatureSource = batteryTemperatureSource
            ?? (batteryTemperatureCelsius == nil && registryTemperature != nil ? .ioRegistry : nil)
        let values = Self.readValues(
            powerSource: powerSource,
            registry: registry,
            batteryTemperatureCelsius: observedTemperature
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
            temperatureCelsius: observedTemperature,
            timeToEmptyMinutes: values.timeToEmptyMinutes,
            timeToFullMinutes: values.timeToFullMinutes,
            temperatureSource: observedTemperature == nil
                ? nil
                : (observedTemperatureSource ?? values.temperatureSource ?? .appleSMC),
            voltageSource: values.voltageSource,
            currentSource: values.currentSource,
            powerSource: values.voltageMillivolts != nil && values.currentMilliamps != nil
                ? (values.voltageSource == values.currentSource ? values.voltageSource : nil)
                : nil,
            timeToEmptySource: values.timeToEmptySource,
            timeToFullSource: values.timeToFullSource
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
        let state = Self.readState(
            powerSource: powerSource,
            registry: registry,
            batteryData: batteryData
        )

        let operatingState = BatteryStateResolver.resolve(
            present: state.present,
            isACConnected: state.isACConnected,
            isCharging: state.isCharging,
            isFullyCharged: state.isFullyCharged
        )
        let electrical = Self.readElectricalValues(
            powerSource: powerSource,
            registry: registry,
            operatingState: operatingState
        )

        return BatteryReadValues(
            present: state.present,
            isACConnected: state.isACConnected,
            isCharging: state.isCharging,
            isFullyCharged: state.isFullyCharged,
            stateOfChargePercent: state.stateOfChargePercent,
            currentCapacityMAh: state.currentCapacityMAh,
            maxCapacityMAh: state.capacities.maximum,
            designCapacityMAh: state.capacities.design,
            cycleCount: Self.integer(registry?["CycleCount"]),
            voltageMillivolts: electrical.voltage?.value,
            currentMilliamps: electrical.current?.value,
            temperatureCelsius: batteryTemperatureCelsius,
            timeToEmptyMinutes: electrical.timeToEmpty?.value,
            timeToFullMinutes: electrical.timeToFull?.value,
            voltageSource: electrical.voltage?.source,
            currentSource: electrical.current?.source,
            timeToEmptySource: electrical.timeToEmpty?.source,
            timeToFullSource: electrical.timeToFull?.source,
            temperatureSource: batteryTemperatureCelsius == nil ? nil : .appleSMC
        )
    }

    static func readState(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> BatteryStateReadValues {
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
        return BatteryStateReadValues(
            present: present,
            isACConnected: isACConnected,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            stateOfChargePercent: Self.chargePercent(
                powerSource: powerSource,
                registry: registry,
                currentCapacityMAh: currentCapacityMAh,
                maxCapacityMAh: capacities.maximum
            ),
            currentCapacityMAh: currentCapacityMAh,
            capacities: capacities
        )
    }

    static func readElectricalValues(
        powerSource: [String: Any]?,
        registry: [String: Any]?,
        operatingState: BatteryOperatingState
    ) -> BatteryElectricalReadValues {
        let voltage = Self.firstValid(
            [
                (registry?["Voltage"], TelemetrySource.ioRegistry),
                (registry?["AppleRawBatteryVoltage"], .ioRegistry),
                (powerSource?[kIOPSVoltageKey], .powerSources)
            ],
            validator: BatteryPowerModel.validVoltageMillivolts
        )
        let current = Self.firstValid(
            [
                (registry?["InstantAmperage"], .ioRegistry),
                (registry?["Amperage"], .ioRegistry),
                (powerSource?[kIOPSCurrentKey], .powerSources)
            ],
            validator: BatteryPowerModel.validCurrentMilliamps
        )
        let timeToEmpty = Self.firstValid(
            [
                (registry?["AvgTimeToEmpty"], .ioRegistry),
                (registry?["TimeRemaining"], .ioRegistry)
            ],
            validator: Self.validMinutes
        )
        let timeToFull = Self.firstValid(
            [(registry?["AvgTimeToFull"], .ioRegistry)],
            validator: Self.validMinutes
        )
        return BatteryElectricalReadValues(
            voltage: voltage,
            current: current,
            timeToEmpty: operatingState == .discharging ? timeToEmpty : nil,
            timeToFull: operatingState == .charging ? timeToFull : nil
        )
    }

    static func registryBatteryTemperature(_ registry: [String: Any]?) -> Double? {
        let batteryData = registry?["BatteryData"] as? [String: Any]
        let raw = integer(registry?["Temperature"]) ?? integer(batteryData?["Temperature"])
        return BatteryPowerModel.temperatureCelsius(rawTenthsKelvin: raw)
    }

    static func firstValid(
        _ candidates: [(Any?, TelemetrySource)],
        validator: (Int?) -> Int?
    ) -> (value: Int, source: TelemetrySource)? {
        for (candidate, source) in candidates {
            if let value = validator(integer(candidate)) {
                return (value, source)
            }
        }
        return nil
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
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite,
                  doubleValue.rounded() == doubleValue,
                  doubleValue >= Double(Int.min),
                  doubleValue <= Double(Int.max)
            else { return nil }
            return Int(doubleValue)
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
