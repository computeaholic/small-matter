import Foundation
import SwiftUI

@MainActor
final class CoolingService: ObservableObject {
    @Published private(set) var snapshot = CoolingSnapshot.unavailable

    private let source: any CoolingTelemetrySource
    private var refreshTimer: Timer?
    private let staleAfter: TimeInterval = 8
    private let unavailableAfter: TimeInterval = 30

    init(
        source: any CoolingTelemetrySource = AppleSMCReadOnlyReader(),
        automaticallyStart: Bool = true
    ) {
        self.source = source
        if automaticallyStart {
            start()
        }
    }

    deinit {
        refreshTimer?.invalidate()
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
        let source = self.source
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = source.collect()
            Task { @MainActor in
                self?.apply(result, attemptedAt: attempt)
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
                macOSPolicyOwner: true
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
            )
        case .failure:
            let failures = snapshot.consecutiveFailures + 1
            snapshot = snapshot.with(consecutiveFailures: failures)
            updateFreshness(now: attemptedAt)
        }
    }
}

private extension CoolingSnapshot {
    func with(
        freshness: TelemetryFreshness? = nil,
        consecutiveFailures: Int? = nil
    ) -> CoolingSnapshot {
        CoolingSnapshot(
            timestamp: timestamp,
            freshness: freshness ?? self.freshness,
            source: source,
            nativeThermalState: nativeThermalState,
            fanCount: fanCount,
            fans: fans,
            temperatures: temperatures,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            consecutiveFailures: consecutiveFailures ?? self.consecutiveFailures,
            macOSPolicyOwner: macOSPolicyOwner
        )
    }
}
