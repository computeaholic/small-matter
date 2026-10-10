import Foundation

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
}
