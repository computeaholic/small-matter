// swiftformat:disable trailingCommas
@testable import Tunix
import XCTest

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
final class Horizon2EvidenceCoreTests: XCTestCase {
    func testObservationRoundTripIsDeterministicAndValueBased() throws {
        let observation = EvidenceFixtureCorpus.externalStorageLoss
        let first = try observation.deterministicData()
        let second = try observation.deterministicData()
        XCTAssertEqual(first, second)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Observation.self, from: first), observation)
        XCTAssertEqual(observation, observation)
        let _: any Sendable = observation
    }

    func testUnknownDomainAndEventKindDecodeWithoutChangingKnownValues() throws {
        let observation = EvidenceFixtureCorpus.externalStorageLoss
        let encoder = JSONEncoder()
        let data = try encoder.encode(observation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["domain"] = "FUTURE_DOMAIN"
        object["eventKind"] = "FUTURE_EVENT"
        let futureData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Observation.self, from: futureData)
        XCTAssertEqual(decoded.domain, .unknown("FUTURE_DOMAIN"))
        XCTAssertEqual(decoded.eventKind, .unknown("FUTURE_EVENT"))
    }

    func testEveryEventKindRoundTripsLosslessly() throws {
        let eventKinds: [EvidenceEventKind] = [
            .storageDiskLifecycle,
            .storageMountLifecycle,
            .networkPathTransition,
            .powerSourceTransition,
            .sleepWakeBoundary(.none),
            .sleepWakeBoundary(.processRestart),
            .sleepWakeBoundary(.sleepWake),
            .sourceUnavailable,
            .sourceSuppressed,
            .unknown("FUTURE_EVENT")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for eventKind in eventKinds {
            XCTAssertEqual(try decoder.decode(EvidenceEventKind.self, from: encoder.encode(eventKind)), eventKind)
        }
    }

    func testUnavailableIsDistinctFromZeroAndMissingSourceTimeStaysMissing() {
        let unavailable = EvidenceFixtureCorpus.missingEvidence
        XCTAssertEqual(unavailable.availability, .unavailable(.sourceUnavailable))
        XCTAssertNil(unavailable.time.sourceOccurrence?.wallTime)
        XCTAssertNil(unavailable.time.sourceOccurrence?.continuousNanoseconds)

        let zero = EvidenceFixtureCorpus.externalStorageLoss
        XCTAssertEqual(zero.currentState, .integer(0))
        XCTAssertNotEqual(zero.availability, unavailable.availability)
    }

    func testNamedFixtureCorpusUsesFixedIDsAndTypedStreams() throws {
        XCTAssertEqual(
            EvidenceFixtureCorpus.unrelatedEvents.map(\.id),
            [EvidenceFixtureCorpus.ids.storageObservation, EvidenceFixtureCorpus.ids.networkObservation]
        )
        XCTAssertEqual(EvidenceFixtureCorpus.duplicateEvent[0], EvidenceFixtureCorpus.duplicateEvent[1])
        XCTAssertEqual(EvidenceFixtureCorpus.outOfOrderEvent.map(\.time.localSequence), [2, 1])
        XCTAssertEqual(EvidenceFixtureCorpus.contradictoryEvidence[1].availability, .unavailable(.sourceUnavailable))
        XCTAssertEqual(
            try EvidenceFixtureCorpus.sleepWakeBoundary.deterministicData(),
            try EvidenceFixtureCorpus.sleepWakeBoundary.deterministicData()
        )
    }

    func testOrderingUsesExplicitLocalAndContinuousBases() {
        let first = EvidenceFixtureCorpus.externalStorageLoss
        let second = EvidenceFixtureCorpus.networkPathTransition
        let local = first.time.compare(to: first.time)
        XCTAssertEqual(local.relation, .equal)
        XCTAssertEqual(local.basis, .localSequence)

        let continuous = first.time.compare(to: second.time)
        XCTAssertEqual(continuous.relation, .before)
        XCTAssertEqual(continuous.basis, .continuousClock)

        let restarted = EvidenceFixtureCorpus.afterProcessRestart
        let processBoundary = first.time.compare(to: restarted.time)
        XCTAssertEqual(processBoundary.relation, .incomparable)
        XCTAssertEqual(processBoundary.basis, .none)

        let sleepBoundary = first.time.compare(to: EvidenceFixtureCorpus.sleepWakeBoundary.time)
        XCTAssertEqual(sleepBoundary.relation, .incomparable)
        XCTAssertEqual(sleepBoundary.basis, .none)

        var differentClock = second.time
        differentClock = EvidenceTime(
            observedWallTime: differentClock.observedWallTime,
            continuousNanoseconds: differentClock.continuousNanoseconds,
            processUptimeNanoseconds: differentClock.processUptimeNanoseconds,
            processRunID: differentClock.processRunID,
            bootSessionID: differentClock.bootSessionID,
            localSequence: differentClock.localSequence,
            sourceTimestampQuality: differentClock.sourceTimestampQuality,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: .network,
                processRunID: differentClock.processRunID,
                clockDomainID: "other-clock"
            ),
            sourceOccurrence: differentClock.sourceOccurrence
        )
        let differentClockResult = first.time.compare(to: differentClock)
        XCTAssertEqual(differentClockResult.relation, .incomparable)
        XCTAssertEqual(differentClockResult.basis, .none)

        let wallOnly = EvidenceTime(
            observedWallTime: second.time.observedWallTime,
            continuousNanoseconds: nil,
            processUptimeNanoseconds: nil,
            processRunID: second.time.processRunID,
            bootSessionID: second.time.bootSessionID,
            localSequence: second.time.localSequence,
            sourceTimestampQuality: .unavailable,
            orderingDomain: second.time.orderingDomain,
            sourceOccurrence: nil
        )
        let wallOnlyResult = first.time.compare(to: wallOnly)
        XCTAssertEqual(wallOnlyResult.relation, .incomparable)
        XCTAssertEqual(wallOnlyResult.basis, .none)
        XCTAssertEqual(EvidenceFixtureCorpus.sleepWakeBoundary.eventKind, .sleepWakeBoundary(.sleepWake))
    }

    func testSchemaAuthoritiesRemainIndependent() {
        XCTAssertEqual(Observation.currentSchemaVersion, Horizon2EvidenceConfiguration.observationSchemaVersion)
        XCTAssertEqual(Horizon2EvidenceConfiguration.incidentPackageSchemaVersion, 1)
        XCTAssertEqual(EvidencePackage.currentSchemaVersion, Horizon2EvidenceConfiguration.evidencePackageSchemaVersion)
        XCTAssertEqual(Horizon2EvidenceConfiguration.sqliteSchemaVersion, 1)

        let observationWithNextSchema = Observation(
            id: EvidenceFixtureCorpus.externalStorageLoss.id,
            domain: EvidenceFixtureCorpus.externalStorageLoss.domain,
            eventKind: EvidenceFixtureCorpus.externalStorageLoss.eventKind,
            sourceID: EvidenceFixtureCorpus.externalStorageLoss.sourceID,
            subject: EvidenceFixtureCorpus.externalStorageLoss.subject,
            provenance: EvidenceFixtureCorpus.externalStorageLoss.provenance,
            time: EvidenceFixtureCorpus.externalStorageLoss.time,
            schemaVersion: Horizon2EvidenceConfiguration.observationSchemaVersion + 1
        )
        XCTAssertEqual(observationWithNextSchema.schemaVersion, 2)
        XCTAssertEqual(Horizon2EvidenceConfiguration.sqliteSchemaVersion, 1)
        XCTAssertNotEqual(observationWithNextSchema.schemaVersion, Horizon2EvidenceConfiguration.sqliteSchemaVersion)
    }

    func testSensitivitySupportsNestedArraysOptionalFieldsAndUnknownPaths() throws {
        let registry = EvidenceSensitivityRegistry(fields: [
            EvidenceFieldSensitivity(
                path: EvidenceFieldPath("attributes.interfaces[*].name"),
                classification: .networkMetadata,
                pseudonymization: .allowed(scope: "package")
            ),
            EvidenceFieldSensitivity(
                path: EvidenceFieldPath("attributes.mount.volumeName"),
                classification: .filesystemMetadata,
                pseudonymization: .required(scope: "package")
            )
        ])
        XCTAssertEqual(
            registry.classification(for: EvidenceFieldPath("attributes.interfaces[*].name")),
            .networkMetadata
        )
        XCTAssertEqual(
            registry.metadata(for: EvidenceFieldPath("attributes.mount.volumeName"))?.pseudonymization,
            .required(scope: "package")
        )
        XCTAssertNil(registry.classification(for: EvidenceFieldPath("attributes.unknown")))

        let value: EvidenceValue = .object([
            "interfaces": .array([.object(["name": .string("en0")])]),
            "optional": .null
        ])
        XCTAssertFalse(try value.deterministicData().isEmpty)
    }

    func testInferenceUsesExactObservationIDsAndDoesNotMutateObservations() {
        let observation = EvidenceFixtureCorpus.externalStorageLoss
        let before = observation
        let evidenceSet = EvidenceSet(
            id: EvidenceFixtureCorpus.ids.evidenceSet,
            members: [EvidenceMembership(observationID: observation.id, reasons: [.sameSubject])],
            ruleID: "EXTERNAL_STORAGE_LIFECYCLE",
            ruleVersion: "1.0.0",
            temporalBounds: EvidenceTimeBounds(
                start: observation.time.observedWallTime,
                end: observation.time.observedWallTime
            ),
            orderingQuality: .totalWithinDomain,
            schemaVersion: Observation.currentSchemaVersion
        )
        let inference = Inference(
            id: EvidenceFixtureCorpus.ids.inference,
            evidenceSetID: evidenceSet.id,
            generatedAt: observation.time.observedWallTime,
            hypothesis: .string("A storage lifecycle changed."),
            evidenceClass: .supported,
            supportingObservationIDs: [observation.id],
            contradictingObservationIDs: [EvidenceFixtureCorpus.networkPathTransition.id],
            alternatives: [],
            missingEvidence: [],
            nextTests: [],
            ruleID: "EXTERNAL_STORAGE_LIFECYCLE",
            ruleVersion: "1.0.0",
            schemaVersion: Observation.currentSchemaVersion,
            packageVersion: "2.4.0"
        )

        XCTAssertTrue(inference.referencesOnly(Set([observation.id, EvidenceFixtureCorpus.networkPathTransition.id])))
        XCTAssertEqual(before, observation)
        XCTAssertEqual(evidenceSet.memberObservationIDs, [observation.id])
    }

    func testNextTestSafetyValidationAcceptsSafeAndRejectsUnsafeEntries() throws {
        let safe = EvidenceFixtureCorpus.safeNextTest
        XCTAssertEqual(try safe.validatedReference().testID, "OBSERVE_STORAGE_RECONNECT")
        XCTAssertEqual(
            try EvidenceFixtureCorpus.safeStorageDisconnect.validatedReference().testID,
            "SAFE_STORAGE_DISCONNECT"
        )

        for entry in [
            EvidenceFixtureCorpus.storageDisconnectOnlyUnmounted,
            EvidenceFixtureCorpus.storageDisconnectOnlyNoWrites,
            EvidenceFixtureCorpus.textOnlyStorageDisconnect,
            EvidenceFixtureCorpus.unsafeStorageDisconnect
        ] {
            XCTAssertThrowsError(try entry.validatedReference()) { error in
                XCTAssertEqual(error as? NextTestValidationIssue, .storagePrerequisiteMissing)
            }
        }

        for entry in [
            EvidenceFixtureCorpus.privilegedNextTest,
            EvidenceFixtureCorpus.hardwareWriteNextTest,
            EvidenceFixtureCorpus.hiddenNetworkNextTest
        ] {
            XCTAssertThrowsError(try entry.validatedReference())
        }
    }

    func testIncidentUsesFrozenWindowsAndDistinguishesIncomplete() {
        let complete = IncidentPackage(
            id: EvidenceFixtureCorpus.ids.incident,
            marker: EvidenceFixtureCorpus.marker,
            status: .complete,
            completedAt: EvidenceFixtureCorpus.marker.wallTime,
            materializedContext: .object(["power": .string("AC")]),
            observationIDs: [EvidenceFixtureCorpus.externalStorageLoss.id]
        )
        XCTAssertEqual(complete.preWindowSeconds, 60)
        XCTAssertEqual(complete.postWindowSeconds, 120)
        XCTAssertEqual(complete.status, .complete)
        XCTAssertEqual(complete.materializedContext, .object(["power": .string("AC")]))

        let incomplete = IncidentPackage(
            id: EvidenceFixtureCorpus.ids.incompleteIncident,
            marker: EvidenceFixtureCorpus.marker,
            status: .incomplete,
            completedAt: nil,
            materializedContext: .object([:]),
            observationIDs: [],
            unknowns: [EvidenceMissing(
                sourceID: .network,
                reason: .incompleteCapture,
                explanation: "Source ended during capture."
            )],
            failureReason: .incompleteCapture
        )
        XCTAssertNotEqual(complete.status, incomplete.status)
        XCTAssertNil(incomplete.completedAt)
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    func testEvidencePackageRequiresEvidenceSetContextForInferenceSupport() {
        let observation = EvidenceFixtureCorpus.externalStorageLoss
        let evidenceSet = EvidenceSet(
            id: EvidenceFixtureCorpus.ids.evidenceSet,
            members: [EvidenceMembership(observationID: observation.id, reasons: [.temporalEligibility(seconds: 15)])],
            ruleID: "EXTERNAL_STORAGE_LIFECYCLE",
            ruleVersion: "1.0.0",
            temporalBounds: EvidenceTimeBounds(
                start: observation.time.observedWallTime,
                end: observation.time.observedWallTime
            ),
            orderingQuality: .totalWithinDomain,
            schemaVersion: Observation.currentSchemaVersion
        )
        let package = EvidencePackage(
            id: EvidenceFixtureCorpus.ids.package,
            schemaVersion: 1,
            productIdentity: "Small Matter",
            systemMetadata: .object([:]),
            captureWindow: EvidenceTimeBounds(
                start: observation.time.observedWallTime,
                end: observation.time.observedWallTime
            ),
            currentState: nil,
            observations: [observation],
            evidenceSets: [evidenceSet],
            inferences: [Inference(
                id: EvidenceFixtureCorpus.ids.inference,
                evidenceSetID: evidenceSet.id,
                generatedAt: observation.time.observedWallTime,
                hypothesis: .string("Storage changed"),
                evidenceClass: .supported,
                supportingObservationIDs: [observation.id],
                contradictingObservationIDs: [],
                alternatives: [],
                missingEvidence: [],
                nextTests: [],
                ruleID: "EXTERNAL_STORAGE_LIFECYCLE",
                ruleVersion: "1.0.0",
                schemaVersion: 1,
                packageVersion: "2.4.0"
            )],
            unknowns: [],
            nextTests: [],
            sourceManifest: Horizon2SourceID.allCases.map {
                EvidenceSourceManifestEntry(
                    sourceID: $0,
                    disposition: Horizon2EvidenceConfiguration.sourceDispositions[$0]!,
                    userFacingEvidenceAllowed: Horizon2SourceCapability.canProvideUserFacingEvidence($0)
                )
            },
            redactionManifest: [],
            exportPolicyVersion: "1.0.0"
        )
        XCTAssertTrue(package.hasConsistentInferenceReferences())
    }

    func testSourceDispositionManifestAgreesWithStaticConfiguration() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let manifestURL = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/horizon2/R6_1_MANIFEST.json")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "The private R6.1 planning manifest is not part of the public export"
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ManifestDocument.self, from: data)
        let expected = Dictionary(uniqueKeysWithValues: Horizon2EvidenceConfiguration.sourceDispositions.map { (
            $0.key.rawValue,
            $0.value.rawValue
        ) })
        XCTAssertEqual(manifest.sourceDispositions, expected)
        XCTAssertFalse(manifest.implementationAuthorized)
        XCTAssertEqual(manifest.specVersion, Horizon2EvidenceConfiguration.specificationVersion)
        XCTAssertEqual(manifest.initialRules.keys.sorted(), Horizon2EvidenceConfiguration.initialRuleIDs.sorted())
        XCTAssertEqual(Set(manifest.deferredRules.keys), Horizon2EvidenceConfiguration.deferredRuleIDs)
        XCTAssertEqual(manifest.frozenConstants["retention_default_days"], 7)
        XCTAssertEqual(manifest.frozenConstants["retention_maximum_days"], 30)
        XCTAssertEqual(manifest.frozenConstants["journal_maximum_bytes"], 16 * 1024 * 1024)
        XCTAssertEqual(manifest.frozenConstants["incident_pre_window_seconds"], 60)
        XCTAssertEqual(manifest.frozenConstants["incident_post_window_seconds"], 120)
        XCTAssertEqual(manifest.frozenConstants["collector_queue_maximum"], 2048)
        XCTAssertEqual(manifest.frozenConstants["pending_write_queue_maximum"], 2048)
        XCTAssertGreaterThan(Horizon2EvidenceConfiguration.collectorQueueCapacity, 0)
        XCTAssertLessThanOrEqual(
            Horizon2EvidenceConfiguration.collectorQueueCapacity,
            Horizon2EvidenceConfiguration.collectorQueueMaximum
        )
        XCTAssertEqual(manifest.frozenConstants["temporal_eligibility_seconds"], 15)
        XCTAssertEqual(manifest.frozenConstants["sqlite_schema_version"], 1)
    }

    func testInMemoryJournalIsDeterministicAndRejectsMutationByID() async throws {
        let journal = InMemoryEvidenceJournal()
        let observation = EvidenceFixtureCorpus.externalStorageLoss
        try await journal.append(observation)
        let initialBytes = await journal.retentionStatus().bytes
        XCTAssertGreaterThan(initialBytes, 1)
        XCTAssertNotEqual(initialBytes, 1)
        try await journal.append(observation)
        let duplicateBytes = await journal.retentionStatus().bytes
        XCTAssertEqual(duplicateBytes, initialBytes)
        let fetched = await journal.observation(id: observation.id)
        let storageIDs = await journal.query(EvidenceJournalQuery(sourceID: .storage)).map(\.id)
        XCTAssertEqual(fetched, observation)
        XCTAssertEqual(storageIDs, [observation.id])

        let changed = Observation(
            id: observation.id,
            domain: observation.domain,
            eventKind: observation.eventKind,
            sourceID: observation.sourceID,
            subject: observation.subject,
            provenance: observation.provenance,
            time: observation.time,
            availability: .unknown(.notObserved),
            previousState: observation.previousState,
            currentState: observation.currentState,
            attributes: observation.attributes,
            sensitivity: observation.sensitivity
        )
        do {
            try await journal.append(changed)
            XCTFail("A changed payload must not replace an immutable observation.")
        } catch {
            XCTAssertEqual(error as? EvidenceJournalError, .observationPayloadMismatch)
        }
        let rejectedBytes = await journal.retentionStatus().bytes
        XCTAssertEqual(rejectedBytes, initialBytes)
    }
}

