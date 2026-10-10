import Foundation
@testable import Tunix
import XCTest

// swiftformat:disable trailingCommas
final class CorrelationBoundedTests: XCTestCase {
    private let runID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
    private let epoch = UUID(uuidString: "75000000-0000-0000-0000-000000000001")!
    private let start = Date(timeIntervalSince1970: 1_700_200_000)

    func testCorrelationIsStableAcrossOneHundredDeterministicPermutations() throws {
        let values = [
            storage(60, seconds: 0),
            storage(61, seconds: 2),
            storage(62, seconds: 14),
            storage(63, seconds: 30),
            network(64, seconds: 1),
            network(65, seconds: 12),
            power(66, seconds: 3)
        ]
        let expected = try CorrelationEngine().correlate(incident: incident(values), observations: values)
        let expectedData = try expected.map(canonicalData)

        for seed in 0 ..< 100 {
            let permuted = deterministicPermutation(values, seed: seed)
            let actual = try CorrelationEngine().correlate(incident: incident(permuted), observations: permuted)
            XCTAssertEqual(actual, expected, "Permutation \(seed) changed correlation")
            XCTAssertEqual(try actual.map(canonicalData), expectedData)
        }
    }

    func testBoundedTwoHundredObservationFixtureRemainsScopedAndDeterministic() throws {
        var values: [Observation] = []
        for index in 0 ..< 100 {
            values.append(storage(100 + index, seconds: Double(index) / 2))
        }
        for index in 0 ..< 50 {
            values.append(network(300 + index, seconds: Double(index) / 2))
        }
        for index in 0 ..< 50 {
            values.append(power(400 + index, seconds: Double(index) / 2))
        }

        let engine = CorrelationEngine()
        let first = try engine.correlate(incident: incident(values), observations: values)
        let second = try engine.correlate(incident: incident(values), observations: values.reversed())
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { set in
            let members = set.memberObservationIDs.compactMap { id in values.first { $0.id == id } }
            let sources = Set(members.map(\.sourceID))
            guard set.members.count > 1 else { return true }
            guard sources.count == 1 else { return false }
            let coordinates = members.compactMap(\.time.continuousNanoseconds)
            guard let minimum = coordinates.min(), let maximum = coordinates.max() else { return false }
            return maximum - minimum <= 15_000_000_000
        })
        XCTAssertFalse(first.flatMap(\.memberObservationIDs).contains { id in
            values.first { $0.id == id }?.sourceID == .power
        })
    }

    private func deterministicPermutation(_ values: [Observation], seed: Int) -> [Observation] {
        var result = values
        var state = UInt64(seed + 1)
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let swapIndex = Int(state % UInt64(index + 1))
            result.swapAt(index, swapIndex)
        }
        return result
    }

    private func canonicalData(_ set: EvidenceSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(set)
    }

    private func incident(_ observations: [Observation]) -> IncidentPackage {
        IncidentPackage(
            id: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!,
            marker: IncidentMarker(wallTime: start),
            status: .complete,
            completedAt: start,
            materializedContext: .object([:]),
            observationIDs: observations.map(\.id)
        )
    }

    private func storage(_ index: Int, seconds: TimeInterval) -> Observation {
        make(
            index: index,
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            source: .storage,
            subject: EvidenceSubject(
                type: .storageDisk,
                identityDigest: "bounded-disk",
                quality: .qualified,
                safeDisplayLabel: "bounded fixture disk"
            ),
            seconds: seconds
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

    // Why: complete canonical inputs.
    // Why: complete canonical inputs.
    // swiftlint:disable:next function_parameter_count
    private func make(
        index: Int,
        domain: EvidenceDomain,
        eventKind: EvidenceEventKind,
        source: Horizon2SourceID,
        subject: EvidenceSubject,
        seconds: TimeInterval
    ) -> Observation {
        let time = EvidenceTime(
            observedWallTime: start.addingTimeInterval(seconds),
            continuousNanoseconds: UInt64(seconds * 1_000_000_000),
            processUptimeNanoseconds: UInt64(seconds * 1_000_000_000),
            processRunID: runID,
            bootSessionID: "bounded-fixture-boot",
            localSequence: UInt64(index),
            sourceTimestampQuality: .exact,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: source,
                processRunID: runID,
                clockDomainID: "bounded-fixture-clock"
            ),
            sourceOccurrence: nil,
            correlationEpochID: epoch
        )
        return Observation(
            id: UUID(uuidString: String(format: "77000000-0000-0000-0000-%012d", index))!,
            domain: domain,
            eventKind: eventKind,
            sourceID: source,
            subject: subject,
            provenance: EvidenceProvenance(
                sourceID: source,
                apiName: "bounded-fixture",
                apiVersion: "1",
                captureChannel: "test",
                sourceTimestampQuality: .exact,
                normalizationRuleID: "bounded-fixture",
                normalizationRuleVersion: "1",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: nil
            ),
            time: time,
            currentState: .string("bounded-fixture")
        )
    }
}
