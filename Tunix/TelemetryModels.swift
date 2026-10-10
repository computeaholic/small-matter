import Foundation

enum TelemetryFreshness: Equatable {
    case fresh
    case stale
    case unavailable

    var label: String {
        switch self {
        case .fresh: return "Telemetry Available"
        case .stale: return "Telemetry Stale"
        case .unavailable: return "Telemetry Unavailable"
        }
    }

    static var valid: Self {
        .fresh
    }
}

enum TelemetryErrorKind: String, Equatable {
    case sourceUnavailable = "SOURCE_UNAVAILABLE"
    case permissionDenied = "PERMISSION_DENIED"
    case invalidSample = "INVALID_SAMPLE"
    case unsupported = "UNSUPPORTED"
    case temporaryReadFailure = "TEMPORARY_READ_FAILURE"
    case other = "OTHER"
}

enum TelemetrySource: String, Equatable {
    case machHost = "Mach host processor API"
    case machVM = "Mach VM statistics"
    case networkInterfaces = "Native network interface counters"
    case fileSystem = "Native file-system attributes"
    case processInfo = "ProcessInfo"
    case appleSMC = "AppleSMC read-only app process"
    case ioRegistry = "AppleSmartBattery / IORegistry"
    case powerSources = "IOPowerSources"
    case unavailable = "Unavailable"
}

struct TelemetryHealth: Equatable {
    let lastAttemptAt: Date?
    let lastSuccessfulSampleAt: Date?
    let consecutiveFailures: Int
    let staleAfter: TimeInterval
    let unavailableAfter: TimeInterval

    func freshness(at now: Date) -> TelemetryFreshness {
        guard let lastSuccessfulSampleAt else { return .unavailable }
        let age = now.timeIntervalSince(lastSuccessfulSampleAt)
        if age >= unavailableAfter {
            return .unavailable
        }
        if age >= staleAfter {
            return .stale
        }
        return .fresh
    }
}

struct BoundedHistory<Value> {
    let limit: Int
    private(set) var values: [Value] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func append(_ value: Value) {
        values.append(value)
        if values.count > limit {
            values.removeFirst(values.count - limit)
        }
    }
}

struct ProcessorCPUTicks: Equatable {
    let identifier: Int
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 {
        user + system + idle + nice
    }

    var busy: UInt64 {
        user + system + nice
    }
}

struct CPUAggregateResult: Equatable {
    let totalUtilization: Double
    let userUtilization: Double
    let systemUtilization: Double
    let idleUtilization: Double
    let logicalCPUCount: Int
    let perCoreUtilization: [Int: Double]
}

enum CPUUsageCalculator {
    /// Calculates a single host-wide percentage from matching logical CPU
    /// counters. The matching identifier keeps Core N tied to Core N across
    /// samples; a counter reset invalidates the complete sample.
    static func calculate(
        previous: [ProcessorCPUTicks],
        current: [ProcessorCPUTicks]
    ) -> CPUAggregateResult? {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.identifier, $0) })
        var userDelta: UInt64 = 0
        var systemDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        var niceDelta: UInt64 = 0
        var perCore: [Int: Double] = [:]
        var matchedCount = 0

        for sample in current {
            guard let old = previousByID[sample.identifier],
                  sample.user >= old.user,
                  sample.system >= old.system,
                  sample.idle >= old.idle,
                  sample.nice >= old.nice
            else {
                return nil
            }

            let user = sample.user - old.user
            let system = sample.system - old.system
            let idle = sample.idle - old.idle
            let nice = sample.nice - old.nice
            let total = user + system + idle + nice
            guard total > 0 else { continue }

            userDelta += user
            systemDelta += system
            idleDelta += idle
            niceDelta += nice
            perCore[sample.identifier] = Double(user + system + nice) / Double(total) * 100
            matchedCount += 1
        }

        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard matchedCount > 0, totalDelta > 0 else { return nil }

        return CPUAggregateResult(
            totalUtilization: Double(userDelta + systemDelta + niceDelta) / Double(totalDelta) * 100,
            userUtilization: Double(userDelta) / Double(totalDelta) * 100,
            systemUtilization: Double(systemDelta) / Double(totalDelta) * 100,
            idleUtilization: Double(idleDelta) / Double(totalDelta) * 100,
            logicalCPUCount: current.count,
            perCoreUtilization: perCore
        )
    }
}