private struct ManifestDocument: Decodable {
    let specVersion: String
    let sourceDispositions: [String: String]
    let initialRules: [String: [String]]
    let deferredRules: [String: [String]]
    let frozenConstants: [String: Int]
    let implementationAuthorized: Bool

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case sourceDispositions = "source_dispositions"
        case initialRules = "initial_rules"
        case deferredRules = "deferred_rules"
        case frozenConstants = "frozen_constants"
        case implementationAuthorized = "implementation_authorized"
    }
}

private enum EvidenceFixtureCorpus {
    static let ids = FixtureIDs()
    static let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let restartedRunID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let bootSession = "boot-fixed-1"
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    static let externalStorageLoss = makeObservation(
        id: ids.storageObservation,
        sourceID: .storage,
        domain: .storage,
        eventKind: .storageDiskLifecycle,
        sequence: 1,
        currentState: .integer(0),
        attributes: .object(["mount": .object(["volumeName": .string("fixture-volume")])]),
        sensitivity: EvidenceSensitivityRegistry(fields: [EvidenceFieldSensitivity(
            path: EvidenceFieldPath("attributes.mount.volumeName"),
            classification: .filesystemMetadata,
            pseudonymization: .required(scope: "package")
        )])
    )

    static let networkPathTransition = makeObservation(
        id: ids.networkObservation,
        sourceID: .network,
        domain: .network,
        eventKind: .networkPathTransition,
        sequence: 2,
        currentState: .string("satisfied")
    )

