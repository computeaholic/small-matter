// swiftlint:disable line_length
import Foundation
import Network

final class NetworkEvidenceAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID = .network

    private let clock: any EvidenceClock
    private let emit: @Sendable (EvidenceAdapterEmission) -> Void
    private let lock = NSLock()
    private var running = false
    private var monitor: NWPathMonitor?
    private var previousPath: NetworkRawPath?

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
        let createdMonitor = NWPathMonitor()
        monitor = createdMonitor
        lock.unlock()

        createdMonitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        createdMonitor.start(queue: DispatchQueue(label: "com.tunix.horizon2.network", qos: .utility))
        emit(.health(health(event: .started, reason: .notObserved, detail: "NWPathMonitor started")))
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let oldMonitor = monitor
        monitor = nil
        previousPath = nil
        lock.unlock()

        oldMonitor?.cancel()
        emit(.health(health(event: .stopped, reason: .notObserved, detail: "NWPathMonitor cancelled")))
    }

    func reconcileAfterWake() {
        lock.lock()
        previousPath = nil
        lock.unlock()
        // NWPathMonitor will provide the current path. The first post-wake path
        // establishes a baseline and cannot invent a transition.
    }

    private func handle(_ path: NWPath) {
        guard isRunning else { return }
        let current = Self.rawPath(from: path)
        lock.lock()
        let previous = previousPath
        previousPath = current
        lock.unlock()

        guard let previous else { return }
        let raw = NetworkRawTransition(previous: previous, current: current, occurrence: occurrence())
        guard NetworkPathNormalizer.normalize(raw) != nil else {
            emit(.health(health(event: .duplicateSuppressed, reason: .notObserved, suppressedCount: 1, detail: "Equivalent NWPath callback")))
            return
        }
        emit(.raw(.network(raw)))
    }

    private static func rawPath(from path: NWPath) -> NetworkRawPath {
        let status: NetworkPathStatus
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unsatisfied
        }
        let interfaces = Set(path.availableInterfaces.map { interface -> NetworkInterfaceFact in
            switch interface.type {
            case .wifi: return .wifi
            case .wiredEthernet: return .wiredEthernet
            case .cellular: return .cellular
            case .loopback: return .loopback
            case .other: return .other
            @unknown default: return .other
            }
        })
        return NetworkRawPath(status: status, interfaces: interfaces)
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
        EvidenceSourceHealthUpdate(sourceID: .network, event: event, reason: reason, suppressedCount: suppressedCount, observedAt: clock.reading().wallTime, detail: detail)
    }

    deinit {
        stop()
    }
}

// swiftlint:enable line_length
