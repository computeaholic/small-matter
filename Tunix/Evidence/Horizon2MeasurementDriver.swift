#if HORIZON2_MEASUREMENT
    import Foundation

    enum Horizon2MeasurementDriver {
        private struct NormalizedRecord {
            let sourceID: String
            let eventName: String
            let capturedAt: EvidenceSourceOccurrence
            let identityDigest: String?
            let status: NetworkPathStatus
            let interfaces: Set<NetworkInterfaceFact>
        }
    }

    private extension Horizon2MeasurementDriver {
        private struct MeasurementWorkload {
            let records: [NormalizedRecord]
            let replayable: [(NormalizedRecord, Horizon2RawEvent)]

            var expectedOffered: Int {
                replayable.count * factor
            }

            let factor: Int
        }

        func run(
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime,
            journal: any EvidenceJournal
        ) async {
            var initialStableBytes = 0
            do {
                let workload = try prepareWorkload(configuration: configuration)
                initialStableBytes = await stableBytes(in: journal)
                let snapshot = try await replay(
                    workload,
                    configuration: configuration,
                    runtime: runtime
                )
                try await finalize(
                    workload: workload,
                    snapshot: snapshot,
                    configuration: configuration,
                    journal: journal,
                    initialStableBytes: initialStableBytes
                )
            } catch {
                await writeFailure(
                    error,
                    configuration: configuration,
                    runtime: runtime,
                    journal: journal,
                    initialStableBytes: initialStableBytes
                )
            }
        }

        private func prepareWorkload(configuration: Horizon2MeasurementConfiguration) throws -> MeasurementWorkload {
            let records = try loadRecords(from: configuration.corpusURL)
            let selectedRecords = configuration.burstSeconds > 0
                ? records.filter { Self.representativeTransitionEventNames.contains($0.eventName) }
                : records
            let replayable = selectedRecords.compactMap { record in
                makeRawEvent(record).map { (record, $0) }
            }
            return MeasurementWorkload(records: records, replayable: replayable, factor: configuration.factor)
        }

        private func stableBytes(in journal: any EvidenceJournal) async -> Int {
            guard let sqlite = journal as? SQLiteEvidenceJournal else { return 0 }
            return await sqlite.retentionStatus().bytes
        }

        private func replay(
            _ workload: MeasurementWorkload,
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime
        ) async throws -> Horizon2MeasurementSnapshot {
            writePhase("burst-start", configuration: configuration)
            try await inject(workload, configuration: configuration, runtime: runtime)
            writePhase("injection-complete", configuration: configuration)
            if configuration.recoverySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(configuration.recoverySeconds * 1_000_000_000))
            }
            writePhase("recovery-complete", configuration: configuration)
            let snapshot = try await waitForDrain(
                expectedOffered: workload.expectedOffered,
                configuration: configuration,
                runtime: runtime
            )
            guard snapshot.accepted == snapshot.persisted + snapshot.failed else {
                throw NSError(domain: "Horizon2Measurement", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Accepted/persisted/failed counters did not reconcile."
                ])
            }
            return snapshot
        }

        private func inject(
            _ workload: MeasurementWorkload,
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime
        ) async throws {
            let burstStart = DispatchTime.now().uptimeNanoseconds
            let totalEmissions = workload.replayable.count * configuration.factor
            var emissionIndex = 0
            for _ in 0 ..< configuration.factor {
                var previousWallTime: Date?
                for (record, raw) in workload.replayable {
                    if configuration.burstSeconds > 0, totalEmissions > 0 {
                        let target = burstStart + UInt64(
                            configuration.burstSeconds * 1_000_000_000
                                * Double(emissionIndex + 1) / Double(totalEmissions)
                        )
                        let now = DispatchTime.now().uptimeNanoseconds
                        if target > now {
                            try? await Task.sleep(nanoseconds: target - now)
                        }
                    } else if let previousWallTime, configuration.timeScale > 0 {
                        let interval = max(0, record.capturedAt.wallTime?.timeIntervalSince(previousWallTime) ?? 0)
                        let nanoseconds = UInt64(
                            interval * configuration.timeScale * 1_000_000_000 / Double(configuration.factor)
                        )
                        if nanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: nanoseconds)
                        }
                    }
                    runtime.receive(.raw(raw))
                    previousWallTime = record.capturedAt.wallTime
                    emissionIndex += 1
                }
            }
        }

        private func waitForDrain(
            expectedOffered: Int,
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime
        ) async throws -> Horizon2MeasurementSnapshot {
            let drainStarted = DispatchTime.now().uptimeNanoseconds
            let deadline = drainStarted + UInt64(max(5, configuration.durationSeconds) * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let snapshot = runtime.measurementSnapshot()
                if snapshot.offered >= expectedOffered,
                   snapshot.accepted + snapshot.collectorOverflow == expectedOffered,
                   snapshot.currentCollectorDepth == 0,
                   snapshot.currentPendingDepth == 0,
                   snapshot.inFlightPersistenceCount == 0,
                   snapshot.accepted == snapshot.persisted + snapshot.failed {
                    writePhase("drain-complete", configuration: configuration)
                    return snapshot
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "Horizon2Measurement", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Measurement drain timed out with accepted work outstanding."
            ])
        }

        private func finalize(
            workload: MeasurementWorkload,
            snapshot: Horizon2MeasurementSnapshot,
            configuration: Horizon2MeasurementConfiguration,
            journal: any EvidenceJournal,
            initialStableBytes: Int
        ) async throws {
            writePhase("package-start", configuration: configuration)
            let observations = await journal.query(EvidenceJournalQuery(limit: nil, newestFirst: true))
            let incident = makeIncident(snapshot: snapshot, observations: observations)
            try await journal.finalizeIncidentCapture(incident)
            let costs = try await packageCosts(incidentID: incident.id, journal: journal)
            writePhase("package-complete", configuration: configuration)
            let footprint = await journalFootprint(
                journal: journal,
                initialStableBytes: initialStableBytes
            )
            let resetResult = try await resetResult(configuration: configuration, journal: journal)
            let report = Horizon2MeasurementReport(
                format: "h2-i9-3-swift-production-v1",
                workloadClass: configuration.burstSeconds > 0
                    ? "representative_transition_burst"
                    : "hostile_mapped_stress",
                corpusRecords: workload.records.count,
                replayableRecords: workload.replayable.count,
                collectorCapacity: configuration.ingressCapacity,
                originalSourceEventCounts: sourceEventCounts(workload.records),
                replayableSourceEventCounts: sourceEventCounts(workload.replayable.map { $0.0 }),
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
                journalFootprint: footprint,
                resetResult: resetResult
            )
            let data = try JSONEncoder.horizon2.encode(report)
            try FileManager.default.createDirectory(
                at: configuration.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: configuration.outputURL, options: .atomic)
        }

        private func makeIncident(
            snapshot: Horizon2MeasurementSnapshot,
            observations: [Observation]
        ) -> IncidentPackage {
            let overflowed = snapshot.collectorOverflow > 0
                || snapshot.pendingWriteOverflow > 0
                || snapshot.failed > 0
            return IncidentPackage(
                id: UUID(),
                marker: IncidentMarker(markerID: UUID(), wallTime: .now),
                status: overflowed ? .incomplete : .complete,
                completedAt: .now,
                materializedContext: .object([
                    "system": .object(["cpuUtilizationPercent": .decimal("0.00")]),
                    "battery": .object(["acConnected": .boolean(true)]),
                    "cooling": .object([:])
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
        }

        private func journalFootprint(
            journal: any EvidenceJournal,
            initialStableBytes: Int
        ) async -> Horizon2MeasurementJournalFootprint? {
            guard let sqlite = journal as? SQLiteEvidenceJournal else { return nil }
            return await sqlite.measurementJournalFootprint(initialStableBytes: initialStableBytes)
        }

        private func resetResult(
            configuration: Horizon2MeasurementConfiguration,
            journal: any EvidenceJournal
        ) async throws -> Horizon2MeasurementResetResult? {
            guard configuration.resetAfter, let sqlite = journal as? SQLiteEvidenceJournal else { return nil }
            let path = sqlite.databaseURL
            try await sqlite.reset()
            let fileManager = FileManager.default
            return Horizon2MeasurementResetResult(
                databaseRemoved: !fileManager.fileExists(atPath: path.path),
                walRemoved: !fileManager.fileExists(atPath: path.path + "-wal"),
                shmRemoved: !fileManager.fileExists(atPath: path.path + "-shm")
            )
        }

        private func writeFailure(
            _ error: Error,
            configuration: Horizon2MeasurementConfiguration,
            runtime: EvidenceRuntime,
            journal: any EvidenceJournal,
            initialStableBytes: Int
        ) async {
            var failure: [String: Any] = [
                "format": "h2-i9-3-swift-production-v1",
                "error": String(describing: error)
            ]
            let snapshot = runtime.measurementSnapshot()
            if let snapshotData = try? JSONEncoder.horizon2.encode(snapshot),
               let snapshotObject = try? JSONSerialization.jsonObject(with: snapshotData) {
                failure["failureMetrics"] = snapshotObject
            }
            if let sqlite = journal as? SQLiteEvidenceJournal,
               let footprintData = try? JSONEncoder.horizon2.encode(
                   await sqlite.measurementJournalFootprint(initialStableBytes: initialStableBytes)
               ),
               let footprintObject = try? JSONSerialization.jsonObject(with: footprintData) {
                failure["journalFootprint"] = footprintObject
            }
            let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: configuration.outputURL, options: .atomic)
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
