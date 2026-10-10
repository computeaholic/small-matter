@testable import Tunix
import XCTest

// swiftlint:disable:next type_body_length
final class InferenceEngineTests: XCTestCase {
    func testProductionRegistryIsExactlyTwoCurrentRules() {
        XCTAssertTrue(InitialInferenceRuleRegistry.production.validateProductionInventory())
        XCTAssertEqual(
            Set(InitialInferenceRuleRegistry.production.definitions.keys),
            Horizon2EvidenceConfiguration.initialRuleIDs
        )
        XCTAssertEqual(InitialInferenceRule.storage.version, "1.0.0")
        XCTAssertEqual(InitialInferenceRule.network.version, "1.0.0")
    }

    func testStorageInferenceUsesStructuredLifecycleAndExactSupport() throws {
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(1))
        let package = incident([observation])
        let set = try XCTUnwrap(try currentSet(package: package, observations: [observation]).first)
        let inference = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: [observation])

        XCTAssertEqual(inference.evidenceClass, .supported)
        XCTAssertEqual(inference.supportingObservationIDs, [observation.id])
        XCTAssertTrue(inference.contradictingObservationIDs.isEmpty)
        XCTAssertEqual(inference.nextTests.map(\.testID), ["INSPECT_STORAGE_STATE"])
        guard case let .object(values) = inference.hypothesis else { return XCTFail("Structured hypothesis missing") }
        XCTAssertEqual(values["kind"], .string("EXTERNAL_STORAGE_LIFECYCLE"))
        XCTAssertEqual(values["subjectType"], .string("STORAGE_DISK"))
        XCTAssertFalse(String(describing: inference.hypothesis).localizedCaseInsensitiveContains("failure"))
    }

    func testNetworkInferenceKeepsPhysicalCauseUnknownAndAlternativesUnranked() throws {
        let observation = network(previous: "SATISFIED", current: "UNSATISFIED", id: id(2))
        let package = incident([observation])
        let set = try XCTUnwrap(try currentSet(package: package, observations: [observation]).first)
        let inference = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: [observation])

        XCTAssertEqual(inference.evidenceClass, .supported)
        XCTAssertEqual(inference.supportingObservationIDs, [observation.id])
        XCTAssertEqual(inference.alternatives.count, 3)
        XCTAssertTrue(inference.alternatives.allSatisfy { $0.reason.contains("does not establish") })
        guard case let .object(values) = inference.hypothesis else { return XCTFail("Structured hypothesis missing") }
        XCTAssertEqual(values["physicalCause"], .string("UNKNOWN"))
    }

    func testContradictionAndMissingEvidenceAreExplicit() throws {
        let contradiction = network(previous: "SATISFIED", current: "SATISFIED", id: id(3))
        let package = incident([contradiction])
        let set = try XCTUnwrap(try currentSet(package: package, observations: [contradiction]).first)
        let result = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: [contradiction])
        XCTAssertEqual(result.evidenceClass, .insufficientEvidence)
        XCTAssertEqual(result.contradictingObservationIDs, [contradiction.id])
        XCTAssertTrue(result.supportingObservationIDs.isEmpty)

        let missing = storage(.storageDiskLifecycle, lifecycle: nil, id: id(4))
        let missingPackage = incident([missing])
        let missingSet = try XCTUnwrap(try currentSet(package: missingPackage, observations: [missing]).first)
        let missingResult = try InferenceEngine().evaluate(
            incident: missingPackage,
            evidenceSet: missingSet,
            observations: [missing]
        )
        XCTAssertEqual(missingResult.evidenceClass, .insufficientEvidence)
        XCTAssertEqual(missingResult.missingEvidence.first?.sourceID, .storage)
        XCTAssertEqual(missingResult.missingEvidence.first?.reason, .notObserved)
    }

    func testUnrelatedIncidentUnknownDoesNotDegradeRelevantRule() throws {
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskDisappeared", id: id(5))
        let unrelated = EvidenceMissing(
            sourceID: .network,
            reason: .incompleteCapture,
            explanation: "Network coverage was incomplete."
        )
        let package = incident([observation], status: .incomplete, unknowns: [unrelated])
        let set = try XCTUnwrap(try currentSet(package: package, observations: [observation]).first)
        let result = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: [observation])
        XCTAssertEqual(result.evidenceClass, .supported)
        XCTAssertTrue(result.missingEvidence.isEmpty)

        let relevant = incident(
            [observation],
            status: .incomplete,
            unknowns: [EvidenceMissing(
                sourceID: .storage,
                reason: .incompleteCapture,
                explanation: "Storage coverage was incomplete."
            )]
        )
        let relevantSet = try XCTUnwrap(try currentSet(package: relevant, observations: [observation]).first)
        let relevantResult = try InferenceEngine().evaluate(
            incident: relevant,
            evidenceSet: relevantSet,
            observations: [observation]
        )
        XCTAssertEqual(relevantResult.evidenceClass, .insufficientEvidence)
    }

    func testLegacyCorrelationInputIsRejected() throws {
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(6))
        let package = incident([observation])
        let current = try XCTUnwrap(try currentSet(package: package, observations: [observation]).first)
        let legacy = EvidenceSet(
            id: current.id,
            members: current.members,
            ruleID: InitialCorrelationRule.storage.id,
            ruleVersion: InitialCorrelationRule.legacyVersion,
            temporalBounds: current.temporalBounds,
            orderingQuality: current.orderingQuality,
            evidenceSetSchemaVersion: EvidenceSet.legacySchemaVersion
        )
        XCTAssertThrowsError(try InferenceEngine().evaluate(
            incident: package,
            evidenceSet: legacy,
            observations: [observation]
        )) { error in
            XCTAssertTrue(error is InferenceEngineError)
        }
    }

    func testInferenceIDIsStableAcrossOneHundredEvaluations() throws {
        let observations = [
            storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(7), sequence: 1),
            storage(.storageDiskLifecycle, lifecycle: "diskDisappeared", id: id(8), sequence: 2)
        ]
        let package = incident(observations)
        let set = try XCTUnwrap(try currentSet(package: package, observations: observations).first)
        let expected = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: observations)
        for offset in 0 ..< 100 {
            let permutation = offset.isMultiple(of: 2) ? observations : observations.reversed()
            let actual = try InferenceEngine().evaluate(
                incident: package,
                evidenceSet: set,
                observations: Array(permutation)
            )
            XCTAssertEqual(actual, expected)
        }
    }

    func testInMemoryInferencePersistenceIsIdempotentAndSnapshotsAreImmutable() async throws {
        let observation = network(previous: "SATISFIED", current: "UNSATISFIED", id: id(9))
        let package = incident([observation])
        let journal = InMemoryEvidenceJournal(observations: [observation], incidents: [package])
        let set = try XCTUnwrap(try currentSet(package: package, observations: [observation]).first)
        try await journal.persistEvidenceSets(incidentID: package.id, sets: [set])
        let inference = try InferenceEngine().evaluate(incident: package, evidenceSet: set, observations: [observation])
        let entries = Horizon2NextTestCatalog.production.entries
        try await journal.persistInferences(incidentID: package.id, inferences: [inference], catalogEntries: entries)
        try await journal.persistInferences(incidentID: package.id, inferences: [inference], catalogEntries: entries)
        let storedInferences = await journal.inferences(incidentID: package.id, currentOnly: true)
        let storedSnapshots = await journal.nextTestSnapshots(inferenceID: inference.id)
        XCTAssertEqual(storedInferences, [inference])
        XCTAssertEqual(storedSnapshots, entries.filter { inference.nextTests.contains($0.reference) })
    }

    func testInMemoryCurrentOnlySeparatesLegacyInference() async throws {
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(11))
        let package = incident([observation])
        let journal = InMemoryEvidenceJournal(observations: [observation], incidents: [package])
        let current = try XCTUnwrap(currentSet(package: package, observations: [observation]).first)
        let legacy = EvidenceSet(
            id: id(12),
            members: current.members,
            ruleID: current.ruleID,
            ruleVersion: InitialCorrelationRule.legacyVersion,
            temporalBounds: current.temporalBounds,
            orderingQuality: current.orderingQuality,
            evidenceSetSchemaVersion: EvidenceSet.legacySchemaVersion
        )
        try await journal.persistEvidenceSets(incidentID: package.id, sets: [current, legacy])

        let currentInference = try InferenceEngine().evaluate(
            incident: package,
            evidenceSet: current,
            observations: [observation]
        )
        let legacyInference = Inference(
            id: id(13),
            evidenceSetID: legacy.id,
            generatedAt: currentInference.generatedAt,
            hypothesis: currentInference.hypothesis,
            evidenceClass: currentInference.evidenceClass,
            supportingObservationIDs: currentInference.supportingObservationIDs,
            contradictingObservationIDs: currentInference.contradictingObservationIDs,
            alternatives: currentInference.alternatives,
            missingEvidence: currentInference.missingEvidence,
            nextTests: currentInference.nextTests,
            ruleID: currentInference.ruleID,
            ruleVersion: currentInference.ruleVersion,
            inferenceSchemaVersion: currentInference.inferenceSchemaVersion,
            inputContractVersion: currentInference.inputContractVersion
        )
        let entries = Horizon2NextTestCatalog.production.entries
        try await journal.persistInferences(
            incidentID: package.id,
            inferences: [currentInference, legacyInference],
            catalogEntries: entries
        )

        let allInferences = await journal.inferences(incidentID: package.id, currentOnly: false)
        let currentInferences = await journal.inferences(incidentID: package.id, currentOnly: true)
        let storedLegacy = await journal.inference(id: legacyInference.id)
        XCTAssertEqual(allInferences.count, 2)
        XCTAssertEqual(currentInferences, [currentInference])
        XCTAssertNotNil(storedLegacy)
    }

    func testSQLiteInferenceRoundTripsExactEvidenceAndCatalogSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "i7-inference-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(10))
        try await journal.append(observation)
        let package = incident([observation])
        try await journal.persist(incident: package)
        let set = try XCTUnwrap(currentSet(package: package, observations: [observation]).first)
        try await journal.persistEvidenceSets(incidentID: package.id, sets: [set])

        let inference = try InferenceEngine().evaluate(
            incident: package,
            evidenceSet: set,
            observations: [observation]
        )
        try await journal.persistInferences(
            incidentID: package.id,
            inferences: [inference],
            catalogEntries: Horizon2NextTestCatalog.production.entries
        )

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let reopenedInferences = await reopened.inferences(incidentID: package.id, currentOnly: false)
        let reopenedSnapshots = await reopened.nextTestSnapshots(inferenceID: inference.id)
        let foreignKeyViolations = await reopened.foreignKeyViolationsForTesting()
        XCTAssertEqual(reopenedInferences, [inference])
        XCTAssertEqual(
            reopenedSnapshots,
            Horizon2NextTestCatalog.production.entries.filter { inference.nextTests.contains($0.reference) }
        )
        XCTAssertEqual(foreignKeyViolations, [])
    }

    // swiftlint:disable:next function_body_length
    func testSQLiteCurrentOnlySeparatesLegacyInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "i7-current-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let observation = storage(.storageDiskLifecycle, lifecycle: "diskAppeared", id: id(14))
        try await journal.append(observation)
        let package = incident([observation])
        try await journal.persist(incident: package)
        let current = try XCTUnwrap(currentSet(package: package, observations: [observation]).first)
        let legacy = EvidenceSet(
            id: id(15),
            members: current.members,
            ruleID: current.ruleID,
            ruleVersion: InitialCorrelationRule.legacyVersion,
            temporalBounds: current.temporalBounds,
            orderingQuality: current.orderingQuality,
            evidenceSetSchemaVersion: EvidenceSet.legacySchemaVersion
        )
        try await journal.persistEvidenceSets(incidentID: package.id, sets: [current, legacy])

        let currentInference = try InferenceEngine().evaluate(
            incident: package,
            evidenceSet: current,
            observations: [observation]
        )
        let legacyInference = Inference(
            id: id(16),
            evidenceSetID: legacy.id,
            generatedAt: currentInference.generatedAt,
            hypothesis: currentInference.hypothesis,
            evidenceClass: currentInference.evidenceClass,
            supportingObservationIDs: currentInference.supportingObservationIDs,
            contradictingObservationIDs: currentInference.contradictingObservationIDs,
            alternatives: currentInference.alternatives,
            missingEvidence: currentInference.missingEvidence,
            nextTests: currentInference.nextTests,
            ruleID: currentInference.ruleID,
            ruleVersion: currentInference.ruleVersion,
            inferenceSchemaVersion: currentInference.inferenceSchemaVersion,
            inputContractVersion: currentInference.inputContractVersion
        )
        try await journal.persistInferences(
            incidentID: package.id,
            inferences: [currentInference, legacyInference],
            catalogEntries: Horizon2NextTestCatalog.production.entries
        )

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let allInferences = await reopened.inferences(incidentID: package.id, currentOnly: false)
        let currentInferences = await reopened.inferences(incidentID: package.id, currentOnly: true)
        let storedLegacy = await reopened.inference(id: legacyInference.id)
        XCTAssertEqual(allInferences.count, 2)
        XCTAssertEqual(currentInferences, [currentInference])
        XCTAssertNotNil(storedLegacy)
    }

    func testDuplicateCatalogReferenceFailsValidation() throws {
        let snapshot = Horizon2NextTestCatalog.production
        let duplicate = try XCTUnwrap(snapshot.entries.first)
        let invalid = NextTestCatalogSnapshot(version: snapshot.version, entries: snapshot.entries + [duplicate])
        XCTAssertThrowsError(try invalid.validated()) { error in
            XCTAssertEqual(error as? NextTestValidationIssue, .duplicateCatalogReference)
        }
    }

    func testInferenceFixtureSeedsInferenceBeforeHistoryRefresh() async throws {
        let journal = RecentChangesFixture.journal(arguments: [
            "-UITesting",
            "-UITestingRecentChanges=loaded",
            "-UITestingIncident=inference-insufficient"
        ])
        await RecentChangesFixture.seedIncidentFixture(
            mode: "inference-insufficient",
            journal: journal,
            processRunID: processRunID
        )
        let incidentID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000305"))
        let seededIncident = await journal.incident(id: incidentID)
        let seededSets = await journal.evidenceSets(incidentID: incidentID)
        let seededInferences = await journal.inferences(incidentID: incidentID, currentOnly: false)
        XCTAssertNotNil(seededIncident)
        XCTAssertFalse(seededSets.isEmpty)
        XCTAssertFalse(seededInferences.isEmpty)
    }

    private func currentSet(package: IncidentPackage, observations: [Observation]) throws -> [EvidenceSet] {
        try CorrelationEngine().correlate(incident: package, observations: observations)
    }

    private func incident(
        _ observations: [Observation],
        status: IncidentCaptureStatus = .complete,
        unknowns: [EvidenceMissing] = []
    ) -> IncidentPackage {
        IncidentPackage(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            marker: IncidentMarker(
                markerID: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                wallTime: start
            ),
            status: status,
            completedAt: start.addingTimeInterval(120),
            materializedContext: .object([:]),
            observationIDs: observations.map(\.id),
            unknowns: unknowns,
            failureReason: unknowns.first?.reason
        )
    }

    private func storage(_ kind: EvidenceEventKind, lifecycle: String?, id: UUID, sequence: UInt64 = 1) -> Observation {
        Observation(
            id: id,
            domain: .storage,
            eventKind: kind,
            sourceID: .storage,
            subject: EvidenceSubject(
                type: .storageDisk,
                identityDigest: "storage-fixture",
                quality: .qualified,
                safeDisplayLabel: "Storage disk"
            ),
            provenance: provenance(.storage),
            time: time(.storage, sequence: sequence),
            currentState: lifecycle.map { .object(["lifecycle": .string($0)]) },
            attributes: lifecycle.map { ["lifecycle": .string($0)] } ?? [:],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("subject.identityDigest"),
                    classification: .deviceMetadata,
                    pseudonymization: .required(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.lifecycle"),
                    classification: .none,
                    pseudonymization: .notApplicable
                )
            ])
        )
    }

    private func network(previous: String, current: String, id: UUID, sequence: UInt64 = 1) -> Observation {
        Observation(
            id: id,
            domain: .network,
            eventKind: .networkPathTransition,
            sourceID: .network,
            subject: EvidenceSubject(
                type: .networkInterface,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: "Network path"
            ),
            provenance: provenance(.network),
            time: time(.network, sequence: sequence),
            previousState: .object(["status": .string(previous)]),
            currentState: .object(["status": .string(current)]),
            attributes: ["supplemental": .boolean(true)]
        )
    }

    private func provenance(_ source: Horizon2SourceID) -> EvidenceProvenance {
        EvidenceProvenance(
            sourceID: source,
            apiName: "Fixture API",
            apiVersion: "1",
            captureChannel: "I7 fixture",
            sourceTimestampQuality: .exact,
            normalizationRuleID: "I7_FIXTURE",
            normalizationRuleVersion: "1.0.0",
            hostScope: .provenOnTestedHost,
            rawReferenceDigest: nil
        )
    }

    private func time(_ source: Horizon2SourceID, sequence: UInt64) -> EvidenceTime {
        EvidenceTime(
            observedWallTime: start.addingTimeInterval(Double(sequence)),
            continuousNanoseconds: sequence * 1_000_000_000,
            processUptimeNanoseconds: sequence * 1_000_000_000,
            processRunID: processRunID,
            bootSessionID: "i7-boot",
            localSequence: sequence,
            sourceTimestampQuality: .exact,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: source,
                processRunID: processRunID,
                clockDomainID: "i7-clock"
            ),
            sourceOccurrence: EvidenceSourceOccurrence(
                wallTime: start,
                continuousNanoseconds: sequence * 1_000_000_000,
                quality: .exact
            )
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", value))!
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let processRunID = UUID(uuidString: "40000000-0000-0000-0000-000000000010")!
} // swiftlint:disable:this file_length
