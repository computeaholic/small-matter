import Foundation
@testable import Tunix
import XCTest

// swiftformat:disable trailingCommas
// swiftlint:disable:next type_body_length
final class CorrelationEngineTests: XCTestCase {
    private let runID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private let epoch = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    private let start = Date(timeIntervalSince1970: 1_700_100_000)

    func testStorageGroupsSameQualifiedSubjectAtInclusiveBoundaryButUsesAnchoredWindow() throws {
        let observations = [storage(1, seconds: 0), storage(2, seconds: 15), storage(3, seconds: 28)]
        let sets = try engine().correlate(incident: incident(observations), observations: observations)
        XCTAssertEqual(sets.map(\.memberObservationIDs.count).sorted(), [1, 2])
        XCTAssertEqual(
            sets.first(where: { $0.members.count == 2 })?.memberObservationIDs,
            [observations[0].id, observations[1].id]
        )
    }

    func testContinuousClockDisagreementCannotCreateOversizedSpan() throws {
        let values = [
            storage(1, seconds: 0, continuousNanoseconds: 15_000_000_000),
            storage(2, seconds: 1, continuousNanoseconds: 0),
            storage(3, seconds: 2, continuousNanoseconds: 30_000_000_000)
        ]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.map(\.memberObservationIDs.count).sorted(), [1, 2])
        for set in sets where set.members.count > 1 {
            let members = set.memberObservationIDs.compactMap { id in values.first { $0.id == id } }
            let coordinates = members.compactMap(\.time.continuousNanoseconds)
            let minimum = try XCTUnwrap(coordinates.min())
            let maximum = try XCTUnwrap(coordinates.max())
            XCTAssertLessThanOrEqual(maximum - minimum, 15_000_000_000)
        }
    }

    func testContinuousClockBoundaryMatrixUsesIntegerNanoseconds() throws {
        let boundaryValues = [
            (14_999_000_000 as UInt64, true),
            (15_000_000_000 as UInt64, true),
            (15_001_000_000 as UInt64, false)
        ]

        for (offset, shouldGroup) in boundaryValues {
            let values = [
                storage(10, seconds: 0, continuousNanoseconds: 0),
                storage(11, seconds: 1, continuousNanoseconds: offset)
            ]
            let sets = try engine().correlate(incident: incident(values), observations: values)
            XCTAssertEqual(sets.count, shouldGroup ? 1 : 2, "Unexpected result for \(offset)ns")
            if shouldGroup {
                XCTAssertTrue(sets[0].members[0].reasons.contains(
                    .temporalEligibility(seconds: 15, basis: .continuousClock)
                ))
            }
        }
    }

    func testLegacyTemporalReasonDecodesWithoutBasis() throws {
        let legacyJSON = Data(#"{"kind":"TEMPORAL_ELIGIBILITY","value":15}"#.utf8)
        let reason = try JSONDecoder().decode(EvidenceMembershipReason.self, from: legacyJSON)

        XCTAssertEqual(
            reason,
            .temporalEligibility(seconds: 15, basis: .legacyUnspecified)
        )
    }

    func testCurrentCorrelationOutputUsesVersionedRuleAndEvidenceSetSchema() throws {
        let values = [storage(60, seconds: 0), storage(61, seconds: 1)]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].ruleVersion, InitialCorrelationRule.currentVersion)
        XCTAssertEqual(sets[0].evidenceSetSchemaVersion, EvidenceSet.currentSchemaVersion)
        XCTAssertEqual(EvidenceSet.currentSchemaVersion, 2)
        XCTAssertTrue(sets[0].members.flatMap(\.reasons).contains(
            .temporalEligibility(seconds: 15, basis: .continuousClock)
        ))
    }

    func testVersionedEvidenceSetIDsRemainStableAcrossOneHundredPermutations() throws {
        let values = [
            storage(70, seconds: 0),
            storage(71, seconds: 2),
            storage(72, seconds: 4)
        ]
        let package = incident(values)
        let expected = try engine().correlate(incident: package, observations: values)
        var observedIDs = Set<[UUID]>()

        for iteration in 0 ..< 100 {
            let offset = iteration % values.count
            let permutation = Array(values[offset...]) + Array(values[..<offset])
            let output = try engine().correlate(incident: package, observations: permutation)
            observedIDs.insert(output.map(\.id))
        }

        XCTAssertEqual(observedIDs, [expected.map(\.id)])
        XCTAssertTrue(expected.allSatisfy { $0.ruleVersion == InitialCorrelationRule.currentVersion })
    }

    func testWallFallbackBoundaryMatrixUsesOneBasis() throws {
        let values = [
            storage(20, seconds: 0, continuousTimestampAvailable: false),
            storage(21, seconds: 15, continuousTimestampAvailable: false),
            storage(22, seconds: 15.001, continuousTimestampAvailable: false)
        ]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.map(\.memberObservationIDs.count).sorted(), [1, 2])
        XCTAssertTrue(sets.contains { set in
            set.members.count == 2 && set.members[0].reasons.contains(
                .temporalEligibility(seconds: 15, basis: .wallClockFallback)
            )
        })
    }

    func testMixedTimestampAvailabilityUsesConservativeWallFallback() throws {
        let values = [
            storage(30, seconds: 0, continuousNanoseconds: 0),
            storage(31, seconds: 1, continuousTimestampAvailable: false),
            storage(32, seconds: 2, continuousNanoseconds: 2_000_000_000)
        ]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].members.count, 3)
        XCTAssertTrue(sets[0].members[0].reasons.contains(
            .temporalEligibility(seconds: 15, basis: .wallClockFallback)
        ))
    }

    func testUnknownTimingCannotCreateMultiMemberTemporalClaim() throws {
        let values = [
            storage(40, seconds: 0, continuousTimestampAvailable: false, timestampQuality: .unknown),
            storage(41, seconds: 1, continuousTimestampAvailable: false, timestampQuality: .unknown)
        ]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.map(\.memberObservationIDs.count), [1, 1])
    }

    func testWallJumpsDoNotOverrideContinuousMembershipOrCanonicalOrder() throws {
        let first = storage(50, seconds: 0, wallSeconds: 10, continuousNanoseconds: 0)
        let second = storage(51, seconds: 1, wallSeconds: 0, continuousNanoseconds: 10_000_000_000)
        let values = [first, second]
        let sets = try engine().correlate(incident: incident(values), observations: values)

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].memberObservationIDs, [second.id, first.id])
        XCTAssertTrue(sets[0].members[0].reasons.contains(
            .temporalEligibility(seconds: 15, basis: .continuousClock)
        ))
    }

    func testStorageDoesNotGroupWeakDifferentSubjectsOrDiskAndVolume() throws {
        let weak = [
            storage(1, seconds: 0, quality: .weak, digest: nil),
            storage(2, seconds: 1, quality: .weak, digest: nil)
        ]
        XCTAssertEqual(try engine().correlate(incident: incident(weak), observations: weak).count, 2)
        let mixed = [storage(3, seconds: 0), storage(4, seconds: 1, subjectType: .mountedVolume)]
        XCTAssertEqual(try engine().correlate(incident: incident(mixed), observations: mixed).count, 2)
        let unavailable = [
            storage(5, seconds: 0, quality: .unavailable, digest: nil),
            storage(6, seconds: 1, quality: .unavailable, digest: nil)
        ]
        XCTAssertEqual(try engine().correlate(incident: incident(unavailable), observations: unavailable).count, 2)
    }

    func testNetworkGroupsOnlyItsOwnBoundedSequenceAndPowerIsFactOnly() throws {
        let network = [network(1, seconds: 0), network(2, seconds: 14)]
        let power = power(3, seconds: 1)
        let sets = try engine().correlate(incident: incident(network + [power]), observations: network + [power])
        XCTAssertEqual(sets.count, 1)
        XCTAssertFalse(sets[0].members.flatMap(\.reasons).contains(.sameSubject))
        XCTAssertFalse(sets.flatMap(\.memberObservationIDs).contains(power.id))
    }

    func testProcessEpochAndSleepBoundariesPreventGrouping() throws {
        let process = storage(1, seconds: 0, process: UUID())
        let epochChange = storage(2, seconds: 1, epoch: UUID())
        let boundary = storage(3, seconds: 2, lifecycle: .sleepWake)
        let values = [process, epochChange, boundary]
        XCTAssertEqual(try engine().correlate(incident: incident(values), observations: values).count, 2)
    }

    func testCorrelationIsPermutationInvariantAndDoesNotMutateObservations() throws {
        let values = [storage(1, seconds: 0), storage(2, seconds: 2), network(3, seconds: 3)]
        let before = try values.map { try $0.deterministicData() }
        let first = try engine().correlate(incident: incident(values), observations: values)
        let second = try engine().correlate(incident: incident(values), observations: values.reversed())
        XCTAssertEqual(first, second)
        XCTAssertEqual(try values.map { try $0.deterministicData() }, before)
    }

    func testInputValidationRejectsMissingAndConflictingObservation() throws {
        let value = storage(1, seconds: 0)
        let missing = incident([value, storage(2, seconds: 1)])
        XCTAssertThrowsError(try engine().correlate(incident: missing, observations: [value])) { error in
            XCTAssertEqual(error as? CorrelationEngineError, .missingObservation(missing.observationIDs[1]))
        }
        var changed = value
        changed = Observation(
            id: value.id,
            domain: value.domain,
            eventKind: value.eventKind,
            sourceID: value.sourceID,
            subject: value.subject,
            provenance: value.provenance,
            time: value.time,
            availability: .unknown(.notObserved),
            currentState: value.currentState
        )
        XCTAssertThrowsError(
            try engine().correlate(incident: incident([value]), observations: [value, changed])
        ) { error in
            XCTAssertEqual(error as? CorrelationEngineError, .duplicateObservationConflict(value.id))
        }
    }

    func testSQLiteEvidenceSetRoundTripIsIdempotentAndCascadesOnIncidentDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "i6-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let values = [storage(1, seconds: 0), storage(2, seconds: 1)]
        for value in values {
            try await journal.append(value)
        }
        let package = incident(values)
        try await journal.persist(incident: package)
        let sets = try engine().correlate(incident: package, observations: values)
        try await journal.persistEvidenceSets(incidentID: package.id, sets: sets)
        try await journal.persistEvidenceSets(incidentID: package.id, sets: sets)
        let persisted = await journal.evidenceSets(incidentID: package.id)
        XCTAssertEqual(persisted, sets)
        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let reopenedSets = await reopened.evidenceSets(incidentID: package.id)
        XCTAssertEqual(reopenedSets, sets)
        let violations = await reopened.foreignKeyViolationsForTesting()
        XCTAssertEqual(violations, [])
        try await reopened.deleteIncident(id: package.id)
        let deletedSets = await reopened.evidenceSets(incidentID: package.id)
        XCTAssertTrue(deletedSets.isEmpty)
    }

    func testLegacyAndCurrentEvidenceSetsCoexistAndServiceReturnsOnlyCurrentOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "i6-2-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let values = [storage(80, seconds: 0), storage(81, seconds: 1)]
        for value in values {
            try await journal.append(value)
        }
        let package = incident(values)
        try await journal.persist(incident: package)

        let current = try engine().correlate(incident: package, observations: values)
        let currentSet = try XCTUnwrap(current.first(where: { $0.members.count > 1 }))
        let legacy = try legacyFixture(from: currentSet, incidentID: package.id)

        XCTAssertEqual(legacy.ruleVersion, InitialCorrelationRule.legacyVersion)
        XCTAssertEqual(legacy.evidenceSetSchemaVersion, EvidenceSet.legacySchemaVersion)
        XCTAssertNotEqual(legacy.id, currentSet.id)
        XCTAssertTrue(legacy.members.flatMap(\.reasons).contains(
            .temporalEligibility(seconds: 15, basis: .legacyUnspecified)
        ))

        try await journal.persistEvidenceSets(incidentID: package.id, sets: [legacy])
        try await journal.persistEvidenceSets(incidentID: package.id, sets: current)
        let beforeReopen = await journal.evidenceSets(incidentID: package.id)
        XCTAssertEqual(beforeReopen.count, current.count + 1)
        XCTAssertTrue(beforeReopen.contains(legacy))
        XCTAssertTrue(beforeReopen.contains(currentSet))

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let historicalAndCurrent = await reopened.evidenceSets(incidentID: package.id)
        XCTAssertEqual(historicalAndCurrent.count, current.count + 1)
        XCTAssertTrue(historicalAndCurrent.contains(legacy))
        XCTAssertTrue(historicalAndCurrent.contains(currentSet))

        let serviceOutput = try await IncidentCorrelationService(journal: reopened).process(incidentID: package.id)
        XCTAssertEqual(serviceOutput, current)
        let afterReprocessing = await reopened.evidenceSets(incidentID: package.id)
        XCTAssertEqual(afterReprocessing, historicalAndCurrent)
    }

    private func engine() -> CorrelationEngine {
        CorrelationEngine()
    }

    private func legacyFixture(from current: EvidenceSet, incidentID: UUID) throws -> EvidenceSet {
        let legacyID = EvidenceIdentityDigest.makeUUID(
            scope: "horizon2-evidence-set",
            material: [incidentID.uuidString, current.ruleID ?? "", InitialCorrelationRule.legacyVersion]
                + current.memberObservationIDs.map(\.uuidString)
        )!
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["id"] = legacyID.uuidString
        object["ruleVersion"] = InitialCorrelationRule.legacyVersion
        object["evidenceSetSchemaVersion"] = EvidenceSet.legacySchemaVersion
        if var members = object["members"] as? [[String: Any]] {
            for index in members.indices {
                if var reasons = members[index]["reasons"] as? [[String: Any]] {
                    for reasonIndex in reasons.indices {
                        reasons[reasonIndex].removeValue(forKey: "basis")
                    }
                    members[index]["reasons"] = reasons
                }
            }
            object["members"] = members
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(EvidenceSet.self, from: legacyData)
    }

    private func incident(_ observations: [Observation]) -> IncidentPackage {
        IncidentPackage(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
            marker: IncidentMarker(wallTime: start),
            status: .complete,
            completedAt: start,
            materializedContext: .object([:]),
            observationIDs: observations.map(\.id)
        )
    }

    private func storage(
        _ index: Int,
        seconds: TimeInterval,
        quality: EvidenceIdentityQuality = .qualified,
        digest: String? = "disk-1",
        subjectType: EvidenceSubjectType = .storageDisk,
        process: UUID? = nil,
        epoch: UUID? = nil,
        lifecycle: EvidenceLifecycleBoundary = .none,
        wallSeconds: TimeInterval? = nil,
        continuousNanoseconds: UInt64? = nil,
        continuousTimestampAvailable: Bool = true,
        timestampQuality: EvidenceTimestampQuality = .exact
    ) -> Observation {
        make(
            index: index,
            domain: .storage,
            eventKind: subjectType == .mountedVolume
                ? .storageMountLifecycle
                : .storageDiskLifecycle,
            source: .storage,
            subject: EvidenceSubject(
                type: subjectType,
                identityDigest: digest,
                quality: quality,
                safeDisplayLabel: "fixture"
            ),
            seconds: seconds,
            wallSeconds: wallSeconds,
            continuousNanoseconds: continuousNanoseconds,
            continuousTimestampAvailable: continuousTimestampAvailable,
            timestampQuality: timestampQuality,
            process: process ?? runID,
            epoch: epoch ?? self.epoch,
            lifecycle: lifecycle
        )
    }

    private func network(_ index: Int, seconds: TimeInterval) -> Observation {
        make(
            index: index,
            domain: .network,
            eventKind: .networkPathTransition,
            source: .network,
            subject: EvidenceSubject(
                type: .networkInterface,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: nil
            ),
            seconds: seconds
        )
    }

    private func power(_ index: Int, seconds: TimeInterval) -> Observation {
        make(
            index: index,
            domain: .power,
            eventKind: .powerSourceTransition,
            source: .power,
            subject: EvidenceSubject(
                type: .powerSource,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: nil
            ),
            seconds: seconds
        )
    }

    // swiftlint:disable:next function_body_length function_parameter_count
    private func make(
        index: Int,
        domain: EvidenceDomain,
        eventKind: EvidenceEventKind,
        source: Horizon2SourceID,
        subject: EvidenceSubject,
        seconds: TimeInterval,
        wallSeconds: TimeInterval? = nil,
        continuousNanoseconds: UInt64? = nil,
        continuousTimestampAvailable: Bool = true,
        timestampQuality: EvidenceTimestampQuality = .exact,
        process: UUID? = nil,
        epoch: UUID? = nil,
        lifecycle: EvidenceLifecycleBoundary = .none
    ) -> Observation {
        let process = process ?? runID
        let epoch = epoch ?? self.epoch
        let time = EvidenceTime(
            observedWallTime: start.addingTimeInterval(wallSeconds ?? seconds),
            continuousNanoseconds: continuousTimestampAvailable
                ? continuousNanoseconds ?? UInt64(seconds * 1_000_000_000)
                : nil,
            processUptimeNanoseconds: UInt64(seconds * 1_000_000_000),
            processRunID: process,
            bootSessionID: "fixture-boot",
            localSequence: UInt64(index),
            sourceTimestampQuality: timestampQuality,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: source,
                processRunID: process,
                clockDomainID: "fixture-clock"
            ),
            sourceOccurrence: nil,
            lifecycleBoundary: lifecycle,
            correlationEpochID: epoch
        )
        var sensitivityFields = [EvidenceFieldSensitivity(
            path: EvidenceFieldPath("currentState"),
            classification: .none,
            pseudonymization: .notApplicable
        )]
        if subject.identityDigest != nil {
            sensitivityFields.append(EvidenceFieldSensitivity(
                path: EvidenceFieldPath("subject.identityDigest"),
                classification: .deviceMetadata,
                pseudonymization: .required(scope: "test")
            ))
        }
        let sensitivity = EvidenceSensitivityRegistry(fields: sensitivityFields)
        return Observation(
            id: UUID(uuidString: String(
                format: "73000000-0000-0000-0000-%012d",
                index
            ))!,
            domain: domain,
            eventKind: eventKind,
            sourceID: source,
            subject: subject,
            provenance: EvidenceProvenance(
                sourceID: source,
                apiName: "fixture",
                apiVersion: "1",
                captureChannel: "test",
                sourceTimestampQuality: timestampQuality,
                normalizationRuleID: "fixture",
                normalizationRuleVersion: "1",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: nil
            ),
            time: time,
            currentState: .string("fixture"),
            sensitivity: sensitivity
        )
    }
} // swiftlint:disable:this file_length
