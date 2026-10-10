import Foundation

struct EvidenceIngressBatch {
    let items: [EvidenceIngressItem]
    #if HORIZON2_MEASUREMENT
        let dequeuedAtContinuousNanoseconds: UInt64
        let measurementContext: Horizon2MeasurementBatchContext
    #endif
}

struct EvidenceIngressAdmission {
    let accepted: Bool
    let shouldSignalWorker: Bool
    let dropped: [Horizon2DroppedIngress]
}

struct EvidenceIngressDequeue {
    let batch: EvidenceIngressBatch?
    let expired: [Horizon2DroppedIngress]
}

final class EvidenceIngressBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let residenceMaximumNanoseconds: UInt64
    private let cooperativeBatchCoalescingEnabled: Bool
    #if HORIZON2_MEASUREMENT
        private let measurementMetrics: Horizon2MeasurementMetrics
    #endif

    private var activeGeneration: UInt64?
    private var pendingItems: [EvidenceIngressItem] = []
    private var overflowCounts: [Horizon2OverflowKey: Int] = [:]
    private var totalOverflowCount = 0
    private var currentQueuedPayloadBytes = 0
    private var peakQueuedPayloadBytes = 0
    private var wakeSignaled = false

    #if HORIZON2_MEASUREMENT
        init(
            capacity: Int,
            residenceMaximumNanoseconds: UInt64,
            cooperativeBatchCoalescingEnabled: Bool,
            measurementMetrics: Horizon2MeasurementMetrics
        ) {
            self.capacity = max(1, capacity)
            self.residenceMaximumNanoseconds = residenceMaximumNanoseconds
            self.cooperativeBatchCoalescingEnabled = cooperativeBatchCoalescingEnabled
            self.measurementMetrics = measurementMetrics
        }
    #else
        init(
            capacity: Int,
            residenceMaximumNanoseconds: UInt64,
            cooperativeBatchCoalescingEnabled: Bool
        ) {
            self.capacity = max(1, capacity)
            self.residenceMaximumNanoseconds = residenceMaximumNanoseconds
            self.cooperativeBatchCoalescingEnabled = cooperativeBatchCoalescingEnabled
        }
    #endif

    func begin(generation: UInt64) {
        lock.lock()
        activeGeneration = generation
        wakeSignaled = false
        lock.unlock()
    }

    func stop() -> [EvidenceIngressItem] {
        lock.lock()
        activeGeneration = nil
        let pending = pendingItems
        pendingItems.removeAll(keepingCapacity: true)
        currentQueuedPayloadBytes = 0
        peakQueuedPayloadBytes = 0
        wakeSignaled = false
        #if HORIZON2_MEASUREMENT
            for item in pending {
                measurementMetrics.discarded(payloadBytes: item.measurementPayloadBytes)
            }
        #endif
        lock.unlock()
        return pending
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    func admit(_ item: EvidenceIngressItem) -> EvidenceIngressAdmission {
        var dropped: [Horizon2DroppedIngress] = []
        var rejectNewItem = false
        var shouldSignalWorker = false
        lock.lock()
        guard activeGeneration == item.generation else {
            lock.unlock()
            return EvidenceIngressAdmission(accepted: false, shouldSignalWorker: false, dropped: [])
        }

        dropped.append(contentsOf: expireAgedItemsLocked(now: DispatchTime.now().uptimeNanoseconds))
        let itemBytes = item.batchPayloadBytes
        if itemBytes > Horizon2EvidenceConfiguration.combinedQueuePayloadMaximumBytes {
            recordOverflowLocked(item, reason: .payloadLimit)
            rejectNewItem = true
        } else {
            while pendingItems.count >= capacity {
                guard let oldest = pendingItems.first else { break }
                dropped.append(removeOldestLocked(oldest, reason: .countLimit))
            }
            while currentQueuedPayloadBytes + itemBytes > Horizon2EvidenceConfiguration
                .combinedQueuePayloadMaximumBytes {
                guard let oldest = pendingItems.first else { break }
                dropped.append(removeOldestLocked(oldest, reason: .payloadLimit))
            }
        }
        recordMeasurement(for: dropped, rejected: rejectNewItem ? item : nil)

        if !rejectNewItem {
            shouldSignalWorker = !cooperativeBatchCoalescingEnabled || (pendingItems.isEmpty && !wakeSignaled)
            pendingItems.append(item)
            currentQueuedPayloadBytes += itemBytes
            peakQueuedPayloadBytes = max(peakQueuedPayloadBytes, currentQueuedPayloadBytes)
            #if HORIZON2_MEASUREMENT
                measurementMetrics.enqueued(payloadBytes: item.measurementPayloadBytes)
            #endif
            if shouldSignalWorker {
                wakeSignaled = true
            }
        } else if !wakeSignaled {
            wakeSignaled = true
            shouldSignalWorker = true
        }
        lock.unlock()
        return EvidenceIngressAdmission(
            accepted: !rejectNewItem,
            shouldSignalWorker: shouldSignalWorker,
            dropped: dropped
        )
    }

    func consumeWakeSignal() {
        lock.lock()
        wakeSignaled = false
        lock.unlock()
    }

    func shouldYieldBeforePartialBatch() -> Bool {
        guard cooperativeBatchCoalescingEnabled else { return false }
        return hasPartialBatch()
    }

    func shouldYieldAfterPartialBatch() -> Bool {
        guard cooperativeBatchCoalescingEnabled else { return false }
        return hasPartialBatch()
    }

    func isIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        #if HORIZON2_MEASUREMENT
            let snapshot = measurementMetrics.snapshot()
            return pendingItems.isEmpty && snapshot.inFlightPersistenceCount == 0
        #else
            return pendingItems.isEmpty
        #endif
    }

    func takeBatch() -> EvidenceIngressDequeue {
        lock.lock()
        let expired = expireAgedItemsLocked(now: DispatchTime.now().uptimeNanoseconds)
        guard !pendingItems.isEmpty else {
            recordMeasurement(for: expired, rejected: nil)
            lock.unlock()
            return EvidenceIngressDequeue(batch: nil, expired: expired)
        }

        let count = batchCountLocked()
        let batch = Array(pendingItems.prefix(count))
        let dequeuedAtContinuousNanoseconds = DispatchTime.now().uptimeNanoseconds
        #if HORIZON2_MEASUREMENT
            let measurementContext = Horizon2MeasurementBatchContext(
                observationCount: count,
                canonicalPayloadBytes: batch.reduce(0) { $0 + $1.batchPayloadBytes },
                queueDepthBeforeDequeue: pendingItems.count,
                queueDepthAfterDequeue: pendingItems.count - count,
                firstItemEnqueuedAtMonotonicNanoseconds: batch[0].enqueuedAtContinuousNanoseconds
            )
            for item in batch {
                measurementMetrics.dequeued(
                    payloadBytes: item.measurementPayloadBytes,
                    enqueuedAtNanoseconds: item.enqueuedAtContinuousNanoseconds,
                    dequeuedAtNanoseconds: dequeuedAtContinuousNanoseconds
                )
            }
        #endif
        pendingItems.removeFirst(count)
        currentQueuedPayloadBytes -= batch.reduce(0) { $0 + $1.batchPayloadBytes }
        precondition(currentQueuedPayloadBytes >= 0)
        recordMeasurement(for: expired, rejected: nil)
        lock.unlock()

        #if HORIZON2_MEASUREMENT
            return EvidenceIngressDequeue(
                batch: EvidenceIngressBatch(
                    items: batch,
                    dequeuedAtContinuousNanoseconds: dequeuedAtContinuousNanoseconds,
                    measurementContext: measurementContext
                ),
                expired: expired
            )
        #else
            return EvidenceIngressDequeue(batch: EvidenceIngressBatch(items: batch), expired: expired)
        #endif
    }

    func takeOverflowCounts() -> [Horizon2OverflowKey: Int] {
        lock.lock()
        defer { lock.unlock() }
        let counts = overflowCounts
        overflowCounts.removeAll(keepingCapacity: true)
        return counts
    }

    func overflowCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return overflowCounts.values.reduce(0, +)
    }

    func queuedPayloadBytesForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentQueuedPayloadBytes
    }

    func totalOverflowCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return totalOverflowCount
    }

    func peakQueuedPayloadBytesForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peakQueuedPayloadBytes
    }

    #if HORIZON2_MEASUREMENT
        func measurementSnapshot() -> Horizon2MeasurementSnapshot {
            measurementMetrics.snapshot()
        }

        func recordCompletedBatch(
            batch: EvidenceIngressBatch,
            startNanoseconds: UInt64,
            endNanoseconds: UInt64,
            observations: [Observation?]
        ) {
            measurementMetrics.completedBatch(
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
        }
    #endif
}