    // These named streams are intentionally typed fixture corpus members. The
    // deferred/future streams cannot be mistaken for an enabled production rule.
    static let unrelatedEvents = [externalStorageLoss, networkPathTransition]
    static let contradictoryEvidence = [externalStorageLoss, missingEvidence]
    static let duplicateEvent = [externalStorageLoss, externalStorageLoss]
    static let outOfOrderEvent = [networkPathTransition, externalStorageLoss]

    static let missingEvidence = makeObservation(
        id: ids.missingObservation,
        sourceID: .display,
        domain: .display,
        eventKind: .sourceUnavailable,
        sequence: 3,
        availability: .unavailable(.sourceUnavailable),
        sourceOccurrence: nil
    )

    static let afterProcessRestart = makeObservation(
        id: ids.restartObservation,
        sourceID: .storage,
        domain: .storage,
        eventKind: .storageMountLifecycle,
        sequence: 1,
        processRunID: restartedRunID
    )

    static let sleepWakeBoundary = makeObservation(
        id: ids.sleepObservation,
        sourceID: .sleepWake,
        domain: .sleepWake,
        eventKind: .sleepWakeBoundary(.sleepWake),
        sequence: 4,
        lifecycleBoundary: .sleepWake
    )

    static let marker = IncidentMarker(
        observationID: externalStorageLoss.id,
        wallTime: externalStorageLoss.time.observedWallTime,
        localSequence: externalStorageLoss.time.localSequence
    )

