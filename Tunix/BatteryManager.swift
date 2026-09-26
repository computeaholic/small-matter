// swiftlint:disable file_length
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
    func read() -> BatterySnapshot? {
        let powerSource = Self.readPowerSource()
        let registry = Self.readSmartBatteryProperties()
        guard powerSource != nil || registry != nil else { return nil }
        let values = Self.readValues(powerSource: powerSource, registry: registry)

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
            timeToFullMinutes: values.timeToFullMinutes
        )
    }
}

private extension NativeBatteryTelemetryReader {
    static func readValues(
        powerSource: [String: Any]?,
        registry: [String: Any]?
    ) -> BatteryReadValues {
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
        let maxCapacityMAh = Self.integer(registry?["AppleRawMaxCapacity"])
            ?? Self.integer(registry?["NominalChargeCapacity"])
        let designCapacityMAh = Self.integer(registry?["DesignCapacity"])
        let stateOfChargePercent = Self.chargePercent(
            powerSource: powerSource,
            registry: registry,
            currentCapacityMAh: currentCapacityMAh,
            maxCapacityMAh: maxCapacityMAh
        )

        let voltageMillivolts = Self.integer(registry?["Voltage"])
            ?? Self.integer(registry?["AppleRawBatteryVoltage"])
            ?? Self.integer(powerSource?[kIOPSVoltageKey])
        let currentMilliamps = Self.integer(registry?["InstantAmperage"])
            ?? Self.integer(registry?["Amperage"])
            ?? Self.integer(powerSource?[kIOPSCurrentKey])
        let temperatureCelsius = BatteryPowerModel.temperatureCelsius(
            rawTenthsKelvin: Self.integer(registry?["Temperature"])
        )
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
            maxCapacityMAh: maxCapacityMAh,
            designCapacityMAh: designCapacityMAh,
            cycleCount: Self.integer(registry?["CycleCount"]),
            voltageMillivolts: voltageMillivolts,
            currentMilliamps: currentMilliamps,
            temperatureCelsius: temperatureCelsius,
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
           maximum > 0
        // swiftlint:disable:next opening_brace
        {
            return min(max(Double(current) / Double(maximum) * 100, 0), 100)
        }
        if let currentCapacityMAh, let maxCapacityMAh, maxCapacityMAh > 0 {
            return min(max(Double(currentCapacityMAh) / Double(maxCapacityMAh) * 100, 0), 100)
        }
        if let batteryData = registry?["BatteryData"] as? [String: Any],
           let stateOfCharge = integer(batteryData["StateOfCharge"])
        // swiftlint:disable:next opening_brace
        {
            return min(max(Double(stateOfCharge), 0), 100)
        }
        return nil
    }

    static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65535 else { return nil }
        return value
    }
}

@MainActor
final class BatteryManager: ObservableObject {
    @Published private(set) var snapshot = BatterySnapshot.unavailable
    @Published private(set) var lastUpdated: Date = .now
    @Published var lastMessage: String?
    @Published private(set) var chargeHistory: [ChargeDataPoint] = []
    @Published private(set) var lastSuccessfulSampleAt: Date?
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var consecutiveFailures = 0

    private let reader: any BatteryTelemetryReading
    private var timer: Timer?
    private let maxHistoryPoints = 288 // 24 hours at 5-minute intervals
    private let staleAfter: TimeInterval = 15
    private let unavailableAfter: TimeInterval = 60

    init(reader: any BatteryTelemetryReading = NativeBatteryTelemetryReader(), startTimer: Bool = true) {
        self.reader = reader
        refresh()
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        lastAttemptAt = .now
        guard let nextSnapshot = reader.read() else {
            recordFailure()
            return
        }

        snapshot = nextSnapshot.withAvailability(.valid)
        lastUpdated = nextSnapshot.timestamp
        lastSuccessfulSampleAt = nextSnapshot.timestamp
        consecutiveFailures = 0
        appendHistory(from: snapshot)
    }

    func updateTelemetryState(now: Date = .now) {
        guard let lastSuccessfulSampleAt else {
            snapshot = snapshot.withAvailability(.unavailable)
            return
        }
        snapshot = snapshot.withAvailability(
            BatteryTelemetryHealth(
                lastSuccessfulSampleAt: lastSuccessfulSampleAt,
                staleAfter: staleAfter,
                unavailableAfter: unavailableAfter
            ).state(at: now)
        )
    }

    private func recordFailure() {
        consecutiveFailures += 1
        updateTelemetryState()
    }

    private func appendHistory(from snapshot: BatterySnapshot) {
        guard let chargeLevel = snapshot.stateOfChargePercent else { return }
        chargeHistory.append(
            ChargeDataPoint(
                timestamp: snapshot.timestamp,
                chargeLevel: chargeLevel,
                isCharging: snapshot.isCharging,
                temperature: snapshot.temperatureCelsius
            )
        )
        if chargeHistory.count > maxHistoryPoints {
            chargeHistory.removeFirst(chargeHistory.count - maxHistoryPoints)
        }
    }