struct CPUSnapshot: Equatable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let totalUtilization: Double
    let userUtilization: Double
    let systemUtilization: Double
    let idleUtilization: Double
    let logicalCPUCount: Int
    let perCoreUtilization: [Int: Double]

    static let empty = CPUSnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .unavailable,
        totalUtilization: 0,
        userUtilization: 0,
        systemUtilization: 0,
        idleUtilization: 0,
        logicalCPUCount: 0,
        perCoreUtilization: [:]
    )

    init(
        timestamp: Date,
        result: CPUAggregateResult,
        freshness: TelemetryFreshness = .fresh,
        source: TelemetrySource = .machHost
    ) {
        self.timestamp = timestamp
        self.freshness = freshness
        self.source = source
        totalUtilization = result.totalUtilization
        userUtilization = result.userUtilization
        systemUtilization = result.systemUtilization
        idleUtilization = result.idleUtilization
        logicalCPUCount = result.logicalCPUCount
        perCoreUtilization = result.perCoreUtilization
    }

    private init(
        timestamp: Date,
        freshness: TelemetryFreshness,
        source: TelemetrySource,
        totalUtilization: Double,
        userUtilization: Double,
        systemUtilization: Double,
        idleUtilization: Double,
        logicalCPUCount: Int,
        perCoreUtilization: [Int: Double]
    ) {
        self.timestamp = timestamp
        self.freshness = freshness
        self.source = source
        self.totalUtilization = totalUtilization
        self.userUtilization = userUtilization
        self.systemUtilization = systemUtilization
        self.idleUtilization = idleUtilization
        self.logicalCPUCount = logicalCPUCount
        self.perCoreUtilization = perCoreUtilization
    }
}

typealias BatteryTelemetryAvailability = TelemetryFreshness
typealias BatteryTelemetrySource = TelemetrySource

enum BatteryOperatingState: Equatable {
    case charging
    case discharging
    case connectedNotCharging
    case fullyCharged
    case unavailable

    var label: String {
        switch self {
        case .charging: return "Charging"
        case .discharging: return "Discharging"
        case .connectedNotCharging: return "Connected to Power"
        case .fullyCharged: return "Fully Charged"
        case .unavailable: return "Battery Unavailable"
        }
    }
}

struct BatterySnapshot: Equatable {
    let timestamp: Date
    let availability: BatteryTelemetryAvailability
    let source: BatteryTelemetrySource
    let present: Bool
    let isACConnected: Bool
    let isCharging: Bool
    let isFullyCharged: Bool
    let stateOfChargePercent: Double?
    let currentCapacityMAh: Int?
    let maxCapacityMAh: Int?
    let designCapacityMAh: Int?
    let healthPercent: Double?
    let cycleCount: Int?
    let voltageMillivolts: Int?
    let currentMilliamps: Int?
    let powerWatts: Double?
    let temperatureCelsius: Double?
    let timeToEmptyMinutes: Int?
    let timeToFullMinutes: Int?
    let temperatureSource: TelemetrySource?

    static let unavailable = BatterySnapshot(
        timestamp: .now,
        availability: .unavailable,
        source: .unavailable,
        present: false,
        isACConnected: false,
        isCharging: false,
        isFullyCharged: false,
        stateOfChargePercent: nil,
        currentCapacityMAh: nil,
        maxCapacityMAh: nil,
        designCapacityMAh: nil,
        healthPercent: nil,
        cycleCount: nil,
        voltageMillivolts: nil,
        currentMilliamps: nil,
        powerWatts: nil,
        temperatureCelsius: nil,
        timeToEmptyMinutes: nil,
        timeToFullMinutes: nil,
        temperatureSource: nil
    )

    var operatingState: BatteryOperatingState {
        BatteryStateResolver.resolve(
            present: present,
            isACConnected: isACConnected,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged
        )
    }

    func withAvailability(_ availability: BatteryTelemetryAvailability) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: timestamp,
            availability: availability,
            source: source,
            present: present,
            isACConnected: isACConnected,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            stateOfChargePercent: stateOfChargePercent,
            currentCapacityMAh: currentCapacityMAh,
            maxCapacityMAh: maxCapacityMAh,
            designCapacityMAh: designCapacityMAh,
            healthPercent: healthPercent,
            cycleCount: cycleCount,
            voltageMillivolts: voltageMillivolts,
            currentMilliamps: currentMilliamps,
            powerWatts: powerWatts,
            temperatureCelsius: temperatureCelsius,
            timeToEmptyMinutes: timeToEmptyMinutes,
            timeToFullMinutes: timeToFullMinutes,
            temperatureSource: temperatureSource
        )
    }
}

