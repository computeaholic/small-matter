// swiftlint:disable line_length trailing_comma

import Foundation
@testable import Tunix
import XCTest

@MainActor
final class IncidentCaptureTests: XCTestCase {
    func testMarkerIsIndependentFromObservationAndLegacyMarkerDecodes() throws {
        let markerID = try XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000001"))
        let marker = IncidentMarker(
            markerID: markerID,
            wallTime: Date(timeIntervalSince1970: 1_700_000_000),
            continuousNanoseconds: 42,
            observationID: nil
        )
        XCTAssertEqual(marker.markerID, markerID)
        XCTAssertNil(marker.observationID)

        let legacy = IncidentMarker(
            observationID: EvidenceFixtureIDs.storage,
            wallTime: marker.wallTime,
            localSequence: 4
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(IncidentMarker.self, from: data)
        XCTAssertEqual(decoded.observationID, EvidenceFixtureIDs.storage)
        XCTAssertEqual(decoded.markerID, EvidenceFixtureIDs.storage)
        XCTAssertEqual(decoded.localSequence, 4)
    }

    func testCoordinatorCapturesWindowAndFinalizesCompletePackage() async throws {
        let markerTime = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = InMemoryEvidenceJournal(observations: [EvidenceFixtureIDs.observation])
        let scheduler = ManualIncidentCaptureScheduler()
        let coordinator = IncidentCaptureCoordinator(
            journal: journal,
            clock: FixedEvidenceClock(wallTime: markerTime, continuousNanoseconds: 1000, processUptimeNanoseconds: 1000),
            scheduler: scheduler,
            processRunID: EvidenceFixtureIDs.processA
        )

        coordinator.start(context: IncidentContextSnapshot(capturedAt: markerTime, values: .object(["system": .object(["safe": .boolean(true)])]), unknowns: []))
        await yieldToCoordinator()
        XCTAssertEqual(coordinator.state, IncidentCaptureState.capturing)
        let activeAfterStart = await journal.activeIncidentCaptures()
        XCTAssertEqual(activeAfterStart.count, 1)

        scheduler.advance(by: 120)
        await yieldToCoordinator()
        await yieldToCoordinator()

        XCTAssertEqual(coordinator.state, IncidentCaptureState.complete)
        let package = try XCTUnwrap(coordinator.incidents.first)
        XCTAssertEqual(package.status, IncidentCaptureStatus.complete)
        XCTAssertEqual(package.observationIDs, [EvidenceFixtureIDs.observation.id])
        XCTAssertNil(package.marker.observationID)
        XCTAssertEqual(package.preWindowSeconds, 60)
        XCTAssertEqual(package.postWindowSeconds, 120)
        let activeAfterFinish = await journal.activeIncidentCaptures()
        XCTAssertTrue(activeAfterFinish.isEmpty)
    }

    func testSecondCaptureCannotStartWhileOneIsActive() async {
        let journal = InMemoryEvidenceJournal()
        let scheduler = ManualIncidentCaptureScheduler()
        let coordinator = IncidentCaptureCoordinator(
            journal: journal,
            clock: FixedEvidenceClock(wallTime: Date(timeIntervalSince1970: 1_700_000_000), continuousNanoseconds: 1, processUptimeNanoseconds: 1),
            scheduler: scheduler,
            processRunID: EvidenceFixtureIDs.processA
        )
        let context = IncidentContextSnapshot(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), values: .object([:]), unknowns: [])

        coordinator.start(context: context)
        await yieldToCoordinator()
        coordinator.start(context: context)
        await yieldToCoordinator()

        let active = await journal.activeIncidentCaptures()
        XCTAssertEqual(active.count, 1)
    }

    func testStaleCaptureRecoversAsIncompleteAfterProcessRestart() async throws {
        let markerTime = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = InMemoryEvidenceJournal(observations: [EvidenceFixtureIDs.observation])
        let session = try IncidentCaptureSession(
            id: XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000002")),
            marker: IncidentMarker(markerID: UUID(), wallTime: markerTime),
            startedAt: markerTime,
            processRunID: EvidenceFixtureIDs.processA,
            materializedContext: .object(["system": .object(["safe": .boolean(true)])]),
            observationIDs: [EvidenceFixtureIDs.observation.id]
        )
        try await journal.beginIncidentCapture(session)

        let coordinator = IncidentCaptureCoordinator(
            journal: journal,
            clock: FixedEvidenceClock(wallTime: markerTime, continuousNanoseconds: 2, processUptimeNanoseconds: 2),
            scheduler: ManualIncidentCaptureScheduler(),
            processRunID: EvidenceFixtureIDs.processB
        )
        await yieldToCoordinator()

        let recovered = await journal.incident(id: session.id)
        let package = try XCTUnwrap(recovered)
        XCTAssertEqual(package.status, .incomplete)
        XCTAssertEqual(package.failureReason, .processInterrupted)
        XCTAssertEqual(package.observationIDs, [EvidenceFixtureIDs.observation.id])
        XCTAssertEqual(coordinator.state, IncidentCaptureState.idle)
    }