    func recentHistory(hours: Int) -> [ChargeDataPoint] {
        let cutoff = Date().addingTimeInterval(-Double(hours * 3600))
        return chargeHistory.filter { $0.timestamp >= cutoff }
    }

    var todayHistory: [ChargeDataPoint] {
        recentHistory(hours: 24)
    }

    var weekAverage: Double {
        let weekData = recentHistory(hours: 168)
        guard !weekData.isEmpty else { return 0 }
        return weekData.map(\.chargeLevel).reduce(0, +) / Double(weekData.count)
    }

    var isCharging: Bool {
        snapshot.operatingState == .charging
    }

    var batteryTelemetryAvailable: Bool {
        snapshot.availability != .unavailable && snapshot.present
    }

    var telemetryStatusLabel: String {
        snapshot.availability.label
    }

    var powerStateLabel: String {
        snapshot.operatingState.label
    }

    var powerDirectionDisplay: String {
        guard let power = snapshot.powerWatts else { return "Power Unavailable" }
        let magnitude = String(format: "%.1f W", abs(power))
        switch snapshot.operatingState {
        case .charging: return "Charging at \(magnitude)"
        case .discharging: return "Discharging at \(magnitude)"
        case .fullyCharged: return "Fully Charged · \(magnitude)"
        case .connectedNotCharging: return "Connected to Power · \(magnitude)"
        case .unavailable: return "Power Unavailable"
        }
    }

    var powerDisplay: String {
        guard let power = snapshot.powerWatts else { return "Unavailable" }
        return String(format: "%.1f W", abs(power))
    }

    var signedPowerDisplay: String {
        snapshot.powerWatts.map { String(format: "%.1f W", $0) } ?? "Unavailable"
    }

    var chargePercent: Double? {
        snapshot.stateOfChargePercent
    }

    var chargePercentString: String {
        guard let chargePercent else { return "Unavailable" }
        return String(format: "%.0f%%", chargePercent)
    }

    var healthPercentString: String {
        guard let healthPercent = snapshot.healthPercent else { return "Unavailable" }
        return String(format: "%.0f%%", min(max(healthPercent, 0), 100))
    }

    var cycleCountText: String {
        snapshot.cycleCount.map(String.init) ?? "Unavailable"
    }

    var maxCapacityDisplay: String {
        snapshot.maxCapacityMAh.map { "\($0) mAh" } ?? "Unavailable"
    }

    var designCapacityDisplay: String {
        snapshot.designCapacityMAh.map { "\($0) mAh" } ?? "Unavailable"
    }

    var voltageDisplay: String {
        guard let voltage = snapshot.voltageMillivolts else { return "Unavailable" }
        return String(format: "%.2f V", Double(voltage) / 1000)
    }

    var amperageDisplay: String {
        guard let current = snapshot.currentMilliamps else { return "Unavailable" }
        return String(format: "%.2f A", abs(Double(current) / 1000))
    }

    var temperatureDisplay: String {
        guard let temperature = snapshot.temperatureCelsius else { return "Unavailable" }
        return String(format: "%.1f°C", temperature)
    }

    var temperatureStatusText: String {
        snapshot.temperatureCelsius == nil ? "Unavailable" : snapshot.source.rawValue
    }

    var timeToEmptyDisplay: String {
        snapshot.timeToEmptyMinutes.map(Self.formatMinutes) ?? "Unavailable"
    }

    var timeToFullDisplay: String {
        snapshot.timeToFullMinutes.map(Self.formatMinutes) ?? "Unavailable"
    }

    var sourceDisplay: String {
        snapshot.source.rawValue
    }

    var staleAgeDisplay: String {
        guard let lastSuccessfulSampleAt else { return "Unavailable" }
        return Self.formatAge(Date().timeIntervalSince(lastSuccessfulSampleAt))
    }

    var status: BatteryStatus {
        BatteryStatus(
            isPresent: snapshot.present,
            isCharging: snapshot.isCharging,
            powerSource: snapshot.isACConnected ? "AC Power" : "Battery Power",
            currentCapacity: Int(snapshot.stateOfChargePercent ?? 0),
            maxCapacity: 100,
            designCapacity: 100,
            cycleCount: snapshot.cycleCount,
            voltage: snapshot.voltageMillivolts ?? 0,
            amperage: snapshot.currentMilliamps ?? 0,
            hasVoltageReading: snapshot.voltageMillivolts != nil,
            hasAmperageReading: snapshot.currentMilliamps != nil
        )
    }

    nonisolated static func chargePercent(from status: BatteryStatus) -> Double? {
        guard status.isPresent, status.maxCapacity > 0 else { return nil }
        let percent = Double(status.currentCapacity) / Double(status.maxCapacity) * 100
        return min(max(percent, 0), 100)
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        if age < 1 {
            return "Just now"
        }
        return String(format: "%.0fs ago", age)
    }
}
