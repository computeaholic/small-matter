// swiftlint:disable line_length
// swiftlint:disable trailing_comma
// swiftlint:disable file_length type_body_length
import Foundation
import SQLite3
@testable import Tunix
import XCTest

final class Horizon2SQLiteJournalTests: XCTestCase {
    func testBoundedNewestFirstQueryUsesTimeIndex() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let first = makeObservation()
        let second = Observation(
            id: UUID(),
            domain: first.domain,
            eventKind: first.eventKind,
            sourceID: first.sourceID,
            subject: first.subject,
            provenance: first.provenance,
            time: EvidenceTime(
                observedWallTime: first.time.observedWallTime.addingTimeInterval(60),
                continuousNanoseconds: 20,
                processUptimeNanoseconds: 30,
                processRunID: first.time.processRunID,
                bootSessionID: first.time.bootSessionID,
                localSequence: first.time.localSequence + 1,
                sourceTimestampQuality: .exact,
                orderingDomain: first.time.orderingDomain,
                sourceOccurrence: first.time.sourceOccurrence,
                correlationEpochID: first.time.correlationEpochID
            ),
            currentState: first.currentState,
            attributes: first.attributes,
            sensitivity: first.sensitivity
        )
        try await journal.append(first)
        try await journal.append(second)

        let result = await journal.query(EvidenceJournalQuery(limit: 1, newestFirst: true))
        let indexes = await journal.schemaIndexNames()
        let plan = await journal.explainQueryPlan(EvidenceJournalQuery(limit: 1, newestFirst: true))
        XCTAssertEqual(result.map(\.id), [second.id])
        XCTAssertTrue(indexes.contains("observations_by_time"))
        XCTAssertFalse(plan.isEmpty)
    }

    func testFreshSchemaRoundTripsObservationAndPreservesEpoch() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let observation = makeObservation()

        try await journal.append(observation)

        let fetched = await journal.observation(id: observation.id)
        let storageIDs = await journal.query(EvidenceJournalQuery(sourceID: .storage)).map(\.id)
        let tables = await journal.schemaTableNames()
        XCTAssertEqual(fetched, observation)
        XCTAssertEqual(storageIDs, [observation.id])
        XCTAssertTrue(tables.contains("observations"))
        XCTAssertTrue(tables.contains("inference_contradictions"))
        let indexes = await journal.schemaIndexNames()
        XCTAssertTrue(indexes.contains("observations_by_time"))
        XCTAssertTrue(indexes.contains("observations_by_source_time"))
        let plan = await journal.explainQueryPlan(EvidenceJournalQuery(start: observation.time.observedWallTime, sourceID: .storage))
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(observation.time.correlationEpochID, fetched?.time.correlationEpochID)
    }

    func testRuntimePersistsNormalizedAdapterEventAndReopens() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let clock = FixedEvidenceClock(wallTime: Date(timeIntervalSince1970: 1_700_000_100), continuousNanoseconds: 100, processUptimeNanoseconds: 100)
        let runtime = EvidenceRuntime(clock: clock, journal: journal, adapterFactory: { _ in [] })
        runtime.start()
        let raw = StorageRawEvent(
            kind: .diskAppeared,
            identity: StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "qualified-media", bsdName: nil, isWholeDisk: true),
            occurrence: EvidenceSourceOccurrence(wallTime: clock.reading().wallTime, continuousNanoseconds: 100, quality: .exact),
            callbackToken: nil
        )
        let observation = await runtime.ingest(.storage(raw))
        runtime.stop()

        XCTAssertNotNil(observation)
        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let persistedObservation = try XCTUnwrap(observation)
        let fetched = await reopened.observation(id: persistedObservation.id)
        XCTAssertEqual(fetched, observation)
    }

    func testDuplicateIsIdempotentAndMismatchIsRejected() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observation = makeObservation()

        try await journal.append(observation)
        try await journal.append(observation)
        var changed = observation
        changed = Observation(
            id: observation.id,
            domain: observation.domain,
            eventKind: observation.eventKind,
            sourceID: observation.sourceID,
            subject: observation.subject,
            provenance: observation.provenance,
            time: observation.time,
            availability: .unknown(.notObserved),
            currentState: observation.currentState,
            sensitivity: observation.sensitivity
        )

        do {
            try await journal.append(changed)
            XCTFail("A changed payload must not replace an immutable observation")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .observationPayloadMismatch)
        }
        let observations = await journal.query(EvidenceJournalQuery())
        XCTAssertEqual(observations.count, 1)
    }

    func testAppendBatchIsAtomicWhenOnePayloadMismatches() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let existing = makeObservation()
        let newObservation = makeObservation(id: UUID())
        var mismatched = existing
        mismatched = Observation(
            id: existing.id,
            domain: existing.domain,
            eventKind: existing.eventKind,
            sourceID: existing.sourceID,
            subject: existing.subject,
            provenance: existing.provenance,
            time: existing.time,
            availability: .unknown(.notObserved),
            currentState: existing.currentState,
            attributes: existing.attributes,
            sensitivity: existing.sensitivity
        )

        try await journal.append(existing)
        do {
            try await journal.appendBatch([mismatched, newObservation])
            XCTFail("A mismatched member must reject the complete batch")
        } catch {
            guard case .observationPayloadMismatch = error as? EvidenceJournalError else {
                return XCTFail("Unexpected batch error: \(error)")
            }
        }

        let rejected = await journal.observation(id: newObservation.id)
        let observations = await journal.query(EvidenceJournalQuery()).map(\.id)
        XCTAssertNil(rejected)
        XCTAssertEqual(observations, [existing.id])
    }

    func testAppendBatchAcceptsSevenOrdinaryObservations() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observations = (0 ..< 7).map { offset in
            makeObservation(id: UUID(), extraAttribute: .string("ordinary-\(offset)"))
        }

        try await journal.appendBatch(observations)

        let persisted = await journal.query(EvidenceJournalQuery())
        XCTAssertEqual(persisted.count, 7)
    }

    func testAppendBatchRejectsAggregateLargePayloadBeforeMutation() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let ordinary = (0 ..< 6).map { _ in makeObservation(id: UUID()) }
        let large = makeObservation(id: UUID(), extraAttribute: .string(String(repeating: "L", count: 300_000)))
        let largeCanonicalBytes = try large.deterministicData().count
        XCTAssertGreaterThan(largeCanonicalBytes, Horizon2EvidenceConfiguration.maximumBatchPayloadBytes)
        XCTAssertFalse(Horizon2EvidenceConfiguration.batchFits(count: 7, canonicalPayloadBytes: largeCanonicalBytes))

        do {
            try await journal.appendBatch([large] + ordinary)
            XCTFail("An aggregate payload above the batch bound must be rejected before BEGIN")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .oversizedRecord)
        }

        let persisted = await journal.query(EvidenceJournalQuery())
        XCTAssertTrue(persisted.isEmpty)
    }

    func testAppendBatchRejectsSeveralLargeObservationsBeforeMutation() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observations = (0 ..< 3).map { _ in
            makeObservation(id: UUID(), extraAttribute: .string(String(repeating: "S", count: 200_000)))
        }
        XCTAssertGreaterThan(try observations[0].deterministicData().count, Horizon2EvidenceConfiguration.maximumBatchPayloadBytes / 2)

        do {
            try await journal.appendBatch(observations)
            XCTFail("Several large observations must be rejected before BEGIN")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .oversizedRecord)
        }

        let persisted = await journal.query(EvidenceJournalQuery())
        XCTAssertTrue(persisted.isEmpty)
    }

    func testAppendBatchDuplicateIsIdempotent() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observations = [makeObservation(id: UUID()), makeObservation(id: UUID())]

        try await journal.appendBatch(observations)
        try await journal.appendBatch(observations)

        let persisted = await journal.query(EvidenceJournalQuery())
        XCTAssertEqual(persisted.count, 2)
    }

    func testAppendBatchHeadroomRejectsBeforeMutation() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(
            databaseURL: root.appendingPathComponent("horizon2.sqlite"),
            transactionalHeadroomBytes: 8192
        )
        let observations = [makeObservation(id: UUID()), makeObservation(id: UUID())]
        var canonicalBytes = 0
        for observation in observations {
            canonicalBytes += try observation.deterministicData().count
        }
        XCTAssertTrue(canonicalBytes + observations.count * Horizon2EvidenceConfiguration.batchFixedOverheadBytes > 8192)

        do {
            try await journal.appendBatch(observations)
            XCTFail("The aggregate transaction headroom guard must reject before BEGIN")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .oversizedRecord)
        }

        let persisted = await journal.query(EvidenceJournalQuery())
        XCTAssertTrue(persisted.isEmpty)
    }

    func testProductionAndMeasurementBatchPolicyShareTheSameBounds() {
        XCTAssertTrue(Horizon2EvidenceConfiguration.batchFits(count: 7, canonicalPayloadBytes: 7 * 4096))
        XCTAssertFalse(Horizon2EvidenceConfiguration.batchFits(count: 8, canonicalPayloadBytes: 8 * 4096))
        XCTAssertFalse(Horizon2EvidenceConfiguration.batchFits(count: 2, canonicalPayloadBytes: 257 * 1024))
        XCTAssertEqual(Horizon2EvidenceConfiguration.maximumBatchCount, 7)
        XCTAssertEqual(Horizon2EvidenceConfiguration.maximumBatchPayloadBytes, 256 * 1024)
    }

    func testAppendBatchReopensAfterBoundedCheckpointWithProtectedSidecars() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let first = makeObservation()
        let second = makeObservation(id: UUID())
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)

        try await journal.appendBatch([first, second])
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        XCTAssertGreaterThan(fileSize(walURL), 0)
        XCTAssertEqual(filePermissions(databaseURL), 0o600)
        if FileManager.default.fileExists(atPath: walURL.path) {
            XCTAssertEqual(filePermissions(walURL), 0o600)
        }
        try await journal.checkpointForTesting()

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let observations = await reopened.query(EvidenceJournalQuery()).map(\.id)
        XCTAssertEqual(Set(observations), Set([first.id, second.id]))
        let status = await reopened.retentionStatus()
        XCTAssertLessThanOrEqual(status.bytes, Horizon2EvidenceConfiguration.maximumJournalBytes)
    }

    func testUnclassifiedStructuredValueFailsClosedBeforeWrite() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observation = makeObservation(sensitivity: .init())

        do {
            try await journal.append(observation)
            XCTFail("The empty registry must not silently classify structured values as safe")
        } catch {
            guard case .invalidSensitivity = error as? EvidenceJournalError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let observations = await journal.query(EvidenceJournalQuery())
        XCTAssertTrue(observations.isEmpty)
    }

    func testHealthAndIncidentMembershipPersistAcrossReopen() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let observation = makeObservation()
        let incidentID = UUID()
        let record = EvidenceSourceHealthRecord(id: UUID(), sourceID: .storage, event: .sourceUnavailable, reason: .incompleteCapture, observedAt: observation.time.observedWallTime, detail: "bounded test overflow")

        do {
            let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
            try await journal.append(observation)
            try await journal.recordSourceHealth(record)
            try await journal.recordIncidentMembership(incidentID: incidentID, observationIDs: [observation.id])
        }

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let health = await reopened.sourceHealth()
        let membership = await reopened.incidentObservationIDs(incidentID: incidentID)
        let fetched = await reopened.observation(id: observation.id)
        XCTAssertEqual(health, [record])
        XCTAssertEqual(membership, [observation.id])
        XCTAssertEqual(fetched, observation)
    }

    func testIncidentDeletionLeavesObservationAvailable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observation = makeObservation()
        try await journal.append(observation)
        let incident = IncidentPackage(
            id: UUID(),
            marker: IncidentMarker(observationID: observation.id, wallTime: observation.time.observedWallTime, localSequence: observation.time.localSequence),
            status: .complete,
            completedAt: observation.time.observedWallTime,
            materializedContext: .object(["test": .string("context")]),
            observationIDs: [observation.id]
        )

        try await journal.persist(incident: incident)
        let persisted = await journal.incident(id: incident.id)
        XCTAssertEqual(persisted, incident)
        try await journal.deleteIncident(id: incident.id)
        let deleted = await journal.incident(id: incident.id)
        let retained = await journal.observation(id: observation.id)
        XCTAssertNil(deleted)
        XCTAssertEqual(retained, observation)
    }

    func testFutureSchemaAndCorruptDatabaseFailWithoutReplacement() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let futureURL = root.appendingPathComponent("future.sqlite")
        var futureDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(futureURL.path, &futureDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(futureDB, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(futureDB)
        XCTAssertThrowsError(try SQLiteEvidenceJournal(databaseURL: futureURL)) { error in
            XCTAssertEqual(error as? EvidenceJournalError, .incompatibleSchema)
        }

        let corruptURL = root.appendingPathComponent("corrupt.sqlite")
        try Data("not a sqlite database".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try SQLiteEvidenceJournal(databaseURL: corruptURL))
        XCTAssertEqual(try Data(contentsOf: corruptURL), Data("not a sqlite database".utf8))
    }

    func testResetRemovesOnlyJournalFiles() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let unrelated = root.appendingPathComponent("settings.json")
        try Data("keep".utf8).write(to: unrelated)
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        try await journal.append(makeObservation())

        try await journal.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        do {
            try await journal.append(makeObservation())
            XCTFail("A reset journal must remain closed")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .unavailable)
        }
    }

    func testAppendCapRejectionLeavesNoNewObservationAndPreservesOlderEvidence() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let older = makeObservation(observedAt: Date(), id: UUID())
        try await journal.append(older)
        await journal.setTestMaximumJournalBytes(1)
        let rejected = makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID())

        do {
            try await journal.append(rejected)
            XCTFail("The configured cap must reject the second append")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .capacityUnavailable)
        }
        let rejectedObservation = await journal.observation(id: rejected.id)
        let olderObservation = await journal.observation(id: older.id)
        let foreignKeyViolations = await journal.foreignKeyViolationsForTesting()
        XCTAssertNil(rejectedObservation)
        XCTAssertEqual(olderObservation?.id, older.id)
        XCTAssertTrue(foreignKeyViolations.isEmpty)
    }

    func testRejectedAppendReclaimsPhysicalFootprintAndKeepsReadsAvailable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let older = makeObservation(observedAt: Date(), id: UUID())
        try await journal.append(older)
        let before = await journal.retentionStatus().bytes
        let rejected = makeObservation(
            observedAt: Date(timeIntervalSinceNow: 1),
            id: UUID(),
            extraAttribute: .string(String(repeating: "c", count: 40000))
        )
        let canonicalBytes = try rejected.deterministicData().count
        await journal.setTestMaximumJournalBytes(before + canonicalBytes + 8192)

        do {
            try await journal.append(rejected)
            XCTFail("The post-commit physical cap check must reject the mutation")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .capacityUnavailable)
        }

        let status = await journal.retentionStatus()
        let rejectedObservation = await journal.observation(id: rejected.id)
        let olderObservation = await journal.observation(id: older.id)
        let foreignKeyViolations = await journal.foreignKeyViolationsForTesting()
        XCTAssertLessThanOrEqual(status.bytes, before + canonicalBytes + 8192)
        XCTAssertNil(rejectedObservation)
        XCTAssertEqual(olderObservation?.id, older.id)
        XCTAssertTrue(foreignKeyViolations.isEmpty)
    }

    func testCapacityUnavailableRecoversAfterRetentionReclaimsFootprint() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        try await journal.append(makeObservation(observedAt: Date(), id: UUID()))
        let currentBytes = await journal.retentionStatus().bytes
        await journal.setTestMaximumJournalBytes(currentBytes + 1_000_000)
        await journal.forceCapacityUnavailableForTesting()

        let status = try await journal.performRetention(now: Date())
        XCTAssertEqual(status.availability, .available)
        try await journal.append(makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID()))
        let recoveredStatus = await journal.retentionStatus()
        XCTAssertEqual(recoveredStatus.availability, .available)
    }

    func testExplicitCapacityRecoveryCompactsUnprotectedHistoryAndPreservesProtectedEvidence() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let ordinary = makeObservation(observedAt: Date(), id: UUID())
        let protectedObservation = makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID())
        try await journal.append(ordinary)
        try await journal.append(protectedObservation)
        let protectedIncident = makeIncident(for: protectedObservation, completedAt: Date())
        try await journal.persist(incident: protectedIncident, retentionProtected: true)
        let currentBytes = await journal.retentionStatus().bytes
        await journal.setTestMaximumJournalBytes(currentBytes + 1_000_000)
        await journal.forceCapacityUnavailableForTesting()

        let result = try await journal.clearUnprotectedHistory()

        XCTAssertEqual(result.observationsDeleted, 1)
        XCTAssertEqual(result.finalStatus.availability, .available)
        let remainingOrdinary = await journal.observation(id: ordinary.id)
        let remainingProtected = await journal.observation(id: protectedObservation.id)
        let remainingIncident = await journal.incident(id: protectedIncident.id)
        XCTAssertNil(remainingOrdinary)
        XCTAssertNotNil(remainingProtected)
        XCTAssertNotNil(remainingIncident)
        try await journal.append(makeObservation(observedAt: Date(timeIntervalSinceNow: 2), id: UUID()))
    }

    func testProtectedEvidenceKeepsCapacityUnavailable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let observation = makeObservation(observedAt: Date())
        try await journal.append(observation)
        let incident = makeIncident(for: observation, completedAt: Date())
        try await journal.persist(incident: incident, retentionProtected: true)
        await journal.setTestMaximumJournalBytes(1)
        await journal.forceCapacityUnavailableForTesting()

        let status = try await journal.performRetention(now: Date())
        XCTAssertEqual(status.availability, .capacityUnavailable)
        let finalStatus = await journal.retentionStatus()
        let retainedIncident = await journal.incident(id: incident.id)
        XCTAssertEqual(finalStatus.availability, .capacityUnavailable)
        XCTAssertNotNil(retainedIncident)
    }

    func testFootprintAccountsForDatabaseWALAndSHMAndCheckpointShrinksWAL() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        try await journal.append(makeObservation(observedAt: Date()))

        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &rawDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close_v2(rawDB) }
        XCTAssertEqual(sqlite3_exec(rawDB, "BEGIN IMMEDIATE; UPDATE schema_metadata SET value='WAL_SENTINEL' WHERE key='journal_created_at'; COMMIT;", nil, nil, nil), SQLITE_OK)

        let beforeCheckpoint = await journal.retentionStatus().bytes
        let dbBytes = fileSize(databaseURL)
        let walBytes = fileSize(URL(fileURLWithPath: databaseURL.path + "-wal"))
        let shmBytes = fileSize(URL(fileURLWithPath: databaseURL.path + "-shm"))
        XCTAssertGreaterThan(dbBytes, 0)
        XCTAssertEqual(beforeCheckpoint, dbBytes + walBytes + shmBytes)
        try await journal.checkpointForTesting()
        let afterCheckpoint = await journal.retentionStatus()
        XCTAssertLessThanOrEqual(afterCheckpoint.bytes, beforeCheckpoint)
        XCTAssertLessThanOrEqual(afterCheckpoint.bytes, Horizon2EvidenceConfiguration.maximumJournalBytes)
    }

    func testTransactionalHeadroomRejectsSingleOversizedRecord() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(
            databaseURL: root.appendingPathComponent("horizon2.sqlite"),
            transactionalHeadroomBytes: 128
        )
        let oversized = makeObservation(extraAttribute: .string(String(repeating: "x", count: 4096)))

        do {
            try await journal.append(oversized)
            XCTFail("The oversized record must be rejected")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .oversizedRecord)
        }
        let persistedOversized = await journal.observation(id: oversized.id)
        XCTAssertNil(persistedOversized)
    }

    func testRepeatedWritesRemainWithinInjectedCap() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let initial = await journal.retentionStatus().bytes
        await journal.setTestMaximumJournalBytes(initial + 350_000)
        var accepted = 0
        for offset in 0 ..< 40 {
            do {
                try await journal.append(makeObservation(observedAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(offset)), id: UUID(), extraAttribute: .string(String(repeating: "w", count: 2000))))
                accepted += 1
            } catch EvidenceJournalError.capacityUnavailable {
                break
            }
        }
        XCTAssertGreaterThan(accepted, 0)
        let status = await journal.retentionStatus()
        XCTAssertLessThanOrEqual(status.bytes, initial + 350_000)
        XCTAssertNotEqual(status.availability, .unavailable)
    }

    func testDefaultAgeAndReferencedObservationRetentionMatrix() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"), retentionBatchSize: 2)
        let expired = makeObservation(observedAt: Date(timeIntervalSinceNow: -8 * 86400), id: UUID())
        let recent = makeObservation(observedAt: Date(timeIntervalSinceNow: -86400), id: UUID())
        let referenced = makeObservation(observedAt: Date(timeIntervalSinceNow: -8 * 86400), id: UUID())
        try await journal.append(expired)
        try await journal.append(recent)
        try await journal.append(referenced)
        let incidentID = UUID()
        try await journal.recordIncidentMembership(incidentID: incidentID, observationIDs: [referenced.id])

        _ = try await journal.performRetention(now: Date())
        let expiredResult = await journal.observation(id: expired.id)
        let recentResult = await journal.observation(id: recent.id)
        let referencedResult = await journal.observation(id: referenced.id)
        XCTAssertNil(expiredResult)
        XCTAssertEqual(recentResult?.id, recent.id)
        XCTAssertEqual(referencedResult?.id, referenced.id)
        let retentionForeignKeys = await journal.foreignKeyViolationsForTesting()
        XCTAssertTrue(retentionForeignKeys.isEmpty)
        try await journal.deleteIncident(id: incidentID)
        _ = try await journal.performRetention(now: Date())
        let deletedReferenced = await journal.observation(id: referenced.id)
        XCTAssertNil(deletedReferenced)
    }

    func testMaximumIncidentAgeAndProtectedIncidentRetention() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"), retentionBatchSize: 1)
        let oldObservation = makeObservation(observedAt: Date(timeIntervalSinceNow: -31 * 86400), id: UUID())
        let protectedObservation = makeObservation(observedAt: Date(timeIntervalSinceNow: -31 * 86400), id: UUID())
        try await journal.append(oldObservation)
        try await journal.append(protectedObservation)
        let oldIncident = makeIncident(for: oldObservation, completedAt: Date(timeIntervalSinceNow: -31 * 86400))
        let protectedIncident = makeIncident(for: protectedObservation, completedAt: Date(timeIntervalSinceNow: -31 * 86400))
        try await journal.persist(incident: oldIncident)
        try await journal.persist(incident: protectedIncident, retentionProtected: true)

        _ = try await journal.performRetention(now: Date())
        let oldResult = await journal.incident(id: oldIncident.id)
        let protectedResult = await journal.incident(id: protectedIncident.id)
        let incidentForeignKeys = await journal.foreignKeyViolationsForTesting()
        XCTAssertNil(oldResult)
        XCTAssertNotNil(protectedResult)
        XCTAssertTrue(incidentForeignKeys.isEmpty)
    }

    func testExpiredIncidentDeletionUsesMultipleBoundedBatches() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"), retentionBatchSize: 2)
        var incidents: [UUID] = []
        for offset in 0 ..< 7 {
            let observation = makeObservation(observedAt: Date(timeIntervalSinceNow: -31 * 86400 - Double(offset)), id: UUID())
            try await journal.append(observation)
            let incident = makeIncident(for: observation, completedAt: Date(timeIntervalSinceNow: -31 * 86400 - Double(offset)), id: UUID())
            incidents.append(incident.id)
            try await journal.persist(incident: incident)
        }
        let result = try await journal.performRetention(now: Date())
        XCTAssertEqual(result.protectedIncidentCount, 0)
        for incidentID in incidents {
            let retained = await journal.incident(id: incidentID)
            XCTAssertNil(retained)
        }
        let batchForeignKeys = await journal.foreignKeyViolationsForTesting()
        XCTAssertTrue(batchForeignKeys.isEmpty)
    }

    func testOldestEligibleIncidentEvictsBeforeNewerUnderBytePressure() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let olderObservation = makeObservation(observedAt: Date(), id: UUID(), extraAttribute: .string(String(repeating: "o", count: 10000)))
        let newerObservation = makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID(), extraAttribute: .string(String(repeating: "n", count: 10000)))
        try await journal.append(olderObservation)
        try await journal.append(newerObservation)
        let olderIncident = makeIncident(for: olderObservation, completedAt: Date(timeIntervalSinceNow: -2), id: UUID(), contextSize: 500_000)
        let newerIncident = makeIncident(for: newerObservation, completedAt: Date(timeIntervalSinceNow: -1), id: UUID(), contextSize: 20000)
        try await journal.persist(incident: olderIncident)
        try await journal.persist(incident: newerIncident)
        let before = await journal.retentionStatus().bytes
        await journal.setTestMaximumJournalBytes(before - 100_000)

        _ = try await journal.performRetention(now: Date())
        let evictedOlder = await journal.incident(id: olderIncident.id)
        let retainedNewer = await journal.incident(id: newerIncident.id)
        let evictionForeignKeys = await journal.foreignKeyViolationsForTesting()
        XCTAssertNil(evictedOlder)
        XCTAssertNotNil(retainedNewer)
        XCTAssertTrue(evictionForeignKeys.isEmpty)
    }

    func testBusyLockIsBoundedAndRecovers() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let existing = makeObservation(observedAt: Date(), id: UUID())
        try await journal.append(existing)
        var lockDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &lockDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let started = Date()
        do {
            try await journal.append(makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID()))
            XCTFail("The held lock must reject the append")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .busy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(sqlite3_exec(lockDB, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(lockDB)
        try await journal.append(makeObservation(observedAt: Date(timeIntervalSinceNow: 2), id: UUID()))
        let existingAfterLock = await journal.observation(id: existing.id)
        XCTAssertEqual(existingAfterLock?.id, existing.id)
    }

    func testDiskFullIsAtomicAndPriorEvidenceRemainsReadable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let existing = makeObservation(observedAt: Date())
        try await journal.append(existing)
        let pageCount = try await journal.pageCountForTesting()
        try await journal.setTestMaximumPageCount(pageCount + 1)
        let candidate = makeObservation(observedAt: Date(timeIntervalSinceNow: 1), id: UUID(), extraAttribute: .string(String(repeating: "d", count: 500_000)))

        do {
            try await journal.append(candidate)
            XCTFail("The page limit must reject the large transaction")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .capacityUnavailable)
        }
        let candidateAfterFull = await journal.observation(id: candidate.id)
        let existingAfterFull = await journal.observation(id: existing.id)
        let fullForeignKeys = await journal.foreignKeyViolationsForTesting()
        XCTAssertNil(candidateAfterFull)
        XCTAssertEqual(existingAfterFull?.id, existing.id)
        XCTAssertTrue(fullForeignKeys.isEmpty)
    }

    func testMigrationRollbackMetadataMismatchAndNoDowngrade() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failedURL = root.appendingPathComponent("failed.sqlite")
        XCTAssertThrowsError(try SQLiteEvidenceJournal(databaseURL: failedURL, injectMigrationFailure: true))
        XCTAssertEqual(try scalarFromDatabase(failedURL, sql: "PRAGMA user_version"), "0")
        XCTAssertEqual(try scalarFromDatabase(failedURL, sql: "SELECT count(*) FROM sqlite_master WHERE name='observations'"), "0")

        let mismatchURL = root.appendingPathComponent("mismatch.sqlite")
        _ = try SQLiteEvidenceJournal(databaseURL: mismatchURL)
        XCTAssertEqual(try execDatabase(mismatchURL, sql: "UPDATE schema_metadata SET value='9' WHERE key='schema_version'"), SQLITE_OK)
        XCTAssertThrowsError(try SQLiteEvidenceJournal(databaseURL: mismatchURL)) { error in
            XCTAssertEqual(error as? EvidenceJournalError, .schemaMetadataMismatch)
        }

        let downgradeURL = root.appendingPathComponent("downgrade.sqlite")
        _ = try SQLiteEvidenceJournal(databaseURL: downgradeURL)
        XCTAssertEqual(try execDatabase(downgradeURL, sql: "PRAGMA user_version=0"), SQLITE_OK)
        XCTAssertThrowsError(try SQLiteEvidenceJournal(databaseURL: downgradeURL))
        XCTAssertEqual(try scalarFromDatabase(downgradeURL, sql: "SELECT count(*) FROM sqlite_master WHERE name='observations'"), "1")
    }

    func testQueryPlansUseTimeSourceAndSubjectIndexes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        try await journal.append(makeObservation(observedAt: Date()))
        let sourcePlan = await journal.explainQueryPlan(EvidenceJournalQuery(start: Date(timeIntervalSinceNow: -1), sourceID: .storage))
        let subjectPlan = await journal.explainQueryPlan(EvidenceJournalQuery(start: Date(timeIntervalSinceNow: -1), subjectIdentityDigest: "fixture-digest"))
        let timePlan = await journal.explainQueryPlan(EvidenceJournalQuery(start: Date(timeIntervalSinceNow: -1)))
        XCTAssertTrue(sourcePlan.contains(where: { $0.contains("observations_by_source_time") }))
        XCTAssertTrue(subjectPlan.contains(where: { $0.contains("subjects_by_identity") || $0.contains("observations_by_subject_time") }))
        XCTAssertTrue(timePlan.contains(where: { $0.contains("observations_by_time") }))
    }

    func testStorageNormalizationAndHealthPrivacySentinelsDoNotPersistRaw() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let clock = FixedEvidenceClock(wallTime: Date(), continuousNanoseconds: 10, processUptimeNanoseconds: 10)
        let runtime = EvidenceRuntime(clock: clock, journal: journal, adapterFactory: { _ in [] })
        runtime.start()
        let raw = StorageRawEvent(
            kind: .diskAppeared,
            identity: StorageRawIdentity(volumeName: "JEFF_PRIVATE_VOLUME_SENTINEL", filesystemPath: "/Users/private-user/secret-path", serialNumber: "SERIAL_SENTINEL_123", hardwareUUID: "HARDWARE_UUID_SENTINEL", mediaUUID: "MY_PRIVATE_SSID", bsdName: "AA:BB:CC:DD:EE:FF", isWholeDisk: true),
            occurrence: EvidenceSourceOccurrence(wallTime: clock.reading().wallTime, continuousNanoseconds: 10, quality: .exact),
            callbackToken: nil
        )
        let observation = await runtime.ingest(.storage(raw))
        runtime.stop()
        XCTAssertNotNil(observation)
        let detail = EvidenceSourceHealthRecord(id: UUID(), sourceID: .storage, event: .sourceUnavailable, reason: .sourceUnavailable, observedAt: Date(), detail: "192.0.2.123 PRIVATE_USERNAME_SENTINEL")
        do {
            try await journal.recordSourceHealth(detail)
            XCTFail("Sensitive source-health detail must be rejected")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .invalidSensitivity("health.detail"))
        }
        let bytes = databaseBytes(databaseURL)
        for sentinel in ["JEFF_PRIVATE_VOLUME_SENTINEL", "/Users/private-user/secret-path", "SERIAL_SENTINEL_123", "HARDWARE_UUID_SENTINEL", "MY_PRIVATE_SSID", "AA:BB:CC:DD:EE:FF", "192.0.2.123", "PRIVATE_USERNAME_SENTINEL"] {
            XCTAssertFalse(bytes.contains(Data(sentinel.utf8)), "Raw sentinel leaked: \(sentinel)")
        }
        let digest = observation?.provenance.rawReferenceDigest
        XCTAssertNotNil(digest)
        XCTAssertFalse(bytes.contains(Data("JEFF_PRIVATE_VOLUME_SENTINEL".utf8)))
    }

    func testSourceHealthChurnRemainsRowAndByteBounded() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteEvidenceJournal(databaseURL: root.appendingPathComponent("horizon2.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_100_000)

        for index in 0 ..< 4100 {
            try await journal.recordSourceHealth(EvidenceSourceHealthRecord(
                id: UUID(),
                sourceID: .storage,
                event: .sourceUnavailable,
                reason: .sourceUnavailable,
                observedAt: start.addingTimeInterval(Double(index)),
                detail: nil
            ))
        }

        let records = await journal.sourceHealth()
        let status = await journal.retentionStatus()
        XCTAssertLessThanOrEqual(records.count, 4096)
        XCTAssertGreaterThan(records.count, 0)
        XCTAssertEqual(status.availability, .available)
        XCTAssertLessThanOrEqual(status.bytes, Horizon2EvidenceConfiguration.maximumJournalBytes)
    }

    @MainActor
    func testAsyncBootstrapDelaysRuntimeUntilJournalResolution() async throws {
        let deferred = DeferredEvidenceJournal()
        let gate = JournalBootstrapGate()
        let adapter = BootstrapProbeAdapter()
        let runtime = EvidenceRuntime(journal: deferred, adapterFactory: { _ in [adapter] })
        let delegate = SmallMatterAppDelegate(
            evidenceRuntime: runtime,
            deferredJournal: deferred,
            journalBootstrap: { await gate.wait() }
        )

        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test.launch")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(adapter.hasStarted)
        XCTAssertFalse(runtime.isRunning)

        await gate.release(InMemoryEvidenceJournal())
        for _ in 0 ..< 20 where !adapter.hasStarted {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(adapter.hasStarted)
        XCTAssertEqual(adapter.startCount, 1)
        XCTAssertTrue(runtime.isRunning)
        delegate.applicationWillTerminate(Notification(name: Notification.Name("test.terminate")))
        XCTAssertTrue(adapter.hasStopped)
    }

    @MainActor
    func testAsyncBootstrapFailureIsFailClosedAndPendingTerminationIsSafe() async throws {
        let deferred = DeferredEvidenceJournal()
        let failingAdapter = BootstrapProbeAdapter()
        let failingRuntime = EvidenceRuntime(journal: deferred, adapterFactory: { _ in [failingAdapter] })
        let failingDelegate = SmallMatterAppDelegate(
            evidenceRuntime: failingRuntime,
            deferredJournal: deferred,
            journalBootstrap: { UnavailableEvidenceJournal(failure: .unavailable) }
        )
        failingDelegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test.launch.failure")))
        for _ in 0 ..< 20 where !failingAdapter.hasStarted {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(failingAdapter.hasStarted)
        let failureStatus = await deferred.retentionStatus()
        XCTAssertEqual(failureStatus.availability, .unavailable)
        failingDelegate.applicationWillTerminate(Notification(name: Notification.Name("test.terminate.failure")))

        let pendingDeferred = DeferredEvidenceJournal()
        let pendingGate = JournalBootstrapGate()
        let pendingAdapter = BootstrapProbeAdapter()
        let pendingRuntime = EvidenceRuntime(journal: pendingDeferred, adapterFactory: { _ in [pendingAdapter] })
        let pendingDelegate = SmallMatterAppDelegate(
            evidenceRuntime: pendingRuntime,
            deferredJournal: pendingDeferred,
            journalBootstrap: { await pendingGate.wait() }
        )
        pendingDelegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test.launch.pending")))
        try await Task.sleep(nanoseconds: 50_000_000)
        pendingDelegate.applicationWillTerminate(Notification(name: Notification.Name("test.terminate.pending")))
        await pendingGate.release(InMemoryEvidenceJournal())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pendingAdapter.hasStarted)
        XCTAssertFalse(pendingRuntime.isRunning)
    }

    func testDatabaseSidecarsAndProductionDirectoryUseOwnerOnlyPermissions() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("horizon2.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        try await journal.append(makeObservation(observedAt: Date()))
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &rawDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawDB, "BEGIN IMMEDIATE; UPDATE schema_metadata SET value='PERMISSION_SENTINEL' WHERE key='journal_created_at'; COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(rawDB)
        try await journal.checkpointForTesting()
        XCTAssertEqual(filePermissions(databaseURL), 0o600)
        for sidecar in [URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: sidecar.path) {
            XCTAssertEqual(filePermissions(sidecar), 0o600)
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizon2-i3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeObservation(
        sensitivity: EvidenceSensitivityRegistry? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        extraAttribute: EvidenceValue? = nil,
        rawReferenceDigest: String? = nil
    ) -> Observation {
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let epochID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let date = observedAt
        let subject = EvidenceSubject(type: .storageDisk, identityDigest: "fixture-digest", quality: .qualified, safeDisplayLabel: "External storage disk")
        let provenance = EvidenceProvenance(sourceID: .storage, apiName: "Fixture API", apiVersion: "1", captureChannel: "I3_FIXTURE", sourceTimestampQuality: .exact, normalizationRuleID: "FIXTURE", normalizationRuleVersion: "1.0.0", hostScope: .provenOnTestedHost, rawReferenceDigest: rawReferenceDigest)
        let time = EvidenceTime(observedWallTime: date, continuousNanoseconds: 10, processUptimeNanoseconds: 20, processRunID: runID, bootSessionID: "boot", localSequence: 1, sourceTimestampQuality: .exact, orderingDomain: EvidenceOrderingDomain(sourceID: .storage, processRunID: runID, clockDomainID: "fixture"), sourceOccurrence: EvidenceSourceOccurrence(wallTime: date, continuousNanoseconds: 10, quality: .exact), correlationEpochID: epochID)
        var attributes: [String: EvidenceValue] = ["lifecycle": .string("appeared")]
        if let extraAttribute {
            attributes["extra"] = extraAttribute
        }
        let fields = sensitivity ?? EvidenceSensitivityRegistry(fields: [
            EvidenceFieldSensitivity(path: EvidenceFieldPath("subject.identityDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
            EvidenceFieldSensitivity(path: EvidenceFieldPath("provenance.rawReferenceDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
            EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState"), classification: .none, pseudonymization: .notApplicable),
            EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.lifecycle"), classification: .none, pseudonymization: .notApplicable),
            EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.extra"), classification: .none, pseudonymization: .notApplicable),
        ])
        return Observation(id: id, domain: .storage, eventKind: .storageDiskLifecycle, sourceID: .storage, subject: subject, provenance: provenance, time: time, currentState: .object(["lifecycle": .string("appeared")]), attributes: attributes, sensitivity: fields)
    }

    private func makeIncident(
        for observation: Observation,
        completedAt: Date,
        id: UUID = UUID(),
        contextSize: Int = 16
    ) -> IncidentPackage {
        IncidentPackage(
            id: id,
            marker: IncidentMarker(observationID: observation.id, wallTime: observation.time.observedWallTime, localSequence: observation.time.localSequence),
            status: .complete,
            completedAt: completedAt,
            materializedContext: .object(["context": .string(String(repeating: "c", count: contextSize))]),
            observationIDs: [observation.id]
        )
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func filePermissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private func databaseBytes(_ databaseURL: URL) -> Data {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
            .reduce(into: Data()) { result, url in
                if let data = try? Data(contentsOf: url) {
                    result.append(data)
                }
            }
    }

    private func scalarFromDatabase(_ databaseURL: URL, sql: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw EvidenceJournalError.unavailable
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EvidenceJournalError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw EvidenceJournalError.unavailable }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func execDatabase(_ databaseURL: URL, sql: String) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw EvidenceJournalError.unavailable
        }
        defer { sqlite3_close_v2(database) }
        return sqlite3_exec(database, sql, nil, nil, nil)
    }
}

private actor JournalBootstrapGate {
    private var continuation: CheckedContinuation<any EvidenceJournal, Never>?

    func wait() async -> any EvidenceJournal {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ journal: any EvidenceJournal) {
        continuation?.resume(returning: journal)
        continuation = nil
    }
}

private final class BootstrapProbeAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID = .storage
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return starts > 0
    }

    var hasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stops > 0
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func start() {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    func reconcileAfterWake() {}
}

// swiftlint:enable line_length
// swiftlint:enable trailing_comma
// swiftlint:enable file_length type_body_length
