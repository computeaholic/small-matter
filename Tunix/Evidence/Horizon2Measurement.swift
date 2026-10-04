#if HORIZON2_MEASUREMENT
    import Foundation

    struct Horizon2MeasurementSnapshot: Codable, Sendable {
        let offered: Int
        let accepted: Int
        let persisted: Int
        let failed: Int
        let collectorOverflow: Int
        let pendingWriteOverflow: Int
        let currentCollectorDepth: Int
        let currentPendingDepth: Int
        let inFlightPersistenceCount: Int
        let collectorPeakDepth: Int
        let pendingWritePeakDepth: Int
        let collectorEncodedPayloadBytes: Int
        let pendingEncodedPayloadBytes: Int
        let peakCombinedEncodedPayloadBytes: Int
        let acceptedDurableLatenciesMilliseconds: [Double]
        let acceptedTerminalLatenciesMilliseconds: [Double]
        let queueResidenceLatenciesMilliseconds: [Double]
        let terminalProcessingLatenciesMilliseconds: [Double]
        let failureCategories: [String: Int]
        let overflowReasons: [String: Int]
        let batchProfile: Horizon2MeasurementBatchProfile
        let batchRecords: [Horizon2MeasurementBatchRecord]
    }

    struct Horizon2MeasurementStageStatistics: Codable, Sendable {
        let samples: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
        let maxMilliseconds: Double
        let totalMilliseconds: Double
    }

    struct Horizon2MeasurementAppendProfile: Codable, Sendable {
        let validationEncoding: Horizon2MeasurementStageStatistics
        let capacityCheck: Horizon2MeasurementStageStatistics
        let transactionBegin: Horizon2MeasurementStageStatistics
        let subjectProvenance: Horizon2MeasurementStageStatistics
        let rowAttributeRedactionInsert: Horizon2MeasurementStageStatistics
        let commit: Horizon2MeasurementStageStatistics
        let checkpoint: Horizon2MeasurementStageStatistics
        let fileProtection: Horizon2MeasurementStageStatistics
        let totalAppend: Horizon2MeasurementStageStatistics
    }

    struct Horizon2MeasurementBatchRecord: Codable, Sendable {
        let observationCount: Int
        let canonicalPayloadBytes: Int
        let queueDepthBeforeDequeue: Int
        let queueDepthAfterDequeue: Int
        let firstItemEnqueuedAtMonotonicNanoseconds: UInt64
        let batchStartMonotonicNanoseconds: UInt64
        let batchEndMonotonicNanoseconds: UInt64
        let persistenceDurationMilliseconds: Double
        let terminalSuccessCount: Int
        let terminalFailureCount: Int
    }

    struct Horizon2MeasurementBatchProfile: Codable, Sendable {
        let totalBatches: Int
        let sizeHistogram: [String: Int]
        let meanBatchSize: Double
        let medianBatchSize: Double
        let p95BatchSize: Double
        let percentageSizeOne: Double
        let percentageSizeSeven: Double
        let transactionsPerPersistedObservation: Double
    }

    struct Horizon2MeasurementBatchContext: Sendable {
        let observationCount: Int
        let canonicalPayloadBytes: Int
        let queueDepthBeforeDequeue: Int
        let queueDepthAfterDequeue: Int
        let firstItemEnqueuedAtMonotonicNanoseconds: UInt64
    }

    struct Horizon2MeasurementTransactionHeadroom: Codable, Sendable {
        let transactions: Int
        let minimumBaselineBytes: Int
        let maximumBaselineBytes: Int
        let maximumPeakBytes: Int
        let maximumDeltaBytes: Int
    }

    struct Horizon2MeasurementAppendTiming: Sendable {
        let validationEncodingMilliseconds: Double
        let capacityCheckMilliseconds: Double
        let transactionBeginMilliseconds: Double
        let subjectProvenanceMilliseconds: Double
        let rowAttributeRedactionInsertMilliseconds: Double
        let commitMilliseconds: Double
        let checkpointMilliseconds: Double
        let fileProtectionMilliseconds: Double
        let totalAppendMilliseconds: Double
    }

    func horizon2MeasurementStageStatistics(_ values: [Double]) -> Horizon2MeasurementStageStatistics {
        guard !values.isEmpty else {
            return Horizon2MeasurementStageStatistics(
                samples: 0,
                p50Milliseconds: 0,
                p95Milliseconds: 0,
                p99Milliseconds: 0,
                maxMilliseconds: 0,
                totalMilliseconds: 0
            )
        }
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
            return sorted[index]
        }
        return Horizon2MeasurementStageStatistics(
            samples: sorted.count,
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99),
            maxMilliseconds: sorted[sorted.count - 1],
            totalMilliseconds: values.reduce(0, +)
        )
    }

    func horizon2MeasurementAppendProfile(_ timings: [Horizon2MeasurementAppendTiming]) -> Horizon2MeasurementAppendProfile {
        Horizon2MeasurementAppendProfile(
            validationEncoding: horizon2MeasurementStageStatistics(timings.map(\.validationEncodingMilliseconds)),
            capacityCheck: horizon2MeasurementStageStatistics(timings.map(\.capacityCheckMilliseconds)),
            transactionBegin: horizon2MeasurementStageStatistics(timings.map(\.transactionBeginMilliseconds)),
            subjectProvenance: horizon2MeasurementStageStatistics(timings.map(\.subjectProvenanceMilliseconds)),
            rowAttributeRedactionInsert: horizon2MeasurementStageStatistics(timings.map(\.rowAttributeRedactionInsertMilliseconds)),
            commit: horizon2MeasurementStageStatistics(timings.map(\.commitMilliseconds)),
            checkpoint: horizon2MeasurementStageStatistics(timings.map(\.checkpointMilliseconds)),
            fileProtection: horizon2MeasurementStageStatistics(timings.map(\.fileProtectionMilliseconds)),
            totalAppend: horizon2MeasurementStageStatistics(timings.map(\.totalAppendMilliseconds))
        )
    }

    func horizon2MeasurementBatchProfile(
        _ records: [Horizon2MeasurementBatchRecord],
        persistedObservations: Int
    ) -> Horizon2MeasurementBatchProfile {
        let sizes = records.map(\.observationCount)
        let sorted = sizes.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
            return Double(sorted[index])
        }
        let histogram = sizes.reduce(into: [String: Int]()) { result, size in
            result[String(size), default: 0] += 1
        }
        let total = Double(records.count)
        return Horizon2MeasurementBatchProfile(
            totalBatches: records.count,
            sizeHistogram: histogram,
            meanBatchSize: sizes.isEmpty ? 0 : Double(sizes.reduce(0, +)) / total,
            medianBatchSize: percentile(0.50),
            p95BatchSize: percentile(0.95),
            percentageSizeOne: total == 0 ? 0 : Double(histogram["1", default: 0]) / total * 100,
            percentageSizeSeven: total == 0 ? 0 : Double(histogram["7", default: 0]) / total * 100,
            transactionsPerPersistedObservation: persistedObservations == 0
                ? 0
                : total / Double(persistedObservations)
        )
    }

    final class Horizon2MeasurementMetrics: @unchecked Sendable {
        private let lock = NSLock()
        private var offeredCount = 0
        private var acceptedCount = 0
        private var persistedCount = 0
        private var failedCount = 0
        private var collectorOverflowCount = 0
        private var pendingOverflowCount = 0
        private var collectorDepth = 0
        private var pendingDepth = 0
        private var collectorPeakDepth = 0
        private var pendingPeakDepth = 0
        private var collectorPayloadBytes = 0
        private var pendingPayloadBytes = 0
        private var collectorPeakPayloadBytes = 0
        private var pendingPeakPayloadBytes = 0
        private var peakCombinedPayloadBytes = 0
        private var latenciesMilliseconds: [Double] = []
        private var terminalLatenciesMilliseconds: [Double] = []
        private var queueResidenceLatenciesMilliseconds: [Double] = []
        private var terminalProcessingLatenciesMilliseconds: [Double] = []
        private var failureCategoryCounts: [String: Int] = [:]
        private var overflowReasonCounts: [String: Int] = [:]
        private var inFlightPersistenceCount = 0
        private var batchRecords: [Horizon2MeasurementBatchRecord] = []

        func offered(payloadBytes _: Int) {
            lock.lock()
            offeredCount += 1
            lock.unlock()
        }

        func enqueued(payloadBytes: Int) {
            lock.lock()
            acceptedCount += 1
            collectorDepth += 1
            collectorPayloadBytes += payloadBytes
            collectorPeakDepth = max(collectorPeakDepth, collectorDepth)
            collectorPeakPayloadBytes = max(collectorPeakPayloadBytes, collectorPayloadBytes)
            peakCombinedPayloadBytes = max(peakCombinedPayloadBytes, collectorPayloadBytes + pendingPayloadBytes)
            lock.unlock()
        }

        func dropped(payloadBytes: Int, reason: String) {
            lock.lock()
            collectorOverflowCount += 1
            overflowReasonCounts[reason, default: 0] += 1
            acceptedCount = max(0, acceptedCount - 1)
            collectorDepth = max(0, collectorDepth - 1)
            collectorPayloadBytes = max(0, collectorPayloadBytes - payloadBytes)
            lock.unlock()
        }

        func rejected(payloadBytes _: Int, reason: String) {
            lock.lock()
            collectorOverflowCount += 1
            overflowReasonCounts[reason, default: 0] += 1
            lock.unlock()
        }

        func discarded(payloadBytes: Int) {
            lock.lock()
            collectorDepth = max(0, collectorDepth - 1)
            collectorPayloadBytes = max(0, collectorPayloadBytes - payloadBytes)
            lock.unlock()
        }

        func dequeued(
            payloadBytes: Int,
            enqueuedAtNanoseconds: UInt64,
            dequeuedAtNanoseconds: UInt64
        ) {
            lock.lock()
            collectorDepth = max(0, collectorDepth - 1)
            collectorPayloadBytes = max(0, collectorPayloadBytes - payloadBytes)
            let residence = Double(dequeuedAtNanoseconds >= enqueuedAtNanoseconds
                ? dequeuedAtNanoseconds - enqueuedAtNanoseconds
                : 0) / 1_000_000.0
            queueResidenceLatenciesMilliseconds.append(residence)
            inFlightPersistenceCount += 1
            lock.unlock()
        }

        func completed(
            enqueuedAtNanoseconds: UInt64,
            dequeuedAtNanoseconds: UInt64,
            persisted: Bool
        ) {
            lock.lock()
            inFlightPersistenceCount = max(0, inFlightPersistenceCount - 1)
            let now = DispatchTime.now().uptimeNanoseconds
            let latency = Double(now >= enqueuedAtNanoseconds ? now - enqueuedAtNanoseconds : 0) / 1_000_000.0
            let processing = Double(now >= dequeuedAtNanoseconds ? now - dequeuedAtNanoseconds : 0) / 1_000_000.0
            terminalProcessingLatenciesMilliseconds.append(processing)
            terminalLatenciesMilliseconds.append(latency)
            if persisted {
                persistedCount += 1
                latenciesMilliseconds.append(latency)
            } else {
                failedCount += 1
            }
            lock.unlock()
        }

        func recordFailure(category: String) {
            lock.lock()
            failureCategoryCounts[category, default: 0] += 1
            lock.unlock()
        }

        func completedBatch(
            context: Horizon2MeasurementBatchContext,
            startNanoseconds: UInt64,
            endNanoseconds: UInt64,
            terminalSuccessCount: Int,
            terminalFailureCount: Int
        ) {
            lock.lock()
            batchRecords.append(Horizon2MeasurementBatchRecord(
                observationCount: context.observationCount,
                canonicalPayloadBytes: context.canonicalPayloadBytes,
                queueDepthBeforeDequeue: context.queueDepthBeforeDequeue,
                queueDepthAfterDequeue: context.queueDepthAfterDequeue,
                firstItemEnqueuedAtMonotonicNanoseconds: context.firstItemEnqueuedAtMonotonicNanoseconds,
                batchStartMonotonicNanoseconds: startNanoseconds,
                batchEndMonotonicNanoseconds: endNanoseconds,
                persistenceDurationMilliseconds: Double(endNanoseconds >= startNanoseconds ? endNanoseconds - startNanoseconds : 0) / 1_000_000.0,
                terminalSuccessCount: terminalSuccessCount,
                terminalFailureCount: terminalFailureCount
            ))
            lock.unlock()
        }

        func snapshot() -> Horizon2MeasurementSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return Horizon2MeasurementSnapshot(
                offered: offeredCount,
                accepted: acceptedCount,
                persisted: persistedCount,
                failed: failedCount,
                collectorOverflow: collectorOverflowCount,
                pendingWriteOverflow: pendingOverflowCount,
                currentCollectorDepth: collectorDepth,
                currentPendingDepth: pendingDepth,
                inFlightPersistenceCount: inFlightPersistenceCount,
                collectorPeakDepth: collectorPeakDepth,
                pendingWritePeakDepth: pendingPeakDepth,
                collectorEncodedPayloadBytes: collectorPeakPayloadBytes,
                pendingEncodedPayloadBytes: pendingPeakPayloadBytes,
                peakCombinedEncodedPayloadBytes: peakCombinedPayloadBytes,
                acceptedDurableLatenciesMilliseconds: latenciesMilliseconds,
                acceptedTerminalLatenciesMilliseconds: terminalLatenciesMilliseconds,
                queueResidenceLatenciesMilliseconds: queueResidenceLatenciesMilliseconds,
                terminalProcessingLatenciesMilliseconds: terminalProcessingLatenciesMilliseconds,
                failureCategories: failureCategoryCounts,
                overflowReasons: overflowReasonCounts,
                batchProfile: horizon2MeasurementBatchProfile(batchRecords, persistedObservations: persistedCount),
                batchRecords: batchRecords
            )
        }
    }

    struct Horizon2MeasurementConfiguration: Sendable {
        let corpusURL: URL
        let journalURL: URL
        let outputURL: URL
        let factor: Int
        let durationSeconds: Double
        let timeScale: Double
        let disableEvidenceRuntime: Bool
        let idle: Bool
        let resetAfter: Bool
        let burstSeconds: Double
        let recoverySeconds: Double
        let residenceLimitMilliseconds: Int
        let phaseURL: URL?
        let ingressCapacity: Int

        init?(arguments: [String]) {
            func value(_ prefix: String) -> String? {
                arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count).description
            }
            guard let corpus = value("-Horizon2MeasurementCorpus="),
                  let journal = value("-Horizon2MeasurementJournal="),
                  let output = value("-Horizon2MeasurementOutput=")
            else { return nil }
            corpusURL = URL(fileURLWithPath: corpus)
            journalURL = URL(fileURLWithPath: journal)
            outputURL = URL(fileURLWithPath: output)
            factor = max(1, Int(value("-Horizon2MeasurementFactor=") ?? "1") ?? 1)
            durationSeconds = max(0, Double(value("-Horizon2MeasurementDuration=") ?? "0") ?? 0)
            timeScale = max(0, Double(value("-Horizon2MeasurementTimeScale=") ?? "0.1") ?? 0.1)
            disableEvidenceRuntime = arguments.contains("-Horizon2MeasurementDisableEvidenceRuntime")
            idle = arguments.contains("-Horizon2MeasurementIdle")
            resetAfter = arguments.contains("-Horizon2MeasurementResetAfter")
            burstSeconds = max(0, Double(value("-Horizon2MeasurementBurstSeconds=") ?? "0") ?? 0)
            recoverySeconds = max(0, Double(value("-Horizon2MeasurementRecoverySeconds=") ?? "0") ?? 0)
            residenceLimitMilliseconds = max(
                1,
                Int(value("-Horizon2MeasurementResidenceLimitMilliseconds=") ?? "(Horizon2EvidenceConfiguration.collectorQueueResidenceMaximumMilliseconds)")
                    ?? Horizon2EvidenceConfiguration.collectorQueueResidenceMaximumMilliseconds
            )
            phaseURL = value("-Horizon2MeasurementPhaseFile=").map(URL.init(fileURLWithPath:))
            ingressCapacity = max(1, Int(value("-Horizon2MeasurementIngressCapacity=") ?? "\(Horizon2EvidenceConfiguration.collectorQueueCapacity)") ?? Horizon2EvidenceConfiguration.collectorQueueCapacity)
        }
    }

    struct Horizon2MeasurementDriver {
        private struct NormalizedRecord {
            let sourceID: String
            let eventName: String
            let capturedAt: EvidenceSourceOccurrence
            let identityDigest: String?
            let status: NetworkPathStatus
            let interfaces: Set<NetworkInterfaceFact>
        }

        func run(
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime,
            journal: any EvidenceJournal
        ) async {
            var initialStableBytes = 0
            do {
                let records = try loadRecords(from: configuration.corpusURL)
                let workloadRecords = configuration.burstSeconds > 0
                    ? records.filter { Self.representativeTransitionEventNames.contains($0.eventName) }
                    : records
                let replayable = workloadRecords.compactMap { record in
                    makeRawEvent(record).map { (record, $0) }
                }
                if let sqlite = journal as? SQLiteEvidenceJournal {
                    initialStableBytes = await sqlite.retentionStatus().bytes
                }
                let expectedOffered = replayable.count * configuration.factor
                writePhase("burst-start", configuration: configuration)
                let burstStart = DispatchTime.now().uptimeNanoseconds
                var emissionIndex = 0
                let totalEmissions = replayable.count * configuration.factor
                for _ in 0 ..< configuration.factor {
                    var previousWallTime: Date?
                    for (record, raw) in replayable {
                        if configuration.burstSeconds > 0, totalEmissions > 0 {
                            let target = burstStart + UInt64(
                                (configuration.burstSeconds * 1_000_000_000)
                                    * Double(emissionIndex + 1) / Double(totalEmissions)
                            )
                            let now = DispatchTime.now().uptimeNanoseconds
                            if target > now {
                                try? await Task.sleep(nanoseconds: target - now)
                            }
                        } else if let previousWallTime, configuration.timeScale > 0 {
                            let interval = max(0, record.capturedAt.wallTime?.timeIntervalSince(previousWallTime) ?? 0)
                            let nanoseconds = UInt64(interval * configuration.timeScale * 1_000_000_000 / Double(configuration.factor))
                            if nanoseconds > 0 {
                                try? await Task.sleep(nanoseconds: nanoseconds)
                            }
                        }
                        runtime.receive(.raw(raw))
                        previousWallTime = record.capturedAt.wallTime
                        emissionIndex += 1
                    }
                }
                writePhase("injection-complete", configuration: configuration)
                if configuration.recoverySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(configuration.recoverySeconds * 1_000_000_000))
                }
                writePhase("recovery-complete", configuration: configuration)
                let drainStarted = DispatchTime.now().uptimeNanoseconds
                let deadline = drainStarted + UInt64(max(5, configuration.durationSeconds) * 1_000_000_000)
                var drainCompleted = false
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let snapshot = runtime.measurementSnapshot()
                    if snapshot.offered >= expectedOffered,
                       snapshot.accepted + snapshot.collectorOverflow == expectedOffered,
                       snapshot.currentCollectorDepth == 0,
                       snapshot.currentPendingDepth == 0,
                       snapshot.inFlightPersistenceCount == 0,
                       snapshot.accepted == snapshot.persisted + snapshot.failed
                    {
                        drainCompleted = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                guard drainCompleted else {
                    throw NSError(domain: "Horizon2Measurement", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Measurement drain timed out with accepted work outstanding.",
                    ])
                }
                writePhase("drain-complete", configuration: configuration)
                let snapshot = runtime.measurementSnapshot()
                guard snapshot.accepted == snapshot.persisted + snapshot.failed else {
                    throw NSError(domain: "Horizon2Measurement", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Accepted/persisted/failed counters did not reconcile.",
                    ])
                }
                writePhase("package-start", configuration: configuration)
                let observations = await journal.query(EvidenceJournalQuery(limit: nil, newestFirst: true))
                let overflowed = snapshot.collectorOverflow > 0 || snapshot.pendingWriteOverflow > 0 || snapshot.failed > 0
                let incident = IncidentPackage(
                    id: UUID(),
                    marker: IncidentMarker(markerID: UUID(), wallTime: .now),
                    status: overflowed ? .incomplete : .complete,
                    completedAt: .now,
                    materializedContext: .object([
                        "system": .object(["cpuUtilizationPercent": .decimal("0.00")]),
                        "battery": .object(["acConnected": .boolean(true)]),
                        "cooling": .object([:]),
                    ]),
                    observationIDs: observations.map(\.id),
                    unknowns: overflowed ? [EvidenceMissing(
                        sourceID: nil,
                        reason: .incompleteCapture,
                        explanation: snapshot.failed > 0
                            ? "Measurement replay had accepted events that failed durable persistence."
                            : "Measurement replay overflowed the bounded production ingress path."
                    )] : [],
                    failureReason: overflowed ? .incompleteCapture : nil
                )
                try await journal.finalizeIncidentCapture(incident)
                let costs = try await packageCosts(incidentID: incident.id, journal: journal)
                writePhase("package-complete", configuration: configuration)
                let journalFootprint: Horizon2MeasurementJournalFootprint?
                if let sqlite = journal as? SQLiteEvidenceJournal {
                    journalFootprint = await sqlite.measurementJournalFootprint(initialStableBytes: initialStableBytes)
                } else {
                    journalFootprint = nil
                }
                let resetResult: Horizon2MeasurementResetResult?
                if configuration.resetAfter, let sqlite = journal as? SQLiteEvidenceJournal {
                    let path = sqlite.databaseURL
                    try await sqlite.reset()
                    let fm = FileManager.default
                    resetResult = Horizon2MeasurementResetResult(
                        databaseRemoved: !fm.fileExists(atPath: path.path),
                        walRemoved: !fm.fileExists(atPath: path.path + "-wal"),
                        shmRemoved: !fm.fileExists(atPath: path.path + "-shm")
                    )
                } else {
                    resetResult = nil
                }
                let report = Horizon2MeasurementReport(
                    format: "h2-i9-3-swift-production-v1",
                    workloadClass: configuration.burstSeconds > 0
                        ? "representative_transition_burst"
                        : "hostile_mapped_stress",
                    corpusRecords: records.count,
                    replayableRecords: replayable.count,
                    collectorCapacity: configuration.ingressCapacity,
                    originalSourceEventCounts: sourceEventCounts(records),
                    replayableSourceEventCounts: sourceEventCounts(replayable.map { $0.0 }),
                    factor: configuration.factor,
                    runtimeDisabled: configuration.disableEvidenceRuntime,
                    durationSeconds: configuration.durationSeconds,
                    timeScale: configuration.timeScale,
                    burstSeconds: configuration.burstSeconds,
                    recoverySeconds: configuration.recoverySeconds,
                    residenceLimitMilliseconds: configuration.residenceLimitMilliseconds,
                    metrics: snapshot,
                    status: incident.status.rawValue,
                    packageCosts: costs,
                    journalFootprint: journalFootprint,
                    resetResult: resetResult
                )
                let data = try JSONEncoder.horizon2.encode(report)
                try FileManager.default.createDirectory(at: configuration.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: configuration.outputURL, options: .atomic)
            } catch {
                var failure: [String: Any] = [
                    "format": "h2-i9-3-swift-production-v1",
                    "error": String(describing: error),
                ]
                let snapshot = runtime.measurementSnapshot()
                if let snapshotData = try? JSONEncoder.horizon2.encode(snapshot),
                   let snapshotObject = try? JSONSerialization.jsonObject(with: snapshotData)
                {
                    failure["failureMetrics"] = snapshotObject
                }
                if let sqlite = journal as? SQLiteEvidenceJournal,
                   let footprintData = try? JSONEncoder.horizon2.encode(
                       await sqlite.measurementJournalFootprint(initialStableBytes: initialStableBytes)
                   ),
                   let footprintObject = try? JSONSerialization.jsonObject(with: footprintData)
                {
                    failure["journalFootprint"] = footprintObject
                }
                let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: configuration.outputURL, options: .atomic)
            }
        }

        private func loadRecords(from url: URL) throws -> [NormalizedRecord] {
            let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            return try lines.map { line in
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sourceID = object["source_id"] as? String,
                      let eventName = object["event_name"] as? String,
                      let wall = object["captured_at_wall"] as? String,
                      let wallTime = ISO8601DateFormatter().date(from: wall)
                else { throw NSError(domain: "Horizon2Measurement", code: 1) }
                let payload = ((object["payload"] as? [String: Any])?["payload"] as? [String: Any]) ?? [:]
                let status = NetworkPathStatus(rawValue: ((payload["status"] as? String) ?? "SATISFIED").uppercased()) ?? .satisfied
                let interfaceNames = payload["uses_interface_types"] as? [String] ?? ["other"]
                let interfaces = Set(interfaceNames.compactMap { NetworkInterfaceFact(rawValue: $0.uppercased()) })
                return NormalizedRecord(
                    sourceID: sourceID,
                    eventName: eventName,
                    capturedAt: EvidenceSourceOccurrence(
                        wallTime: wallTime,
                        continuousNanoseconds: object["captured_at_continuous_ns"] as? UInt64,
                        quality: .exact
                    ),
                    identityDigest: payload["identity_digest"] as? String,
                    status: status,
                    interfaces: interfaces.isEmpty ? [.other] : interfaces
                )
            }
        }

        private func makeRawEvent(_ record: NormalizedRecord) -> Horizon2RawEvent? {
            switch record.sourceID {
            case Horizon2SourceID.storage.rawValue:
                let kind: StorageRawEventKind
                if record.eventName.contains("disk_disappeared") {
                    kind = .diskDisappeared
                } else if record.eventName.contains("volume_mounted") {
                    kind = .volumeMounted
                } else if record.eventName.contains("volume_unmounted") {
                    kind = .volumeUnmounted
                } else {
                    kind = .diskAppeared
                }
                return .storage(StorageRawEvent(
                    kind: kind,
                    identity: StorageRawIdentity(
                        volumeName: nil,
                        filesystemPath: nil,
                        serialNumber: nil,
                        hardwareUUID: nil,
                        mediaUUID: record.identityDigest,
                        bsdName: nil,
                        isWholeDisk: true
                    ),
                    occurrence: record.capturedAt,
                    callbackToken: record.identityDigest
                ))
            case Horizon2SourceID.network.rawValue:
                let previous = NetworkRawPath(status: .unsatisfied, interfaces: [.other])
                let current = NetworkRawPath(status: record.status, interfaces: record.interfaces)
                return .network(NetworkRawTransition(previous: previous, current: current, occurrence: record.capturedAt))
            case Horizon2SourceID.power.rawValue:
                let previous = PowerRawState(externalPowerConnected: false, source: .battery, charging: false, currentCapacity: 50, maximumCapacity: 100)
                let current = PowerRawState(externalPowerConnected: true, source: .ac, charging: false, currentCapacity: 80, maximumCapacity: 100)
                return .power(PowerRawTransition(previous: previous, current: current, occurrence: record.capturedAt))
            default:
                return nil
            }
        }

        private func packageCosts(incidentID: UUID, journal: any EvidenceJournal) async throws -> Horizon2MeasurementPackageCosts {
            let assemblyStart = DispatchTime.now().uptimeNanoseconds
            let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
            let assemblyMilliseconds = milliseconds(since: assemblyStart)
            let jsonStart = DispatchTime.now().uptimeNanoseconds
            let json = try EvidencePackageJSONRenderer.render(package)
            let jsonMilliseconds = milliseconds(since: jsonStart)
            let textStart = DispatchTime.now().uptimeNanoseconds
            let text = try EvidencePackageTextRenderer.render(package)
            let textMilliseconds = milliseconds(since: textStart)
            let previewStart = DispatchTime.now().uptimeNanoseconds
            _ = try EvidenceExportPreviewModel(package: package)
            let previewMilliseconds = milliseconds(since: previewStart)
            return Horizon2MeasurementPackageCosts(
                assemblyMilliseconds: assemblyMilliseconds,
                jsonMilliseconds: jsonMilliseconds,
                textMilliseconds: textMilliseconds,
                previewMilliseconds: previewMilliseconds,
                jsonBytes: json.count,
                textBytes: text.utf8.count
            )
        }

        private func sourceEventCounts(_ records: [NormalizedRecord]) -> [String: Int] {
            records.reduce(into: [:]) { counts, record in
                counts["\(record.sourceID):\(record.eventName)", default: 0] += 1
            }
        }

        private static let representativeTransitionEventNames: Set<String> = [
            "storage.disk_appeared",
            "power.source_change",
            "network.path_update",
        ]

        private func writePhase(_ phase: String, configuration: Horizon2MeasurementConfiguration) {
            guard let phaseURL = configuration.phaseURL else { return }
            let payload = "\(phase) \(DispatchTime.now().uptimeNanoseconds) \(Date().timeIntervalSince1970)\n"
            try? FileManager.default.createDirectory(at: phaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(payload.utf8)
            if FileManager.default.fileExists(atPath: phaseURL.path) {
                do {
                    let handle = try FileHandle(forWritingTo: phaseURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    // Measurement markers are diagnostic only and must never
                    // affect the production evidence path.
                }
            } else {
                try? data.write(to: phaseURL, options: .atomic)
            }
        }

        private func milliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        }
    }

    struct Horizon2MeasurementPackageCosts: Codable, Sendable {
        let assemblyMilliseconds: Double
        let jsonMilliseconds: Double
        let textMilliseconds: Double
        let previewMilliseconds: Double
        let jsonBytes: Int
        let textBytes: Int
    }

    struct Horizon2MeasurementJournalFootprint: Codable, Sendable {
        let initialStableBytes: Int
        let appendProfile: Horizon2MeasurementAppendProfile
        let transactionHeadroom: Horizon2MeasurementTransactionHeadroom
        let finalMainBytes: Int
        let finalWALBytes: Int
        let finalSHMBytes: Int
        let finalStableBytes: Int
    }

    struct Horizon2MeasurementResetResult: Codable, Sendable {
        let databaseRemoved: Bool
        let walRemoved: Bool
        let shmRemoved: Bool
    }

    struct Horizon2MeasurementReport: Codable, Sendable {
        let format: String
        let workloadClass: String
        let corpusRecords: Int
        let replayableRecords: Int
        let collectorCapacity: Int
        let originalSourceEventCounts: [String: Int]
        let replayableSourceEventCounts: [String: Int]
        let factor: Int
        let runtimeDisabled: Bool
        let durationSeconds: Double
        let timeScale: Double
        let burstSeconds: Double
        let recoverySeconds: Double
        let residenceLimitMilliseconds: Int
        let metrics: Horizon2MeasurementSnapshot
        let status: String
        let packageCosts: Horizon2MeasurementPackageCosts
        let journalFootprint: Horizon2MeasurementJournalFootprint?
        let resetResult: Horizon2MeasurementResetResult?
    }

    private extension JSONEncoder {
        static let horizon2: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return encoder
        }()
    }

#endif
