import AppKit
import Foundation

// swiftlint:disable trailing_comma

final class SleepWakeBoundaryAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID = .sleepWake

    private let clock: any EvidenceClock
    private let emit: @Sendable (EvidenceAdapterEmission) -> Void
    private let lock = NSLock()
    private var running = false
    private var notificationTokens: [NSObjectProtocol] = []

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
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handle(.willSleep)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handle(.didWake)
            },
        ]
        lock.unlock()
        emit(.health(health(event: .started, detail: "Sleep/wake control boundary registered")))
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let tokens = notificationTokens
        notificationTokens.removeAll()
        lock.unlock()
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        emit(.health(health(event: .stopped, detail: "Sleep/wake control boundary removed")))
    }

    func reconcileAfterWake() {}

    private func handle(_ event: SleepWakeEventKind) {
        guard isRunning else { return }
        // This is deliberately not an Observation. It is a control message to
        // EvidenceRuntime, which advances the epoch and reconciles sources.
        emit(.raw(.lifecycle(SleepWakeRawEvent(
            kind: event,
            observedAt: clock.reading()
        ))))
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func health(event: EvidenceSourceHealthEvent, detail: String) -> EvidenceSourceHealthUpdate {
        EvidenceSourceHealthUpdate(
            sourceID: .sleepWake,
            event: event,
            reason: .notObserved,
            suppressedCount: 0,
            observedAt: clock.reading().wallTime,
            detail: detail
        )
    }

    deinit {
        stop()
    }
}

// swiftlint:enable trailing_comma
