import Foundation
import SwiftUI

@MainActor
final class CoolingService: ObservableObject {
    @Published private(set) var snapshot = CoolingSnapshot.unavailable

    private let source: any CoolingTelemetrySource
    private let thermalStateReader: @Sendable () -> ProcessInfo.ThermalState
    private var refreshTimer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var refreshGeneration = 0
    private let staleAfter: TimeInterval = 8
    private let unavailableAfter: TimeInterval = 30

    init(
        source: any CoolingTelemetrySource = AppleSMCReadOnlyReader(),
        thermalStateReader: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        automaticallyStart: Bool = true
    ) {
        self.source = source
        self.thermalStateReader = thermalStateReader
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshThermalState() }
        }
        if automaticallyStart {
            start()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    var telemetryState: CoolingTelemetryState {
        snapshot.state
    }

    var lastSuccessfulSampleAt: Date? {
        snapshot.lastSuccessfulSampleAt
    }

    var lastAttemptAt: Date?

    var consecutiveFailures: Int {
        snapshot.consecutiveFailures
    }

    var sensorStatus: CoolingSensorStatus {
        snapshot.sensorStatus
    }

    var sensorAvailabilityDescription: String {
        switch snapshot.sensorStatus {
        case .notObserved:
            return "Raw fan and temperature sensors have not been observed yet."
        case .observed:
            return "Raw readings are reported by the available hardware sensor source."
        case .permissionDenied:
            return "macOS did not permit this app to open the hardware sensor service. "
                + "The thermal state above remains available."
        case .unsupportedByDistribution:
            return "Raw AppleSMC fan and temperature sensors are not included in the Mac App Store build. "
                + "The thermal state above remains available."
        case .unsupportedHardware:
            return "This Mac did not expose supported fan or temperature keys. "
                + "The thermal state above remains available."
        case .temporarilyUnavailable:
            return "The hardware sensor source did not return a valid sample. "
                + "The thermal state above remains available."
        }
    }

    var thermalStateLabel: String {
        guard snapshot.thermalStateFreshness != .unavailable else { return "Unavailable" }
        switch snapshot.nativeThermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var thermalConditionLabel: String {
        switch thermalStateLabel {
        case "Nominal": return "Normal"
        case "Fair": return "Warm"
        case "Serious": return "Elevated"
        case "Critical": return "Critical"
        default: return "Unavailable"
        }
    }

    var thermalStateDetail: String {
        "Apple thermal state: \(thermalStateLabel)"
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let attempt = Date()
        lastAttemptAt = attempt
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshThermalState(at: attempt)
        let source = self.source
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = source.collect()
            Task { @MainActor in
                guard let self, generation == self.refreshGeneration else { return }
                self.apply(result, attemptedAt: attempt)
            }
        }
    }

    func updateFreshness(now: Date = .now) {
        guard let lastGood = snapshot.lastSuccessfulSampleAt else {
            snapshot = CoolingSnapshot(
                timestamp: snapshot.timestamp,
                freshness: .unavailable,
                source: snapshot.source,
                nativeThermalState: snapshot.nativeThermalState,
                fanCount: snapshot.fanCount,
                fans: snapshot.fans,
                temperatures: snapshot.temperatures,
                lastSuccessfulSampleAt: nil,
                consecutiveFailures: snapshot.consecutiveFailures,
                macOSPolicyOwner: true,
                thermalStateSource: snapshot.thermalStateSource,
                thermalStateLastUpdatedAt: snapshot.thermalStateLastUpdatedAt,
                thermalStateFreshness: snapshot.thermalStateFreshness,
                sensorStatus: snapshot.sensorStatus
            )
            return
        }

        let freshness = TelemetryHealth(
            lastAttemptAt: lastAttemptAt,
            lastSuccessfulSampleAt: lastGood,
            consecutiveFailures: snapshot.consecutiveFailures,
            staleAfter: staleAfter,
            unavailableAfter: unavailableAfter
        ).freshness(at: now)
        guard freshness != snapshot.freshness else { return }
        snapshot = snapshot.with(freshness: freshness)
    }

    private func apply(
        _ result: Result<CoolingRawObservation, CoolingCollectionError>,
        attemptedAt: Date
    ) {
        switch result {
        case let .success(raw):
            snapshot = CoolingSnapshot(
                raw: raw,
                timestamp: attemptedAt,
                lastSuccessfulSampleAt: attemptedAt
            ).with(
                thermalState: snapshot.nativeThermalState,
                thermalStateLastUpdatedAt: snapshot.thermalStateLastUpdatedAt,
                thermalStateFreshness: snapshot.thermalStateFreshness
            )
        case let .failure(error):
            let failures = snapshot.consecutiveFailures + 1
            snapshot = snapshot.with(
                consecutiveFailures: failures,
                sensorStatus: Self.sensorStatus(for: error)
            )
            updateFreshness(now: attemptedAt)
        }
    }

    private func refreshThermalState(at timestamp: Date = .now) {
        snapshot = snapshot.with(
            thermalState: thermalStateReader(),
            thermalStateLastUpdatedAt: timestamp,
            thermalStateFreshness: .fresh
        )
    }

    private static func sensorStatus(for error: CoolingCollectionError) -> CoolingSensorStatus {
        switch error {
        case .connectionUnavailable:
            return .permissionDenied
        case .unsupportedByDistribution:
            return .unsupportedByDistribution
        case .serviceUnavailable, .noSupportedKeys:
            return .unsupportedHardware
        case .keyUnreadable:
            return .temporarilyUnavailable
        }
    }
}

private extension CoolingSnapshot {
    func with(
        freshness: TelemetryFreshness? = nil,
        consecutiveFailures: Int? = nil,
        sensorStatus: CoolingSensorStatus? = nil,
        thermalState: ProcessInfo.ThermalState? = nil,
        thermalStateLastUpdatedAt: Date? = nil,
        thermalStateFreshness: TelemetryFreshness? = nil
    ) -> CoolingSnapshot {
        CoolingSnapshot(
            timestamp: timestamp,
            freshness: freshness ?? self.freshness,
            source: source,
            nativeThermalState: thermalState ?? nativeThermalState,
            fanCount: fanCount,
            fans: fans,
            temperatures: temperatures,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            consecutiveFailures: consecutiveFailures ?? self.consecutiveFailures,
            macOSPolicyOwner: macOSPolicyOwner,
            thermalStateSource: thermalStateSource,
            thermalStateLastUpdatedAt: thermalStateLastUpdatedAt ?? self.thermalStateLastUpdatedAt,
            thermalStateFreshness: thermalStateFreshness ?? self.thermalStateFreshness,
            sensorStatus: sensorStatus ?? self.sensorStatus
        )
    }
}
