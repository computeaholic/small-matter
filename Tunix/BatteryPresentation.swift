import SwiftUI

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
        temperatureDisplay(for: .system)
    }

    func temperatureDisplay(for unit: TemperatureDisplayUnit) -> String {
        TemperaturePresentation.string(celsius: snapshot.temperatureCelsius, unit: unit)
    }

    var temperatureStatusText: String {
        snapshot.temperatureCelsius == nil ? "Unavailable" : snapshot.source.rawValue
    }

    var timeToEmptyDisplay: String {
        if let minutes = snapshot.timeToEmptyMinutes {
            return Self.formatMinutes(minutes)
        }
        switch snapshot.operatingState {
        case .connectedNotCharging: return "Connected to power"
        case .fullyCharged: return "Fully charged"
        case .charging, .discharging, .unavailable: return "Unavailable"
        }
    }

    var timeToFullDisplay: String {
        if let minutes = snapshot.timeToFullMinutes {
            return Self.formatMinutes(minutes)
        }
        switch snapshot.operatingState {
        case .connectedNotCharging: return "Not charging"
        case .fullyCharged: return "Fully charged"
        case .charging: return "Estimating…"
        case .discharging, .unavailable: return "Unavailable"
        }
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
