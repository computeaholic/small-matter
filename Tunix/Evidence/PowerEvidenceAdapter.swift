// swiftlint:disable line_length
import Foundation
import IOKit
import IOKit.ps

final class PowerEvidenceAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID = .power

    private let clock: any EvidenceClock
    private let emit: @Sendable (EvidenceAdapterEmission) -> Void
    private let lock = NSLock()
    private var running = false
    private var notificationSource: CFRunLoopSource?
    private var previousState: PowerRawState?

    init(
        clock: any EvidenceClock = SystemEvidenceClock(),
        emit: @escaping @Sendable (EvidenceAdapterEmission) -> Void
    ) {
        self.clock = clock
        self.emit = emit
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        guard let source = IOPSNotificationCreateRunLoopSource(Self.powerChanged, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            running = false
            lock.unlock()
            emit(.health(health(event: .startupFailure, reason: .permissionOrAPIUnavailable, detail: "IOPSNotificationCreateRunLoopSource failed")))
            return
        }
        notificationSource = source
        previousState = readCurrentState()
        lock.unlock()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        emit(.health(health(event: .started, reason: .notObserved, detail: "IOPowerSources notification registered")))
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let source = notificationSource
        notificationSource = nil
        previousState = nil
        lock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        emit(.health(health(event: .stopped, reason: .notObserved, detail: "IOPowerSources notification removed")))
    }

    func reconcileAfterWake() {
        guard isRunning else { return }
        guard let state = readCurrentState() else {
            emit(.health(health(event: .reconciliationFailure, reason: .sourceUnavailable, detail: "IOPowerSources read unavailable after wake")))
            return
        }
        lock.lock()
        previousState = state
        lock.unlock()
    }

    private func handlePowerChanged() {
        guard isRunning, let current = readCurrentState() else {
            if isRunning {
                emit(.health(health(event: .sourceUnavailable, reason: .sourceUnavailable, detail: "IOPowerSources callback read unavailable")))
            }
            return
        }
        lock.lock()
        let previous = previousState
        previousState = current
        lock.unlock()

        guard let previous else { return }
        let raw = PowerRawTransition(previous: previous, current: current, occurrence: occurrence())
        guard PowerTransitionNormalizer.normalize(raw) != nil else {
            emit(.health(health(event: .duplicateSuppressed, reason: .notObserved, suppressedCount: 1, detail: "Unchanged or coalesced power callback")))
            return
        }
        emit(.raw(.power(raw)))
    }

    private func readCurrentState() -> PowerRawState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sourceType = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return nil }
        let sourceString = sourceType as String
        let source: PowerSourceKind
        if sourceString == kIOPMACPowerKey {
            source = .ac
        } else if sourceString == kIOPMBatteryPowerKey {
            source = .battery
        } else {
            source = .unknown
        }

        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        let descriptions: [[String: Any]] = (list ?? []).compactMap { item in
            guard let description = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() else { return nil }
            return description as? [String: Any]
        }
        let description = descriptions.first
        let charging = description?[kIOPSIsChargingKey] as? Bool
        let currentCapacity = (description?[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue
        let maximumCapacity = (description?[kIOPSMaxCapacityKey] as? NSNumber)?.intValue
        return PowerRawState(
            externalPowerConnected: source == .ac,
            source: source,
            charging: charging,
            currentCapacity: currentCapacity,
            maximumCapacity: maximumCapacity
        )
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func occurrence() -> EvidenceSourceOccurrence {
        let reading = clock.reading()
        return EvidenceSourceOccurrence(
            wallTime: reading.wallTime,
            continuousNanoseconds: reading.continuousNanoseconds,
            quality: reading.continuousNanoseconds == nil ? .estimated : .exact
        )
    }

    private func health(
        event: EvidenceSourceHealthEvent,
        reason: EvidenceUnknownReason,
        suppressedCount: Int = 0,
        detail: String?
    ) -> EvidenceSourceHealthUpdate {
        EvidenceSourceHealthUpdate(sourceID: .power, event: event, reason: reason, suppressedCount: suppressedCount, observedAt: clock.reading().wallTime, detail: detail)
    }

    private static let powerChanged: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        Unmanaged<PowerEvidenceAdapter>.fromOpaque(context).takeUnretainedValue().handlePowerChanged()
    }

    deinit {
        stop()
    }
}

// swiftlint:enable line_length