private extension EvidenceIngressBuffer {
    func hasPartialBatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let count = pendingItems.count
        return count > 0 && count < Horizon2EvidenceConfiguration.maximumBatchCount
    }

    func batchCountLocked() -> Int {
        var count = 0
        var bytes = 0
        for item in pendingItems {
            let itemBytes = item.batchPayloadBytes
            if count > 0,
               !Horizon2EvidenceConfiguration.batchFits(
                   count: count + 1,
                   canonicalPayloadBytes: bytes + itemBytes
               ) {
                break
            }
            count += 1
            bytes += itemBytes
        }
        return count
    }

    func expireAgedItemsLocked(now: UInt64) -> [Horizon2DroppedIngress] {
        var dropped: [Horizon2DroppedIngress] = []
        while let oldest = pendingItems.first,
              now > oldest.enqueuedAtContinuousNanoseconds,
              now - oldest.enqueuedAtContinuousNanoseconds > residenceMaximumNanoseconds {
            dropped.append(removeOldestLocked(oldest, reason: .residenceLimit))
        }
        return dropped
    }

    func removeOldestLocked(
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

    func recordOverflowLocked(_ item: EvidenceIngressItem, reason: Horizon2IngressOverflowReason) {
        let key = Horizon2OverflowKey(sourceID: item.emission.sourceID, reason: reason)
        overflowCounts[key, default: 0] += 1
        totalOverflowCount += 1
    }

    func recordMeasurement(
        for dropped: [Horizon2DroppedIngress],
        rejected: EvidenceIngressItem?
    ) {
        #if HORIZON2_MEASUREMENT
            for entry in dropped {
                measurementMetrics.dropped(
                    payloadBytes: entry.item.measurementPayloadBytes,
                    reason: entry.reason.rawValue
                )
            }
            if let rejected {
                measurementMetrics.rejected(
                    payloadBytes: rejected.measurementPayloadBytes,
                    reason: Horizon2IngressOverflowReason.payloadLimit.rawValue
                )
            }
        #else
            _ = dropped
            _ = rejected
        #endif
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