    static let safeNextTest = NextTestCatalogEntry(
        reference: NextTestReference(
            testID: "OBSERVE_STORAGE_RECONNECT",
            catalogVersion: "1.0.0",
            purpose: "Observe a reconnect",
            evidenceExpected: "A mount lifecycle fact"
        ),
        prerequisites: [],
        prerequisiteExplanation: "No mounted volume is actively being written.",
        riskClass: .safe,
        actionKind: .observe,
        userAction: "Observe the next reconnect.",
        stoppingCondition: "Stop when the lifecycle is recorded.",
        expectedObservations: "A storage lifecycle observation.",
        safetyWarning: "Do not disconnect an active volume.",
        catalogProvenance: "I1 fixture catalog"
    )

    static let privilegedNextTest = unsafeNextTest(.privileged)
    static let hardwareWriteNextTest = unsafeNextTest(.hardwareWrite)
    static let hiddenNetworkNextTest = unsafeNextTest(.hiddenNetwork)
    static let safeStorageDisconnect = storageDisconnect([.storageSafelyUnmounted, .noActiveWrites])
    static let storageDisconnectOnlyUnmounted = storageDisconnect([.storageSafelyUnmounted])
    static let storageDisconnectOnlyNoWrites = storageDisconnect([.noActiveWrites])
    static let textOnlyStorageDisconnect = storageDisconnect(
        [],
        explanation: "The storage is safely unmounted and no writes are active."
    )
    static let unsafeStorageDisconnect = storageDisconnect([])