enum BatteryPowerModel {
    /// AppleSmartBattery reports pack voltage in mV and current in mA.
    /// Positive current is charging into the battery; negative is discharge.
    static func watts(voltageMillivolts: Int?, currentMilliamps: Int?) -> Double? {
        guard let voltageMillivolts, voltageMillivolts > 0, let currentMilliamps else {
            return nil
        }
        return Double(voltageMillivolts) * Double(currentMilliamps) / 1_000_000
    }

    static func temperatureCelsius(rawTenthsKelvin: Int?) -> Double? {
        guard let rawTenthsKelvin, rawTenthsKelvin > 0 else { return nil }
        let celsius = Double(rawTenthsKelvin) / 10 - 273.15
        guard (0 ... 100).contains(celsius) else { return nil }
        return celsius
    }

    static func healthPercent(maxCapacityMAh: Int?, designCapacityMAh: Int?) -> Double? {
        guard let maxCapacityMAh, maxCapacityMAh > 0,
              let designCapacityMAh, designCapacityMAh > 0
        else {
            return nil
        }
        return Double(maxCapacityMAh) / Double(designCapacityMAh) * 100
    }
}

enum BatteryStateResolver {
    static func resolve(
        present: Bool,
        isACConnected: Bool,
        isCharging: Bool,
        isFullyCharged: Bool
    ) -> BatteryOperatingState {
        guard present else { return .unavailable }
        if isACConnected, isFullyCharged {
            return .fullyCharged
        }
        if isCharging {
            return .charging
        }
        if isACConnected {
            return .connectedNotCharging
        }
        return .discharging
    }
}

struct BatteryTelemetryHealth: Equatable {
    let lastSuccessfulSampleAt: Date?
    let staleAfter: TimeInterval
    let unavailableAfter: TimeInterval

    func state(at now: Date) -> BatteryTelemetryAvailability {
        TelemetryHealth(
            lastAttemptAt: nil,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            consecutiveFailures: 0,
            staleAfter: staleAfter,
            unavailableAfter: unavailableAfter
        ).freshness(at: now)
    }
}

struct MemorySnapshot: Equatable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let telemetry: MemoryTelemetry

    static let unavailable = MemorySnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .unavailable,
        telemetry: .unavailable
    )
}

struct NetworkSnapshot: Equatable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let sentBytes: UInt64?
    let receivedBytes: UInt64?
    let uploadBytesPerSecond: Double?
    let downloadBytesPerSecond: Double?

    static let unavailable = NetworkSnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .unavailable,
        sentBytes: nil,
        receivedBytes: nil,
        uploadBytesPerSecond: nil,
        downloadBytesPerSecond: nil
    )
}

struct StorageSnapshot: Equatable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let freeBytes: UInt64?
    let totalBytes: UInt64?

    static let unavailable = StorageSnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .unavailable,
        freeBytes: nil,
        totalBytes: nil
    )
}

struct SystemThermalSnapshot: Equatable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let thermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool
    let cpuTemperatureCelsius: Double?
    let batteryTemperatureCelsius: Double?

    static let unavailable = SystemThermalSnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .processInfo,
        thermalState: .nominal,
        lowPowerMode: false,
        cpuTemperatureCelsius: nil,
        batteryTemperatureCelsius: nil
    )
}

struct SystemTelemetrySnapshot: Equatable {
    let timestamp: Date
    let cpu: CPUSnapshot
    let memory: MemorySnapshot
    let network: NetworkSnapshot
    let storage: StorageSnapshot
    let thermal: SystemThermalSnapshot

    static let unavailable = SystemTelemetrySnapshot(
        timestamp: .now,
        cpu: .empty,
        memory: .unavailable,
        network: .unavailable,
        storage: .unavailable,
        thermal: .unavailable
    )
}

struct CoolingTelemetryHealth: Equatable {
    let lastSuccessfulSampleAt: Date?
    let staleAfter: TimeInterval
    let unavailableAfter: TimeInterval

    func state(at now: Date) -> CoolingTelemetryState {
        switch TelemetryHealth(
            lastAttemptAt: nil,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            consecutiveFailures: 0,
            staleAfter: staleAfter,
            unavailableAfter: unavailableAfter
        ).freshness(at: now) {
        case .fresh: return .available
        case .stale: return .stale
        case .unavailable: return .unavailable
        }
    }
} // swiftlint:disable:this file_length