    func testSQLiteActiveCaptureAndDeletionPreserveOrdinaryObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("i5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("journal.sqlite")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let journal = try SQLiteEvidenceJournal(databaseURL: url)
            try await journal.append(EvidenceFixtureIDs.observation)
            let session = try IncidentCaptureSession(
                id: XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000003")),
                marker: IncidentMarker(markerID: UUID(), wallTime: EvidenceFixtureIDs.observation.time.observedWallTime),
                startedAt: EvidenceFixtureIDs.observation.time.observedWallTime,
                processRunID: EvidenceFixtureIDs.processA,
                materializedContext: .object(["system": .object(["safe": .boolean(true)])]),
                observationIDs: [EvidenceFixtureIDs.observation.id]
            )
            try await journal.beginIncidentCapture(session)
            let active = await journal.activeIncidentCaptures()
            XCTAssertEqual(active.first?.id, session.id)

            let package = IncidentPackage(
                id: session.id,
                marker: session.marker,
                status: .complete,
                completedAt: session.marker.wallTime,
                materializedContext: session.materializedContext,
                observationIDs: session.observationIDs
            )
            try await journal.finalizeIncidentCapture(package)
            let persisted = await journal.incident(id: package.id)
            XCTAssertEqual(persisted, package)
            try await journal.deleteIncident(id: package.id)
            let deleted = await journal.incident(id: package.id)
            XCTAssertNil(deleted)
            let ordinaryObservation = await journal.observation(id: EvidenceFixtureIDs.observation.id)
            XCTAssertNotNil(ordinaryObservation)
            let foreignKeys = await journal.foreignKeyViolationsForTesting()
            XCTAssertTrue(foreignKeys.isEmpty)
        }
    }

    func testIncidentContextHistoryProducesBoundedSummaryWithoutInventingCoverage() {
        let history = IncidentContextHistory()
        let marker = Date(timeIntervalSince1970: 1_700_001_000)
        history.append(IncidentContextSnapshot(
            capturedAt: marker.addingTimeInterval(-60),
            values: context(cpu: "10.00", memory: 100, pressure: "normal", acConnected: true)
        ))
        history.append(IncidentContextSnapshot(
            capturedAt: marker.addingTimeInterval(60),
            values: context(cpu: "30.00", memory: 300, pressure: "warning", acConnected: false)
        ))
        history.append(IncidentContextSnapshot(
            capturedAt: marker.addingTimeInterval(120),
            values: context(cpu: "20.00", memory: 200, pressure: "normal", acConnected: false)
        ))

        let summary = history.summary(marker: marker, preWindow: 60, postWindow: 120)
        XCTAssertEqual(summary.coverage, .complete)
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.metrics["cpuUtilizationPercent"]?.minimum, 10)
        XCTAssertEqual(summary.metrics["cpuUtilizationPercent"]?.maximum, 30)
        XCTAssertEqual(summary.metrics["cpuUtilizationPercent"]?.mean, 20)
        XCTAssertEqual(summary.metrics["memoryUsedBytes"]?.sampleCount, 3)
        XCTAssertEqual(summary.states["memoryPressure"], ["normal", "warning"])
        XCTAssertEqual(summary.states["batteryACConnected"], ["false", "true"])
        guard case let .object(fields) = summary.evidenceValue else {
            return XCTFail("summary must remain a scalar bounded object")
        }
        XCTAssertEqual(fields["sampleCount"], .unsigned(3))
        XCTAssertEqual(fields["metric_cpuUtilizationPercent_mean"], .decimal("20.00"))
        XCTAssertFalse(fields.values.contains {
            if case .array = $0 {
                return true
            }; return false
        })
    }

    func testIncidentContextHistoryIsFiveMinutesAndCountBounded() {
        let history = IncidentContextHistory()
        let first = Date(timeIntervalSince1970: 1_700_002_000)
        for index in 0 ..< 500 {
            history.append(IncidentContextSnapshot(
                capturedAt: first.addingTimeInterval(Double(index)),
                values: context(cpu: "1.00", memory: UInt64(index), pressure: "normal", acConnected: true)
            ))
        }

        XCTAssertLessThanOrEqual(history.sampleCount, IncidentContextHistory.maximumSamples)
        let summary = history.summary(
            marker: first.addingTimeInterval(499),
            preWindow: 60,
            postWindow: 120
        )
        XCTAssertLessThanOrEqual(summary.sampleCount, 181)
        XCTAssertGreaterThan(summary.sampleCount, 0)
    }

    func testIncidentContextHistoryReportsPartialAndUnavailableWindows() {
        let history = IncidentContextHistory()
        let marker = Date(timeIntervalSince1970: 1_700_003_000)
        XCTAssertEqual(history.summary(marker: marker, preWindow: 60, postWindow: 120).coverage, .unavailable)

        history.append(IncidentContextSnapshot(
            capturedAt: marker,
            values: context(cpu: "5.00", memory: 50, pressure: "normal", acConnected: true)
        ))
        XCTAssertEqual(history.summary(marker: marker, preWindow: 60, postWindow: 120).coverage, .partial)
    }

    func testCoordinatorPersistsWindowSummaryAndCoverageUnknown() async throws {
        let marker = Date(timeIntervalSince1970: 1_700_004_000)
        let history = IncidentContextHistory()
        history.append(IncidentContextSnapshot(
            capturedAt: marker,
            values: context(cpu: "12.00", memory: 120, pressure: "normal", acConnected: true)
        ))
        let journal = InMemoryEvidenceJournal()
        let scheduler = ManualIncidentCaptureScheduler()
        let coordinator = IncidentCaptureCoordinator(
            journal: journal,
            clock: FixedEvidenceClock(wallTime: marker, continuousNanoseconds: 1, processUptimeNanoseconds: 1),
            scheduler: scheduler,
            processRunID: EvidenceFixtureIDs.processA,
            contextHistory: history
        )
        coordinator.start(context: IncidentContextSnapshot(capturedAt: marker, values: .object([:]), unknowns: []))
        await yieldToCoordinator()
        scheduler.advance(by: 120)
        await yieldToCoordinator()
        await yieldToCoordinator()

        let package = try XCTUnwrap(coordinator.incidents.first)
        guard case let .object(fields) = package.materializedContext,
              case let .object(window)? = fields["windowSummary"]
        else {
            return XCTFail("window summary was not persisted")
        }
        XCTAssertEqual(window["coverage"], .string("PARTIAL"))
        XCTAssertTrue(package.unknowns.contains { $0.reason == .sourceCoverageGap })
    }

    private func context(cpu: String, memory: UInt64, pressure: String, acConnected: Bool) -> EvidenceValue {
        .object([
            "system": .object([
                "cpuUtilizationPercent": .decimal(cpu),
                "memoryUsedBytes": .unsigned(memory),
                "memoryPressure": .string(pressure),
                "thermalState": .string("Nominal"),
                "lowPowerMode": .boolean(false),
            ]),
            "network": .object([:]),
            "battery": .object([
                "present": .boolean(true),
                "acConnected": .boolean(acConnected),
                "charging": .boolean(acConnected),
            ]),
            "cooling": .object([:]),
        ])
    }

    private func yieldToCoordinator() async {
        for _ in 0 ..< 100 {
            await Task.yield()
        }
    }
}

