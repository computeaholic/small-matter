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

    func horizon2MeasurementAppendProfile(
        _ timings: [Horizon2MeasurementAppendTiming]
    ) -> Horizon2MeasurementAppendProfile {
        Horizon2MeasurementAppendProfile(
            validationEncoding: horizon2MeasurementStageStatistics(timings.map(\.validationEncodingMilliseconds)),
            capacityCheck: horizon2MeasurementStageStatistics(timings.map(\.capacityCheckMilliseconds)),
            transactionBegin: horizon2MeasurementStageStatistics(timings.map(\.transactionBeginMilliseconds)),
            subjectProvenance: horizon2MeasurementStageStatistics(timings.map(\.subjectProvenanceMilliseconds)),
            rowAttributeRedactionInsert: horizon2MeasurementStageStatistics(
                timings.map(\.rowAttributeRedactionInsertMilliseconds)
            ),
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
                persistenceDurationMilliseconds: Double(
                    endNanoseconds >= startNanoseconds ? endNanoseconds - startNanoseconds : 0
                ) / 1_000_000.0,
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
                Int(
                    value("-Horizon2MeasurementResidenceLimitMilliseconds=")
                        ?? "(Horizon2EvidenceConfiguration.collectorQueueResidenceLimitMilliseconds)"
                )
                    ?? Horizon2EvidenceConfiguration.collectorQueueResidenceLimitMilliseconds
            )
            phaseURL = value("-Horizon2MeasurementPhaseFile=").map(URL.init(fileURLWithPath:))
            ingressCapacity = max(
                1,
                Int(value("-Horizon2MeasurementIngressCapacity=") ??
                    "\(Horizon2EvidenceConfiguration.collectorQueueCapacity)")
                    ?? Horizon2EvidenceConfiguration.collectorQueueCapacity
            )
        }
    }

#endif
