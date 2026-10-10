import Foundation

actor EvidenceIngestionProcessor {
    private let clock: any EvidenceClock
    private let journal: any EvidenceJournal
    private let processRunID: UUID
    private let onWake: @Sendable () -> Void
    #if HORIZON2_MEASUREMENT
        private let measurementMetrics: Horizon2MeasurementMetrics
    #endif

    private var activeGeneration: UInt64?
    private var correlationEpochID = UUID()
    private var isSleeping = false
    private var nextIngressOrder: UInt64 = 0
    private var sequenceBySource: [Horizon2SourceID: UInt64] = [:]

    #if HORIZON2_MEASUREMENT
        init(
            clock: any EvidenceClock,
            journal: any EvidenceJournal,
            processRunID: UUID,
            onWake: @escaping @Sendable () -> Void,
            measurementMetrics: Horizon2MeasurementMetrics
        ) {
            self.clock = clock
            self.journal = journal
            self.processRunID = processRunID
            self.onWake = onWake
            self.measurementMetrics = measurementMetrics
        }
    #else
        init(
            clock: any EvidenceClock,
            journal: any EvidenceJournal,
            processRunID: UUID,
            onWake: @escaping @Sendable () -> Void
        ) {
            self.clock = clock
            self.journal = journal
            self.processRunID = processRunID
            self.onWake = onWake
        }
    #endif

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
        var pending: [PendingNormalizedObservation] = []
        for (index, item) in items.enumerated() {
            await collect(item, index: index, into: &pending)
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
                    measurementMetrics.recordFailure(category: category)
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

    private func collect(
        _ item: EvidenceIngressItem,
        index: Int,
        into pending: inout [PendingNormalizedObservation]
    ) async {
        guard activeGeneration == item.generation else { return }
        switch item.emission {
        case let .health(update):
            await recordHealth(update)
        case let .raw(raw):
            collect(raw, capturedAt: item.capturedAt, index: index, into: &pending)
        }
    }

    private func collect(
        _ raw: Horizon2RawEvent,
        capturedAt: EvidenceClockReading,
        index: Int,
        into pending: inout [PendingNormalizedObservation]
    ) {
        nextIngressOrder += 1
        switch raw {
        case let .lifecycle(event):
            let boundEvent = SleepWakeRawEvent(
                kind: event.kind,
                observedAt: event.observedAt ?? capturedAt,
                ingressOrder: nextIngressOrder
            )
            handleLifecycle(boundEvent)
        case let .storage(value):
            let fact = StorageEventNormalizer.normalize(value, identityScope: processRunID.uuidString)
            pending.append(PendingNormalizedObservation(
                index: index,
                observation: makeObservation(from: fact),
                fact: fact
            ))
        case let .power(value):
            appendPending(
                PowerTransitionNormalizer.normalize(value),
                index: index,
                into: &pending
            )
        case let .network(value):
            appendPending(
                NetworkPathNormalizer.normalize(value),
                index: index,
                into: &pending
            )
        }
    }

    private func appendPending(
        _ fact: NormalizedEvidenceFact?,
        index: Int,
        into pending: inout [PendingNormalizedObservation]
    ) {
        guard let fact else { return }
        pending.append(PendingNormalizedObservation(
            index: index,
            observation: makeObservation(from: fact),
            fact: fact
        ))
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
                measurementMetrics.recordFailure(category: failureCategory(error))
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
}

extension EvidenceIngestionProcessor {
    func makeObservation(from fact: NormalizedEvidenceFact) -> Observation {
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

    func recordHealth(_ update: EvidenceSourceHealthUpdate) async {
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
