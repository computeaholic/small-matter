import Foundation

final class EvidenceIngestionAuthority: @unchecked Sendable {
    private let stateLock = NSLock()
    private let processor: EvidenceIngestionProcessor
    private let clock: any EvidenceClock
    private let buffer: EvidenceIngressBuffer
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?

    init(
        capacity: Int = Horizon2EvidenceConfiguration.collectorQueueCapacity,
        clock: any EvidenceClock,
        journal: any EvidenceJournal,
        processRunID: UUID,
        onWake: @escaping @Sendable () -> Void
    ) {
        self.clock = clock
        let residenceNanoseconds = Self.residenceLimitNanoseconds()
        let coalescingEnabled = Self.cooperativeBatchCoalescingEnabled()
        #if HORIZON2_MEASUREMENT
            let measurementMetrics = Horizon2MeasurementMetrics()
            buffer = EvidenceIngressBuffer(
                capacity: capacity,
                residenceMaximumNanoseconds: residenceNanoseconds,
                cooperativeBatchCoalescingEnabled: coalescingEnabled,
                measurementMetrics: measurementMetrics
            )
            processor = EvidenceIngestionProcessor(
                clock: clock,
                journal: journal,
                processRunID: processRunID,
                onWake: onWake,
                measurementMetrics: measurementMetrics
            )
        #else
            buffer = EvidenceIngressBuffer(
                capacity: capacity,
                residenceMaximumNanoseconds: residenceNanoseconds,
                cooperativeBatchCoalescingEnabled: coalescingEnabled
            )
            processor = EvidenceIngestionProcessor(
                clock: clock,
                journal: journal,
                processRunID: processRunID,
                onWake: onWake
            )
        #endif
    }

    func start(generation: UInt64) {
        stop()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateLock.lock()
            wakeContinuation = continuation
            stateLock.unlock()
        }
        buffer.begin(generation: generation)
        worker = Task { [weak self, processor] in
            let activated = await processor.activate(generation: generation) { [weak self] in
                self?.isCurrent(generation) ?? false
            }
            guard activated else { return }
            for await _ in stream {
                guard let self else { break }
                buffer.consumeWakeSignal()
                await self.consumeAvailableWork(using: processor)
            }
            guard let self else { return }
            await self.consumeAvailableWork(using: processor)
            await self.flushOverflowCounts(to: processor)
        }
    }

    func enqueue(_ emission: EvidenceAdapterEmission, generation: UInt64) {
        enqueue(EvidenceIngressItem(
            emission: emission,
            generation: generation,
            capturedAt: clock.reading(),
            completion: nil,
            enqueuedAtContinuousNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
    }

    func submit(_ raw: Horizon2RawEvent, generation: UInt64) async -> Observation? {
        await withCheckedContinuation { continuation in
            let completion = ObservationCompletion(continuation)
            enqueue(EvidenceIngressItem(
                emission: .raw(raw),
                generation: generation,
                capturedAt: clock.reading(),
                completion: { completion.resume($0) },
                enqueuedAtContinuousNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }
    }

    func stop() {
        stateLock.lock()
        let oldContinuation = wakeContinuation
        wakeContinuation = nil
        worker = nil
        stateLock.unlock()
        let pending = buffer.stop()
        oldContinuation?.finish()
        for item in pending {
            item.completion?(nil)
        }
    }

    func drainForTesting() async {
        while !buffer.isIdle() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func currentEpoch() async -> UUID {
        await processor.currentEpoch()
    }

    func sequenceCountForTesting() async -> Int {
        await processor.sequenceCountForTesting()
    }

    var overflowCountForTesting: Int {
        buffer.overflowCountForTesting()
    }

    var queuedPayloadBytesForTesting: Int {
        buffer.queuedPayloadBytesForTesting()
    }

    var totalOverflowCountForTesting: Int {
        buffer.totalOverflowCountForTesting()
    }

    var peakQueuedPayloadBytesForTesting: Int {
        buffer.peakQueuedPayloadBytesForTesting()
    }

    private func enqueue(_ item: EvidenceIngressItem) {
        let admission = buffer.admit(item)
        finishDropped(admission.dropped)
        if admission.shouldSignalWorker {
            signalWorker()
        }
        if !admission.accepted {
            item.completion?(nil)
        }
    }

    private func signalWorker() {
        stateLock.lock()
        wakeContinuation?.yield(())
        stateLock.unlock()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        buffer.isCurrent(generation)
    }

    private func consumeAvailableWork(using processor: EvidenceIngestionProcessor) async {
        var yieldedBeforeFirstBatch = false
        while true {
            if !yieldedBeforeFirstBatch, buffer.shouldYieldBeforePartialBatch() {
                yieldedBeforeFirstBatch = true
                await Task.yield()
            }
            let dequeue = buffer.takeBatch()
            finishDropped(dequeue.expired)
            guard let batch = dequeue.batch else {
                await flushOverflowCounts(to: processor)
                return
            }
            await flushOverflowCounts(to: processor)
            await persist(batch, using: processor)
            if buffer.shouldYieldAfterPartialBatch() {
                await Task.yield()
            }
        }
    }

    private func persist(_ batch: EvidenceIngressBatch, using processor: EvidenceIngestionProcessor) async {
        #if HORIZON2_MEASUREMENT
            let startNanoseconds = DispatchTime.now().uptimeNanoseconds
        #endif
        let observations = await processor.process(batch.items)
        #if HORIZON2_MEASUREMENT
            let endNanoseconds = DispatchTime.now().uptimeNanoseconds
            buffer.recordCompletedBatch(
                batch: batch,
                startNanoseconds: startNanoseconds,
                endNanoseconds: endNanoseconds,
                observations: observations
            )
        #endif
        for (item, observation) in zip(batch.items, observations) {
            item.completion?(observation)
        }
    }

    private func finishDropped(_ dropped: [Horizon2DroppedIngress]) {
        for entry in dropped {
            entry.item.completion?(nil)
        }
    }

    private func flushOverflowCounts(to processor: EvidenceIngestionProcessor) async {
        let dropped = buffer.takeOverflowCounts()
        for (key, count) in dropped {
            await processor.recordOverflow(
                sourceID: key.sourceID,
                count: count,
                reason: key.reason,
                observedAt: clock.reading().wallTime
            )
        }
    }

    #if HORIZON2_MEASUREMENT
        func measurementSnapshot() -> Horizon2MeasurementSnapshot {
            buffer.measurementSnapshot()
        }
    #endif

    private static func residenceLimitNanoseconds() -> UInt64 {
        #if HORIZON2_MEASUREMENT
            let prefix = "-Horizon2MeasurementResidenceLimitMilliseconds="
            let overrideMilliseconds = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix(prefix) })
                .flatMap { Int($0.dropFirst(prefix.count)) }
            let milliseconds = max(
                1,
                overrideMilliseconds ?? Horizon2EvidenceConfiguration.collectorQueueResidenceLimitMilliseconds
            )
        #else
            let milliseconds = Horizon2EvidenceConfiguration.collectorQueueResidenceLimitMilliseconds
        #endif
        return UInt64(milliseconds) * 1_000_000
    }

    private static func cooperativeBatchCoalescingEnabled() -> Bool {
        #if HORIZON2_MEASUREMENT
            return !ProcessInfo.processInfo.arguments.contains("-Horizon2MeasurementDisableBatchCoalescing")
        #else
            return true
        #endif
    }
}

enum Horizon2OverflowDiagnostic {
    static func detail(for reason: Horizon2IngressOverflowReason) -> String {
        "Bounded Horizon 2 ingress overflow (\(reason.rawValue)); evidence is incomplete"
    }
}
