import Foundation

struct EvidenceIngressItem: Sendable {
    let emission: EvidenceAdapterEmission
    let generation: UInt64
    let capturedAt: EvidenceClockReading
    let completion: (@Sendable (Observation?) -> Void)?
    let enqueuedAtContinuousNanoseconds: UInt64
}

enum Horizon2IngressOverflowReason: String, Codable, Hashable, Sendable {
    case countLimit = "count_limit"
    case payloadLimit = "payload_limit"
    case residenceLimit = "residence_limit"
}

private struct Horizon2OverflowKey: Hashable, Sendable {
    let sourceID: Horizon2SourceID
    let reason: Horizon2IngressOverflowReason
}

private struct Horizon2DroppedIngress: Sendable {
    let item: EvidenceIngressItem
    let reason: Horizon2IngressOverflowReason
}

private final class ObservationCompletion: @unchecked Sendable {
    private let continuation: CheckedContinuation<Observation?, Never>

    init(_ continuation: CheckedContinuation<Observation?, Never>) {
        self.continuation = continuation
    }

    func resume(_ observation: Observation?) {
        continuation.resume(returning: observation)
    }
}

private actor EvidenceIngestionProcessor {
    private let clock: any EvidenceClock
    private let journal: any EvidenceJournal
    private let processRunID: UUID
    private let onWake: @Sendable () -> Void
    private let measurementMetrics: Any?

    private var activeGeneration: UInt64?
    private var correlationEpochID = UUID()
    private var isSleeping = false
    private var nextIngressOrder: UInt64 = 0
    private var sequenceBySource: [Horizon2SourceID: UInt64] = [:]

    init(
        clock: any EvidenceClock,
        journal: any EvidenceJournal,
        processRunID: UUID,
        onWake: @escaping @Sendable () -> Void,
        measurementMetrics: Any? = nil
    ) {
        self.clock = clock
        self.journal = journal
        self.processRunID = processRunID
        self.onWake = onWake
        self.measurementMetrics = measurementMetrics
    }

    func activate(generation: UInt64, isCurrent: @Sendable () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        activeGeneration = generation
        correlationEpochID = UUID()
        isSleeping = false
        nextIngressOrder = 0
        sequenceBySource.removeAll(keepingCapacity: true)
        return true
    }

    func currentEpoch() -> UUID {
        correlationEpochID
    }

    func sequenceCountForTesting() -> Int {
        sequenceBySource.count
    }

    func process(_ item: EvidenceIngressItem) async -> Observation? {
        guard activeGeneration == item.generation else { return nil }
        switch item.emission {
        case let .raw(raw):
            return await process(raw, capturedAt: item.capturedAt)
        case let .health(update):
            await recordHealth(update)
            return nil
        }
    }

    func process(_ items: [EvidenceIngressItem]) async -> [Observation?] {
        var results = [Observation?](repeating: nil, count: items.count)
        var pending: [(index: Int, observation: Observation, fact: NormalizedEvidenceFact)] = []
        for (index, item) in items.enumerated() {
            guard activeGeneration == item.generation else { continue }
            switch item.emission {
            case let .health(update):
                await recordHealth(update)
            case let .raw(raw):
                nextIngressOrder += 1
                switch raw {
                case let .lifecycle(event):
                    let boundEvent = SleepWakeRawEvent(
                        kind: event.kind,
                        observedAt: event.observedAt ?? item.capturedAt,
                        ingressOrder: nextIngressOrder
                    )
                    handleLifecycle(boundEvent)
                case let .storage(value):
                    let fact = StorageEventNormalizer.normalize(value, identityScope: processRunID.uuidString)
                    pending.append((index, makeObservation(from: fact), fact))
                case let .power(value):
                    if let fact = PowerTransitionNormalizer.normalize(value) {
                        pending.append((index, makeObservation(from: fact), fact))
                    }
                case let .network(value):
                    if let fact = NetworkPathNormalizer.normalize(value) {
                        pending.append((index, makeObservation(from: fact), fact))
                    }
                }
            }
        }
        guard !pending.isEmpty else { return results }
        do {
            try await journal.appendBatch(pending.map(\.observation))
            for item in pending {
                results[item.index] = item.observation
            }
        } catch {
            #if HORIZON2_MEASUREMENT
                let category = failureCategory(error)
                for _ in pending {
                    (measurementMetrics as! Horizon2MeasurementMetrics).recordFailure(category: category)
                }
            #endif
            for item in pending {
                await recordHealth(EvidenceSourceHealthUpdate(
                    sourceID: item.fact.sourceID,
                    event: .sourceUnavailable,
                    reason: (error as? EvidenceJournalError) == .capacityUnavailable
                        ? .journalCapacityUnavailable
                        : .sourceUnavailable,
                    suppressedCount: 0,
                    observedAt: clock.reading().wallTime,
                    detail: "Evidence sink rejected (item.fact.sourceID.rawValue) observation"
                ))
            }
        }
        return results
    }

    private func process(_ raw: Horizon2RawEvent, capturedAt: EvidenceClockReading) async -> Observation? {
        nextIngressOrder += 1
        switch raw {
        case let .lifecycle(event):
            let boundEvent = SleepWakeRawEvent(
                kind: event.kind,
                observedAt: event.observedAt ?? capturedAt,
                ingressOrder: nextIngressOrder
            )
            handleLifecycle(boundEvent)
            return nil
        case let .storage(value):
            return await append(fact: StorageEventNormalizer.normalize(value, identityScope: processRunID.uuidString))
        case let .power(value):
            guard let fact = PowerTransitionNormalizer.normalize(value) else { return nil }
            return await append(fact: fact)
        case let .network(value):
            guard let fact = NetworkPathNormalizer.normalize(value) else { return nil }
            return await append(fact: fact)
        }
    }

    private func handleLifecycle(_ event: SleepWakeRawEvent) {
        // The event carries the adapter's clock reading. The ingress order is
        // assigned only here, so a callback accepted before this boundary can
        // never be retroactively placed in the new epoch.
        _ = event.observedAt
        _ = event.ingressOrder
        switch event.kind {
        case .willSleep:
            guard !isSleeping else { return }
            isSleeping = true
            correlationEpochID = UUID()
            sequenceBySource.removeAll(keepingCapacity: true)
        case .didWake:
            guard isSleeping else { return }
            isSleeping = false
            correlationEpochID = UUID()
            sequenceBySource.removeAll(keepingCapacity: true)
            onWake()
        }
    }

    private func append(fact: NormalizedEvidenceFact) async -> Observation? {
        let observation = makeObservation(from: fact)
        do {
            try await journal.append(observation)
            return observation
        } catch {
            #if HORIZON2_MEASUREMENT
                (measurementMetrics as! Horizon2MeasurementMetrics).recordFailure(category: failureCategory(error))
            #endif
            await recordHealth(EvidenceSourceHealthUpdate(
                sourceID: fact.sourceID,
                event: .sourceUnavailable,
                reason: (error as? EvidenceJournalError) == .capacityUnavailable
                    ? .journalCapacityUnavailable
                    : .sourceUnavailable,
                suppressedCount: 0,
                observedAt: clock.reading().wallTime,
                detail: "Evidence sink rejected \(fact.sourceID.rawValue) observation"
            ))
            return nil
        }
    }

    private func makeObservation(from fact: NormalizedEvidenceFact) -> Observation {
        let reading = clock.reading()
        let sequence = (sequenceBySource[fact.sourceID] ?? 0) + 1
        sequenceBySource[fact.sourceID] = sequence
        let orderingDomain = EvidenceOrderingDomain(
            sourceID: fact.sourceID,
            processRunID: processRunID,
            clockDomainID: reading.clockDomainID
        )
        let time = EvidenceTime(
            observedWallTime: reading.wallTime,
            continuousNanoseconds: reading.continuousNanoseconds,
            processUptimeNanoseconds: reading.processUptimeNanoseconds,
            processRunID: processRunID,
            bootSessionID: reading.bootSessionID,
            localSequence: sequence,
            sourceTimestampQuality: fact.provenance.sourceTimestampQuality,
            orderingDomain: orderingDomain,
            sourceOccurrence: fact.sourceOccurrence,
            lifecycleBoundary: fact.lifecycleBoundary,
            correlationEpochID: correlationEpochID
        )
        return Observation(
            id: UUID(),
            domain: fact.domain,
            eventKind: fact.eventKind,
            sourceID: fact.sourceID,
            subject: fact.subject,
            provenance: fact.provenance,
            time: time,
            availability: fact.availability,
            previousState: fact.previousState,
            currentState: fact.currentState,
            attributes: fact.attributes,
            sensitivity: fact.sensitivity
        )
    }

    #if HORIZON2_MEASUREMENT
        private func failureCategory(_ error: Error) -> String {
            switch error as? EvidenceJournalError {
            case .capacityUnavailable: return "journal_capacity_unavailable"
            case .oversizedRecord: return "oversized_record"
            case .observationPayloadMismatch: return "observation_payload_mismatch"
            case .unavailable: return "journal_unavailable"
            case .none: return "other"
            default: return "other"
            }
        }
    #endif

    private func recordHealth(_ update: EvidenceSourceHealthUpdate) async {
        let record = EvidenceSourceHealthRecord(
            id: UUID(),
            sourceID: update.sourceID,
            event: update.event,
            reason: update.reason,
            suppressedCount: update.suppressedCount,
            observedAt: update.observedAt,
            detail: update.detail
        )
        try? await journal.recordSourceHealth(record)
    }
}