private enum EvidenceFixtureIDs {
    static let storage = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    static let processA = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    static let processB = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!

    static let observation: Observation = {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Observation(
            id: storage,
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            sourceID: .storage,
            subject: EvidenceSubject(type: .storageDisk, identityDigest: nil, quality: .weak, safeDisplayLabel: "Storage disk"),
            provenance: EvidenceProvenance(sourceID: .storage, apiName: "Fixture", apiVersion: nil, captureChannel: "I5_TEST", sourceTimestampQuality: .exact, normalizationRuleID: "I5_TEST", normalizationRuleVersion: "1.0.0", hostScope: .supportedProductBehavior, rawReferenceDigest: nil),
            time: EvidenceTime(observedWallTime: date, continuousNanoseconds: 1, processUptimeNanoseconds: 1, processRunID: processA, bootSessionID: "i5-test", localSequence: 1, sourceTimestampQuality: .exact, orderingDomain: EvidenceOrderingDomain(sourceID: .storage, processRunID: processA, clockDomainID: "i5-clock"), sourceOccurrence: EvidenceSourceOccurrence(wallTime: date, continuousNanoseconds: 1, quality: .exact)),
            attributes: ["lifecycle": .string("diskAppeared")],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(path: EvidenceFieldPath("subject.identityDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("provenance.rawReferenceDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.lifecycle"), classification: .none, pseudonymization: .notApplicable),
            ])
        )
    }()
}
