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

enum CoolingSensorStatus: String, Equatable, Sendable {
    case notObserved
    case observed
    case permissionDenied
    case unsupportedByDistribution
    case unsupportedHardware
    case temporarilyUnavailable

    var label: String {
        switch self {
        case .notObserved: return "Not observed"
        case .observed: return "Observed"
        case .permissionDenied: return "Access unavailable"
        case .unsupportedByDistribution: return "Not available in App Store build"
        case .unsupportedHardware: return "Not supported by this Mac"
        case .temporarilyUnavailable: return "Temporarily unavailable"
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
    let thermalStateSource: TelemetrySource
    let thermalStateLastUpdatedAt: Date?
    let thermalStateFreshness: TelemetryFreshness
    let sensorStatus: CoolingSensorStatus

    init(
        timestamp: Date,
        freshness: TelemetryFreshness,
        source: TelemetrySource,
        nativeThermalState: ProcessInfo.ThermalState,
        fanCount: Int?,
        fans: [CoolingFan],
        temperatures: [CoolingTemperature],
        lastSuccessfulSampleAt: Date?,
        consecutiveFailures: Int,
        macOSPolicyOwner: Bool,
        thermalStateSource: TelemetrySource = .processInfo,
        thermalStateLastUpdatedAt: Date? = nil,
        thermalStateFreshness: TelemetryFreshness = .unavailable,
        sensorStatus: CoolingSensorStatus = .notObserved
    ) {
        self.timestamp = timestamp
        self.freshness = freshness
        self.source = source
        self.nativeThermalState = nativeThermalState
        self.fanCount = fanCount
        self.fans = fans
        self.temperatures = temperatures
        self.lastSuccessfulSampleAt = lastSuccessfulSampleAt
        self.consecutiveFailures = consecutiveFailures
        self.macOSPolicyOwner = macOSPolicyOwner
        self.thermalStateSource = thermalStateSource
        self.thermalStateLastUpdatedAt = thermalStateLastUpdatedAt
        self.thermalStateFreshness = thermalStateFreshness
        self.sensorStatus = sensorStatus
    }

    var state: CoolingTelemetryState {
        guard thermalStateFreshness != .unavailable else { return .unavailable }
        guard freshness != .stale else { return .stale }
        guard sensorStatus == .observed, freshness != .unavailable else { return .partial }
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
        macOSPolicyOwner: true,
        thermalStateSource: .processInfo,
        thermalStateLastUpdatedAt: nil,
        thermalStateFreshness: .unavailable,
        sensorStatus: .notObserved
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
            macOSPolicyOwner: true,
            thermalStateSource: .processInfo,
            thermalStateLastUpdatedAt: timestamp,
            thermalStateFreshness: .fresh,
            sensorStatus: .observed
        )
    }
}
