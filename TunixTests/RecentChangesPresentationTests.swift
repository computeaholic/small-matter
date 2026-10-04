// swiftlint:disable line_length trailing_comma
import Foundation
@testable import Tunix
import XCTest

@MainActor
final class RecentChangesPresentationTests: XCTestCase {
    func testLoadedFixturePresentsFactsAndSupplementalNetwork() async {
        let model = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=loaded"])
        )

        await model.refresh()

        XCTAssertEqual(model.state, .availableWithChanges)
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertTrue(model.rows.contains { $0.title == "Storage device connected" })
        XCTAssertTrue(model.rows.contains { $0.title == "Volume became available" })
        XCTAssertTrue(model.rows.contains { $0.title == "Power source changed from AC to Battery" })
        XCTAssertTrue(model.rows.contains { $0.title == "Network path became unavailable" && $0.isSupplemental })
        XCTAssertTrue(model.rows.allSatisfy { $0.statusText == "Observed" })
        XCTAssertTrue(model.rows.allSatisfy { !$0.title.localizedCaseInsensitiveContains("failed") })
    }

    func testLoadedFixtureDetailIsPrivacySafeAndExplainsSupplementalNetwork() async throws {
        let journal = RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=loaded"])
        let model = RecentChangesViewModel(journal: journal)
        await model.refresh()

        let network = try XCTUnwrap(model.rows.first(where: { $0.isSupplemental }))
        let detail = try XCTUnwrap(model.detail(for: network.id))
        XCTAssertEqual(detail.row.statusText, "Observed")
        XCTAssertEqual(detail.row.sourceText, "Network.framework / NWPathMonitor")
        XCTAssertTrue(detail.supplementalLimitation?.contains("does not identify hardware") == true)
        let rendered = detail.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("fixture-storage-digest"))
        XCTAssertFalse(rendered.contains("rawReferenceDigest"))
        XCTAssertFalse(rendered.contains(network.id.uuidString))
    }

    func testEmptyUnavailableAndCapacityStatesRemainDistinct() async {
        let empty = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=empty"])
        )
        await empty.refresh()
        XCTAssertEqual(empty.state, .availableEmpty)
        XCTAssertTrue(empty.rows.isEmpty)

        let unavailable = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=unavailable"])
        )
        await unavailable.refresh()
        XCTAssertEqual(unavailable.state, .journalUnavailable)

        let capacity = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=capacity"])
        )
        await capacity.refresh()
        XCTAssertEqual(capacity.state, .journalCapacityUnavailable)
    }

    func testCapacityRecoveryRemovesOnlyUnprotectedEvidence() async throws {
        let observation = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001099")),
            sequence: 1
        )
        let journal = InMemoryEvidenceJournal(
            observations: [observation],
            availability: .capacityUnavailable
        )
        let model = RecentChangesViewModel(journal: journal)

        await model.refresh()
        XCTAssertEqual(model.state, .journalCapacityUnavailable)

        await model.recoverCapacity()

        let status = await journal.retentionStatus()
        let remainingObservation = await journal.observation(id: observation.id)
        XCTAssertEqual(status.availability, .available)
        XCTAssertNil(remainingObservation)
        XCTAssertTrue(model.capacityRecoveryMessage?.contains("Removed 1") == true)
    }

    func testIncompleteCoverageIsStatusNotAnObservation() async {
        let model = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=incomplete"])
        )

        await model.refresh()

        XCTAssertEqual(model.state, .incompleteEvidence)
        XCTAssertEqual(model.coverageWarning, "Some changes may be missing.")
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertFalse(model.rows.contains { $0.title.localizedCaseInsensitiveContains("missing") })
    }

    func testUnknownObservationKeepsAvailabilityAndIdentityExplicit() async throws {
        let model = RecentChangesViewModel(
            journal: RecentChangesFixture.journal(arguments: ["-UITestingRecentChanges=unknown"])
        )

        await model.refresh()

        let row = try XCTUnwrap(model.rows.first)
        let detail = try XCTUnwrap(model.detail(for: row.id))
        XCTAssertEqual(row.identityQualityText, "Unavailable")
        XCTAssertTrue(detail.availabilityText?.contains("identity unavailable") == true)
    }

    func testUnknownFutureAttributeIsNotRendered() async throws {
        let observation = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001001")),
            sequence: 1,
            attributes: ["futureSecret": .string("must not appear")]
        )
        let model = RecentChangesViewModel(journal: InMemoryEvidenceJournal(observations: [observation]))

        await model.refresh()

        let detail = try XCTUnwrap(model.detail(for: observation.id))
        let rendered = detail.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("futureSecret"))
        XCTAssertFalse(rendered.contains("must not appear"))
        XCTAssertNil(detail.fields.first(where: { $0.label == "Attributes" }))
    }

    func testBaselineAndRepeatedConfirmationFactsStayOutOfRecentChanges() async throws {
        let baseline = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001010")),
            sequence: 1,
            attributes: ["semanticRole": .string(StorageRawSemanticRole.baseline.rawValue)]
        )
        let confirmation = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001011")),
            sequence: 2,
            attributes: ["semanticRole": .string(StorageRawSemanticRole.confirmation.rawValue)]
        )
        let transition = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001012")),
            sequence: 3,
            attributes: [
                "semanticRole": .string(StorageRawSemanticRole.transition.rawValue),
                "lifecycle": .string("diskAppeared"),
            ]
        )
        let model = RecentChangesViewModel(journal: InMemoryEvidenceJournal(observations: [baseline, confirmation, transition]))

        await model.refresh()

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.title, "Storage device connected")
    }

    func testUncertainStorageFactsStayOutOfRecentChanges() async throws {
        let uncertain = try makeObservation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001013")),
            sequence: 4,
            attributes: [
                "semanticRole": .string(StorageRawSemanticRole.uncertain.rawValue),
                "lifecycle": .string("diskAppeared"),
            ]
        )
        let model = RecentChangesViewModel(journal: InMemoryEvidenceJournal(observations: [uncertain]))

        await model.refresh()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.state, .availableEmpty)
    }

    func testNewestFirstBoundAndStableTieBreaking() async {
        let sameTime = Date(timeIntervalSince1970: 1_735_689_600)
        let observations = (1 ... 205).map { sequence in
            makeObservation(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", sequence))!,
                sequence: UInt64(sequence),
                date: sameTime
            )
        }
        let journal = InMemoryEvidenceJournal(observations: observations)
        let result = await journal.query(EvidenceJournalQuery(limit: 200, newestFirst: true))

        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first?.time.localSequence, 205)
        XCTAssertEqual(result.last?.time.localSequence, 6)
        XCTAssertFalse(result.contains { $0.time.localSequence == 5 })
    }

    private func makeObservation(
        id: UUID,
        sequence: UInt64,
        date: Date = Date(timeIntervalSince1970: 1_735_689_600),
        attributes: [String: EvidenceValue] = [:]
    ) -> Observation {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let sourceID = Horizon2SourceID.storage
        return Observation(
            id: id,
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            sourceID: sourceID,
            subject: EvidenceSubject(
                type: .storageDisk,
                identityDigest: "private-digest",
                quality: .qualified,
                safeDisplayLabel: "Storage disk"
            ),
            provenance: EvidenceProvenance(
                sourceID: sourceID,
                apiName: "Disk Arbitration",
                apiVersion: nil,
                captureChannel: "unit test",
                sourceTimestampQuality: .exact,
                normalizationRuleID: "TEST",
                normalizationRuleVersion: "1.0.0",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: "private-raw-digest"
            ),
            time: EvidenceTime(
                observedWallTime: date,
                continuousNanoseconds: sequence,
                processUptimeNanoseconds: sequence,
                processRunID: runID,
                bootSessionID: "test-boot",
                localSequence: sequence,
                sourceTimestampQuality: .exact,
                orderingDomain: EvidenceOrderingDomain(sourceID: sourceID, processRunID: runID, clockDomainID: "test-clock"),
                sourceOccurrence: EvidenceSourceOccurrence(wallTime: date, continuousNanoseconds: sequence, quality: .exact)
            ),
            currentState: .object(["lifecycle": .string("diskAppeared")]),
            attributes: attributes
        )
    }
}

// swiftlint:enable line_length trailing_comma
