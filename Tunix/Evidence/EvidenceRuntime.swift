import Combine
import Foundation

// swiftlint:disable trailing_comma

final class EvidenceRuntime: ObservableObject, @unchecked Sendable {
    typealias AdapterFactory = @Sendable (
        @escaping @Sendable (EvidenceAdapterEmission) -> Void
    ) -> [any Horizon2EvidenceAdapter]

    let processRunID: UUID
    let journal: any EvidenceJournal
    let nativeCollectionEnabled: Bool

    private let clock: any EvidenceClock
    private let adapterFactory: AdapterFactory?
    private let ingressCapacity: Int
    private let lock = NSLock()
    private var adapters: [any Horizon2EvidenceAdapter] = []
    private var running = false
    private var generation: UInt64 = 0
    private lazy var ingestion: EvidenceIngestionAuthority = .init(
        capacity: ingressCapacity,
        clock: clock,
        journal: journal,
        processRunID: processRunID,
        onWake: { [weak self] in self?.reconcileAfterWake() }
    )

    init(
        clock: any EvidenceClock = SystemEvidenceClock(),
        journal: any EvidenceJournal = InMemoryEvidenceJournal(),
        processRunID: UUID = UUID(),
        adapterFactory: AdapterFactory? = nil,
        enabled: Bool = true,
        ingressCapacity: Int = Horizon2EvidenceConfiguration.collectorQueueCapacity
    ) {
        self.clock = clock
        self.journal = journal
        self.processRunID = processRunID
        self.ingressCapacity = max(1, ingressCapacity)
        nativeCollectionEnabled = enabled
        let disabledFactory: AdapterFactory = { _ in [] }
        self.adapterFactory = enabled ? adapterFactory : disabledFactory
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var currentGenerationForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        generation += 1
        let currentGeneration = generation
        let callback: @Sendable (EvidenceAdapterEmission) -> Void = { [weak self] emission in
            self?.receive(emission, generation: currentGeneration)
        }
        let factory = adapterFactory ?? Self.defaultAdapterFactory(clock: clock)
        let newAdapters = factory(callback)
        adapters = newAdapters
        lock.unlock()

        ingestion.start(generation: currentGeneration)
        newAdapters.forEach { $0.start() }
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        generation += 1
        let oldAdapters = adapters
        adapters.removeAll()
        lock.unlock()

        ingestion.stop()
        oldAdapters.forEach { $0.stop() }
    }

    /// Drives the same bounded serialized raw-event path used by native
    /// callbacks. This is retained as the deterministic adapter test seam.
    @discardableResult
    func ingest(_ raw: Horizon2RawEvent) async -> Observation? {
        guard let currentGeneration = activeGeneration() else { return nil }
        return await ingestion.submit(raw, generation: currentGeneration)
    }

    /// Native callbacks use a generation-bound closure created during start.
    /// The optional generation keeps the manual test seam convenient while
    /// preserving stale-callback rejection for real adapters.
    func receive(_ emission: EvidenceAdapterEmission, generation: UInt64? = nil) {
        guard let acceptedGeneration = generation ?? activeGeneration() else { return }
        ingestion.enqueue(emission, generation: acceptedGeneration)
    }

    func drainForTesting() async {
        await ingestion.drainForTesting()
    }

    func currentCorrelationEpochIDForTesting() async -> UUID {
        await ingestion.currentEpoch()
    }

    var ingressOverflowCountForTesting: Int {
        ingestion.overflowCountForTesting
    }

    var ingressTotalOverflowCountForTesting: Int {
        ingestion.totalOverflowCountForTesting
    }

    var ingressQueuedPayloadBytesForTesting: Int {
        ingestion.queuedPayloadBytesForTesting
    }

    var ingressPeakQueuedPayloadBytesForTesting: Int {
        ingestion.peakQueuedPayloadBytesForTesting
    }

    func runtimeSequenceCountForTesting() async -> Int {
        await ingestion.sequenceCountForTesting()
    }

    #if HORIZON2_MEASUREMENT
        func measurementSnapshot() -> Horizon2MeasurementSnapshot {
            ingestion.measurementSnapshot()
        }
    #endif

    private func activeGeneration() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return running ? generation : nil
    }

    private func reconcileAfterWake() {
        lock.lock()
        let currentAdapters = adapters
        let stillRunning = running
        lock.unlock()
        guard stillRunning else { return }
        currentAdapters.forEach { $0.reconcileAfterWake() }
    }

    private static func defaultAdapterFactory(clock: any EvidenceClock) -> AdapterFactory {
        { emit in
            [
                StorageEvidenceAdapter(clock: clock, emit: emit),
                PowerEvidenceAdapter(clock: clock, emit: emit),
                NetworkEvidenceAdapter(clock: clock, emit: emit),
                SleepWakeBoundaryAdapter(clock: clock, emit: emit),
            ]
        }
    }

    deinit {
        stop()
    }
}

// swiftlint:enable trailing_comma