final class EvidenceIngestionAuthority: @unchecked Sendable {
    private struct EvidenceBatch {
        let items: [EvidenceIngressItem]
        #if HORIZON2_MEASUREMENT
            let dequeuedAtContinuousNanoseconds: UInt64
            let measurementContext: Horizon2MeasurementBatchContext
        #endif
    }

    private let lock = NSLock()
    private let capacity: Int
    private let processor: EvidenceIngestionProcessor
    private let clock: any EvidenceClock
    private var activeGeneration: UInt64?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var pendingItems: [EvidenceIngressItem] = []
    private var worker: Task<Void, Never>?
    private var overflowCounts: [Horizon2OverflowKey: Int] = [:]
    private var totalOverflowCount = 0
    private var currentQueuedPayloadBytes = 0
    private var peakQueuedPayloadBytes = 0
    private var wakeSignaled = false
    private let cooperativeBatchCoalescingEnabled: Bool
    private let residenceMaximumNanoseconds: UInt64
    private let measurementMetrics: Any?

    init(
        capacity: Int = Horizon2EvidenceConfiguration.collectorQueueCapacity,
        clock: any EvidenceClock,
        journal: any EvidenceJournal,
        processRunID: UUID,
        onWake: @escaping @Sendable () -> Void
    ) {
        self.capacity = max(1, capacity)
        self.clock = clock
        #if HORIZON2_MEASUREMENT
            let overrideMilliseconds = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("-Horizon2MeasurementResidenceLimitMilliseconds=") })
                .flatMap { Int($0.dropFirst("-Horizon2MeasurementResidenceLimitMilliseconds=".count)) }
            let residenceMilliseconds = max(
                1,
                overrideMilliseconds ?? Horizon2EvidenceConfiguration.collectorQueueResidenceMaximumMilliseconds
            )
        #else
            let residenceMilliseconds = Horizon2EvidenceConfiguration.collectorQueueResidenceMaximumMilliseconds
        #endif
        residenceMaximumNanoseconds = UInt64(residenceMilliseconds) * 1_000_000
        #if HORIZON2_MEASUREMENT
            cooperativeBatchCoalescingEnabled = !ProcessInfo.processInfo.arguments.contains("-Horizon2MeasurementDisableBatchCoalescing")
        #else
            cooperativeBatchCoalescingEnabled = true
        #endif
        #if HORIZON2_MEASUREMENT
            measurementMetrics = Horizon2MeasurementMetrics()
        #else
            measurementMetrics = nil
        #endif
        processor = EvidenceIngestionProcessor(
            clock: clock,
            journal: journal,
            processRunID: processRunID,
            onWake: onWake,
            measurementMetrics: measurementMetrics
        )
    }

    func start(generation: UInt64) {
        stop()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock()
            self.wakeContinuation = continuation
            self.activeGeneration = generation
            self.wakeSignaled = false
            lock.unlock()
        }
        worker = Task { [weak self, processor] in
            let activated = await processor.activate(generation: generation) { [weak self] in
                self?.isCurrent(generation) ?? false
            }
            guard activated else { return }
            for await _ in stream {
                guard let self else { break }
                self.consumeWakeSignal()
                var yieldedBeforeFirstBatch = false
                while true {
                    if !yieldedBeforeFirstBatch, self.shouldYieldBeforePartialBatch() {
                        yieldedBeforeFirstBatch = true
                        await Task.yield()
                    }
                    guard let batch = self.takeBatch() else {
                        await self.flushOverflowCounts(to: processor)
                        break
                    }
                    await self.flushOverflowCounts(to: processor)
                    let observations = await self.process(batch)
                    for (item, observation) in zip(batch.items, observations) {
                        #if HORIZON2_MEASUREMENT
                            (self.measurementMetrics as! Horizon2MeasurementMetrics).completed(
                                enqueuedAtNanoseconds: item.enqueuedAtContinuousNanoseconds,
                                dequeuedAtNanoseconds: batch.dequeuedAtContinuousNanoseconds,
                                persisted: observation != nil
                            )
                        #endif
                        item.completion?(observation)
                    }
                    if self.shouldYieldAfterPartialBatch() {
                        await Task.yield()
                    }
                }
            }
            if let self {
                while let batch = self.takeBatch() {
                    await self.flushOverflowCounts(to: processor)
                    let observations = await self.process(batch)
                    for (item, observation) in zip(batch.items, observations) {
                        #if HORIZON2_MEASUREMENT
                            (self.measurementMetrics as! Horizon2MeasurementMetrics).completed(
                                enqueuedAtNanoseconds: item.enqueuedAtContinuousNanoseconds,
                                dequeuedAtNanoseconds: batch.dequeuedAtContinuousNanoseconds,
                                persisted: observation != nil
                            )
                        #endif
                        item.completion?(observation)
                    }
                }
                await self.flushOverflowCounts(to: processor)
            }
        }
    }

    func enqueue(_ emission: EvidenceAdapterEmission, generation: UInt64) {
        let item = EvidenceIngressItem(
            emission: emission,
            generation: generation,
            capturedAt: clock.reading(),
            completion: nil,
            enqueuedAtContinuousNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        enqueue(item)
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
        lock.lock()
        activeGeneration = nil
        let oldContinuation = wakeContinuation
        wakeContinuation = nil
        wakeSignaled = false
        let pending = pendingItems
        pendingItems.removeAll(keepingCapacity: true)
        currentQueuedPayloadBytes = 0
        peakQueuedPayloadBytes = 0
        worker = nil
        lock.unlock()
        oldContinuation?.finish()
        for item in pending {
            #if HORIZON2_MEASUREMENT
                (measurementMetrics as! Horizon2MeasurementMetrics).discarded(payloadBytes: item.measurementPayloadBytes)
            #endif
            item.completion?(nil)
        }
    }

    func drainForTesting() async {
        while true {
            if isIdle() {
                return
            }
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
        lock.lock()
        defer { lock.unlock() }
        return overflowCounts.values.reduce(0, +)
    }

    var queuedPayloadBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentQueuedPayloadBytes
    }

    var totalOverflowCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalOverflowCount
    }

    var peakQueuedPayloadBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakQueuedPayloadBytes
    }

    private func enqueue(_ item: EvidenceIngressItem) {
        #if HORIZON2_MEASUREMENT
            (measurementMetrics as! Horizon2MeasurementMetrics).offered(payloadBytes: item.measurementPayloadBytes)
        #endif
        var dropped: [Horizon2DroppedIngress] = []
        var rejectNewItem = false
        lock.lock()
        guard let activeGeneration, activeGeneration == item.generation, wakeContinuation != nil else {
            lock.unlock()
            item.completion?(nil)
            return
        }
        dropped.append(contentsOf: expireAgedItemsLocked(now: DispatchTime.now().uptimeNanoseconds))
        let itemBytes = item.batchPayloadBytes
        if itemBytes > Horizon2EvidenceConfiguration.combinedQueuePayloadMaximumBytes {
            recordOverflowLocked(item, reason: .payloadLimit)
            rejectNewItem = true
        } else {
            while pendingItems.count >= capacity {
                guard let droppedItem = pendingItems.first else { break }
                dropped.append(removeOldestLocked(droppedItem, reason: .countLimit))
            }
            while currentQueuedPayloadBytes + itemBytes > Horizon2EvidenceConfiguration.combinedQueuePayloadMaximumBytes {
                guard let droppedItem = pendingItems.first else { break }
                dropped.append(removeOldestLocked(droppedItem, reason: .payloadLimit))
            }
        }
        #if HORIZON2_MEASUREMENT
            // Keep diagnostic accounting in the same order as the queue
            // mutation so the recorded peak is an externally observable
            // queue state, not a lock-internal transient.
            for entry in dropped {
                (measurementMetrics as! Horizon2MeasurementMetrics).dropped(
                    payloadBytes: entry.item.measurementPayloadBytes,
                    reason: entry.reason.rawValue
                )
            }
            if rejectNewItem {
                (measurementMetrics as! Horizon2MeasurementMetrics).rejected(
                    payloadBytes: item.measurementPayloadBytes,
                    reason: Horizon2IngressOverflowReason.payloadLimit.rawValue
                )
            }
        #endif
        // The empty-to-nonempty transition owns the wake. While the worker is
        // processing a batch, producers only need to leave work visible in the
        // queue; the worker's bounded cooperative yield observes that work
        // before it waits again. Keeping one signaled bit prevents duplicate
        // stream events without allowing a producer to race a lost wake.
        if !rejectNewItem {
            let shouldSignal = !cooperativeBatchCoalescingEnabled || (pendingItems.isEmpty && !wakeSignaled)
            pendingItems.append(item)
            currentQueuedPayloadBytes += itemBytes
            peakQueuedPayloadBytes = max(peakQueuedPayloadBytes, currentQueuedPayloadBytes)
            #if HORIZON2_MEASUREMENT
                (measurementMetrics as! Horizon2MeasurementMetrics).enqueued(payloadBytes: item.measurementPayloadBytes)
            #endif
            if shouldSignal {
                wakeSignaled = true
                wakeContinuation?.yield(())
            }
        }
        lock.unlock()
        finishDropped(dropped)
        if rejectNewItem {
            lock.lock()
            if !wakeSignaled {
                wakeSignaled = true
                wakeContinuation?.yield(())
            }
            lock.unlock()
            item.completion?(nil)
        }
    }

    private func expireAgedItemsLocked(now: UInt64) -> [Horizon2DroppedIngress] {
        var dropped: [Horizon2DroppedIngress] = []
        while let oldest = pendingItems.first,
              now > oldest.enqueuedAtContinuousNanoseconds,
              now - oldest.enqueuedAtContinuousNanoseconds > residenceMaximumNanoseconds
        {
            dropped.append(removeOldestLocked(oldest, reason: .residenceLimit))
        }
        return dropped
    }

    private func removeOldestLocked(
        _ item: EvidenceIngressItem,
        reason: Horizon2IngressOverflowReason
    ) -> Horizon2DroppedIngress {
        let removed = pendingItems.removeFirst()
        precondition(removed.emission.sourceID == item.emission.sourceID)
        currentQueuedPayloadBytes -= removed.batchPayloadBytes
        precondition(currentQueuedPayloadBytes >= 0)
        recordOverflowLocked(removed, reason: reason)
        return Horizon2DroppedIngress(item: removed, reason: reason)
    }

    private func recordOverflowLocked(_ item: EvidenceIngressItem, reason: Horizon2IngressOverflowReason) {
        let key = Horizon2OverflowKey(sourceID: item.emission.sourceID, reason: reason)
        overflowCounts[key, default: 0] += 1
        totalOverflowCount += 1
    }

    private func finishDropped(_ dropped: [Horizon2DroppedIngress]) {
        for entry in dropped {
            entry.item.completion?(nil)
        }
    }

    private func recordDroppedMeasurement(_ dropped: [Horizon2DroppedIngress]) {
        #if HORIZON2_MEASUREMENT
            for entry in dropped {
                (measurementMetrics as! Horizon2MeasurementMetrics).dropped(
                    payloadBytes: entry.item.measurementPayloadBytes,
                    reason: entry.reason.rawValue
                )
            }
        #else
            _ = dropped
        #endif
    }

    private func consumeWakeSignal() {
        lock.lock()
        wakeSignaled = false
        lock.unlock()
    }

    private func shouldYieldBeforePartialBatch() -> Bool {
        guard cooperativeBatchCoalescingEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        let count = pendingItems.count
        return count > 0 && count < Horizon2EvidenceConfiguration.maximumBatchCount
    }

    private func shouldYieldAfterPartialBatch() -> Bool {
        guard cooperativeBatchCoalescingEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        let count = pendingItems.count
        return count > 0 && count < Horizon2EvidenceConfiguration.maximumBatchCount
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    private func isIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        #if HORIZON2_MEASUREMENT
            let snapshot = (measurementMetrics as! Horizon2MeasurementMetrics).snapshot()
            return pendingItems.isEmpty && snapshot.inFlightPersistenceCount == 0
        #else
            return pendingItems.isEmpty
        #endif
    }

    private func takeBatch() -> EvidenceBatch? {
        lock.lock()
        let expired = expireAgedItemsLocked(now: DispatchTime.now().uptimeNanoseconds)
        guard !pendingItems.isEmpty else {
            recordDroppedMeasurement(expired)
            lock.unlock()
            finishDropped(expired)
            return nil
        }
        var count = 0
        var bytes = 0
        for item in pendingItems {
            let itemBytes = item.batchPayloadBytes
            // Seven observations keeps the measured SQLite transaction delta
            // below the frozen 1 MiB headroom on the tested host; the byte
            // bound remains a second guard for unusually large observations.
            if count > 0,
               !Horizon2EvidenceConfiguration.batchFits(
                   count: count + 1,
                   canonicalPayloadBytes: bytes + itemBytes
               )
            {
                break
            }
            count += 1
            bytes += itemBytes
        }
        let batch = Array(pendingItems.prefix(count))
        let dequeuedAtContinuousNanoseconds = DispatchTime.now().uptimeNanoseconds
        #if HORIZON2_MEASUREMENT
            let measurementContext = Horizon2MeasurementBatchContext(
                observationCount: count,
                canonicalPayloadBytes: bytes,
                queueDepthBeforeDequeue: pendingItems.count,
                queueDepthAfterDequeue: pendingItems.count - count,
                firstItemEnqueuedAtMonotonicNanoseconds: batch[0].enqueuedAtContinuousNanoseconds
            )
        #endif
        pendingItems.removeFirst(count)
        currentQueuedPayloadBytes -= batch.reduce(0) { $0 + $1.batchPayloadBytes }
        precondition(currentQueuedPayloadBytes >= 0)
        #if HORIZON2_MEASUREMENT
            for item in batch {
                (measurementMetrics as! Horizon2MeasurementMetrics).dequeued(
                    payloadBytes: item.measurementPayloadBytes,
                    enqueuedAtNanoseconds: item.enqueuedAtContinuousNanoseconds,
                    dequeuedAtNanoseconds: dequeuedAtContinuousNanoseconds
                )
            }
        #endif
        #if HORIZON2_MEASUREMENT
            let result = EvidenceBatch(
                items: batch,
                dequeuedAtContinuousNanoseconds: dequeuedAtContinuousNanoseconds,
                measurementContext: measurementContext
            )
            recordDroppedMeasurement(expired)
            lock.unlock()
            finishDropped(expired)
            return result
        #else
            let result = EvidenceBatch(items: batch)
            recordDroppedMeasurement(expired)
            lock.unlock()
            finishDropped(expired)
            return result
        #endif
    }

    private func process(_ batch: EvidenceBatch) async -> [Observation?] {
        #if HORIZON2_MEASUREMENT
            let startNanoseconds = DispatchTime.now().uptimeNanoseconds
        #endif
        let observations = await processor.process(batch.items)
        #if HORIZON2_MEASUREMENT
            let endNanoseconds = DispatchTime.now().uptimeNanoseconds
            (measurementMetrics as! Horizon2MeasurementMetrics).completedBatch(
                context: batch.measurementContext,
                startNanoseconds: startNanoseconds,
                endNanoseconds: endNanoseconds,
                terminalSuccessCount: observations.reduce(into: 0) { count, observation in
                    if observation != nil {
                        count += 1
                    }
                },
                terminalFailureCount: observations.reduce(into: 0) { count, observation in
                    if observation == nil {
                        count += 1
                    }
                }
            )
        #endif
        return observations
    }

    private func takeOverflowCounts() -> [Horizon2OverflowKey: Int] {
        lock.lock()
        defer { lock.unlock() }
        let counts = overflowCounts
        overflowCounts.removeAll(keepingCapacity: true)
        return counts
    }

    private func flushOverflowCounts(to processor: EvidenceIngestionProcessor) async {
        let dropped = takeOverflowCounts()
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
            (measurementMetrics as! Horizon2MeasurementMetrics).snapshot()
        }
    #endif
}