    private static func storageDisconnect(_ prerequisites: [NextTestPrerequisite],
                                          explanation: String? = nil) -> NextTestCatalogEntry {
        NextTestCatalogEntry(
            reference: NextTestReference(
                testID: prerequisites.count == 2 ? "SAFE_STORAGE_DISCONNECT" : "UNSAFE_STORAGE_DISCONNECT",
                catalogVersion: "1.0.0",
                purpose: "Disconnect storage",
                evidenceExpected: "A storage lifecycle fact"
            ),
            prerequisites: prerequisites,
            prerequisiteExplanation: explanation,
            riskClass: .caution,
            actionKind: .disconnectStorage,
            userAction: "Disconnect the storage.",
            stoppingCondition: "Stop after the lifecycle is recorded.",
            expectedObservations: "A storage lifecycle observation.",
            safetyWarning: "Do not disconnect active storage.",
            catalogProvenance: "I1.1 fixture catalog"
        )
    }

    private static func unsafeNextTest(_ actionKind: NextTestActionKind) -> NextTestCatalogEntry {
        NextTestCatalogEntry(
            reference: NextTestReference(
                testID: "UNSAFE",
                catalogVersion: "1.0.0",
                purpose: "Unsafe fixture",
                evidenceExpected: "None"
            ),
            prerequisites: [],
            riskClass: .caution,
            actionKind: actionKind,
            userAction: "Do unsafe work.",
            stoppingCondition: "",
            expectedObservations: "None",
            safetyWarning: "Unsafe fixture.",
            catalogProvenance: "I1 fixture"
        )
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private static func makeObservation(
        id: UUID,
        sourceID: Horizon2SourceID,
        domain: EvidenceDomain,
        eventKind: EvidenceEventKind,
        sequence: UInt64,
        processRunID: UUID = runID,
        availability: EvidenceAvailability = .available,
        currentState: EvidenceValue? = nil,
        attributes: EvidenceValue? = nil,
        sensitivity: EvidenceSensitivityRegistry = .init(),
        sourceOccurrence: EvidenceSourceOccurrence? = EvidenceSourceOccurrence(
            wallTime: start,
            continuousNanoseconds: 1_000_000,
            quality: .exact
        ),
        lifecycleBoundary: EvidenceLifecycleBoundary = .none
    ) -> Observation {
        let subject = EvidenceSubject(
            type: sourceID == .storage ? .storageDisk : .systemContext,
            identityDigest: "fixture-\(sourceID.rawValue)",
            quality: .qualified,
            safeDisplayLabel: "Fixture"
        )
        let provenance = EvidenceProvenance(
            sourceID: sourceID,
            apiName: "Fixture API",
            apiVersion: "1",
            captureChannel: "I1_FIXTURE",
            sourceTimestampQuality: sourceOccurrence?.quality ?? .unavailable,
            normalizationRuleID: "FIXTURE_NORMALIZE",
            normalizationRuleVersion: "1.0.0",
            hostScope: .provenOnTestedHost,
            rawReferenceDigest: nil
        )
        let time = EvidenceTime(
            observedWallTime: start.addingTimeInterval(Double(sequence)),
            continuousNanoseconds: UInt64(sequence) * 1_000_000,
            processUptimeNanoseconds: UInt64(sequence) * 1_000_000,
            processRunID: processRunID,
            bootSessionID: bootSession,
            localSequence: sequence,
            sourceTimestampQuality: sourceOccurrence?.quality ?? .unavailable,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: sourceID,
                processRunID: processRunID,
                clockDomainID: "fixture-clock"
            ),
            sourceOccurrence: sourceOccurrence,
            lifecycleBoundary: lifecycleBoundary
        )
        var values: [String: EvidenceValue] = [:]
        if let attributes {
            if case let .object(object) = attributes {
                values = object
            }
        }
        return Observation(
            id: id,
            domain: domain,
            eventKind: eventKind,
            sourceID: sourceID,
            subject: subject,
            provenance: provenance,
            time: time,
            availability: availability,
            previousState: nil,
            currentState: currentState,
            attributes: values,
            sensitivity: sensitivity
        )
    }

    struct FixtureIDs {
        let storageObservation = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let networkObservation = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let missingObservation = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let restartObservation = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        let sleepObservation = UUID(uuidString: "20000000-0000-0000-0000-000000000005")!
        let evidenceSet = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let inference = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let incident = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let incompleteIncident = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
        let package = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
        // Why: cohesive reviewed boundary.
    }
} // swiftlint:disable:this file_length
