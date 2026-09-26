import Foundation

struct CoolingFan: Equatable, Sendable {
    let fanIndex: Int
    let currentRPM: Int
    let minimumRPM: Int?
    let maximumRPM: Int?
}

struct CoolingTemperature: Equatable, Sendable {
    let name: String
    let valueCelsius: Double
    let sourceKey: String
}

enum CoolingTelemetryState: String, Equatable, Sendable {
    case available
    case partial
    case stale
    case unavailable

    var label: String {
        switch self {
        case .available: return "Available"
        case .partial: return "Partial"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        }
    }
}

struct CoolingSnapshot: Equatable, Sendable {
    let timestamp: Date
    let freshness: TelemetryFreshness
    let source: TelemetrySource
    let nativeThermalState: ProcessInfo.ThermalState
    let fanCount: Int?
    let fans: [CoolingFan]
    let temperatures: [CoolingTemperature]
    let lastSuccessfulSampleAt: Date?
    let consecutiveFailures: Int
    let macOSPolicyOwner: Bool

    var state: CoolingTelemetryState {
        guard freshness != .unavailable else { return .unavailable }
        guard freshness != .stale else { return .stale }
        let hasCompleteFanTelemetry = fanCount.map { $0 > 0 && fans.count == $0 } == true &&
            fans.allSatisfy { $0.minimumRPM != nil && $0.maximumRPM != nil }
        return hasCompleteFanTelemetry && !temperatures.isEmpty ? .available : .partial
    }

    var primaryTemperature: CoolingTemperature? {
        temperatures.first(where: { $0.name == "CPU" }) ?? temperatures.first
    }

    static let unavailable = CoolingSnapshot(
        timestamp: .now,
        freshness: .unavailable,
        source: .unavailable,
        nativeThermalState: .nominal,
        fanCount: nil,
        fans: [],
        temperatures: [],
        lastSuccessfulSampleAt: nil,
        consecutiveFailures: 0,
        macOSPolicyOwner: true
    )
}

extension CoolingSnapshot {
    init(
        raw: CoolingRawObservation,
        timestamp: Date,
        lastSuccessfulSampleAt: Date,
        consecutiveFailures: Int = 0
    ) {
        self.init(
            timestamp: timestamp,
            freshness: .fresh,
            source: .appleSMC,
            nativeThermalState: raw.thermalState,
            fanCount: raw.fanCount,
            fans: raw.fans,
            temperatures: raw.temperatures,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            consecutiveFailures: consecutiveFailures,
            macOSPolicyOwner: true
        )
    }
}