private extension EvidenceIngestionProcessor {
    func recordOverflow(
        sourceID: Horizon2SourceID,
        count: Int,
        reason: Horizon2IngressOverflowReason,
        observedAt: Date
    ) async {
        let record = EvidenceSourceHealthRecord(
            id: UUID(),
            sourceID: sourceID,
            event: .sourceUnavailable,
            reason: .incompleteCapture,
            suppressedCount: count,
            observedAt: observedAt,
            detail: Horizon2OverflowDiagnostic.detail(for: reason)
        )
        try? await journal.recordSourceHealth(record)
    }
}

enum Horizon2OverflowDiagnostic {
    static func detail(for reason: Horizon2IngressOverflowReason) -> String {
        "Bounded Horizon 2 ingress overflow (\(reason.rawValue)); evidence is incomplete"
    }
}

private extension EvidenceIngressItem {
    var batchPayloadBytes: Int {
        switch emission {
        case let .raw(raw):
            return raw.persistencePayloadBytes
        case let .health(update):
            return 1024 + (update.detail?.utf8.count ?? 0)
        }
    }

    #if HORIZON2_MEASUREMENT
        var measurementPayloadBytes: Int {
            batchPayloadBytes
        }
    #endif
}

private extension Horizon2RawEvent {
    var persistencePayloadBytes: Int {
        let estimate: Int
        switch self {
        case let .storage(event):
            estimate = 64 + event.identity.digestMaterial.reduce(0) { $0 + $1.utf8.count }
        case let .power(event):
            estimate = 96 + String(describing: event.current.meaningfulState).utf8.count
        case let .network(event):
            estimate = 64 + event.current.interfaces.reduce(0) { $0 + $1.rawValue.utf8.count }
        case .lifecycle:
            estimate = 32
        }
        // Include a deterministic envelope allowance for canonical JSON,
        // attributes, and SQLite row metadata in every build configuration.
        return max(4096, estimate + 4096)
    }
}
