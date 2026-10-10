@testable import Tunix
import XCTest

final class TelemetryModelTests: XCTestCase {
    func testSyntheticCPUUtilizationCases() {
        XCTAssertEqual(cpuResult(busy: 0, idle: 100).totalUtilization, 0, accuracy: 0.001)
        XCTAssertEqual(cpuResult(busy: 25, idle: 75).totalUtilization, 25, accuracy: 0.001)
        XCTAssertEqual(cpuResult(busy: 50, idle: 50).totalUtilization, 50, accuracy: 0.001)
        XCTAssertEqual(cpuResult(busy: 100, idle: 0).totalUtilization, 100, accuracy: 0.001)
    }

    func testCPUAggregationSumsLogicalCPUTime() {
        let previous = [
            ProcessorCPUTicks(identifier: 0, user: 0, system: 0, idle: 0, nice: 0),
            ProcessorCPUTicks(identifier: 1, user: 0, system: 0, idle: 0, nice: 0)
        ]
        let current = [
            ProcessorCPUTicks(identifier: 0, user: 10, system: 0, idle: 90, nice: 0),
            ProcessorCPUTicks(identifier: 1, user: 50, system: 0, idle: 50, nice: 0)
        ]

        guard let result = CPUUsageCalculator.calculate(previous: previous, current: current) else {
            return XCTFail("Expected a valid multi-core CPU delta")
        }

        XCTAssertEqual(result.totalUtilization, 30, accuracy: 0.001)
        XCTAssertEqual(result.logicalCPUCount, 2)
        XCTAssertEqual(result.perCoreUtilization[0] ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(result.perCoreUtilization[1] ?? -1, 50, accuracy: 0.001)
    }

    func testCPUCoreIdentitySurvivesReorderedSamples() {
        let previous = [
            ProcessorCPUTicks(identifier: 5, user: 0, system: 0, idle: 0, nice: 0),
            ProcessorCPUTicks(identifier: 7, user: 0, system: 0, idle: 0, nice: 0)
        ]
        let current = [
            ProcessorCPUTicks(identifier: 7, user: 50, system: 0, idle: 50, nice: 0),
            ProcessorCPUTicks(identifier: 5, user: 10, system: 0, idle: 90, nice: 0)
        ]

        guard let result = CPUUsageCalculator.calculate(previous: previous, current: current) else {
            return XCTFail("Expected a valid reordered CPU delta")
        }

        XCTAssertEqual(result.perCoreUtilization[5] ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(result.perCoreUtilization[7] ?? -1, 50, accuracy: 0.001)
    }

    func testCPURejectsZeroElapsedTicksAndCounterReset() {
        let zero = ProcessorCPUTicks(identifier: 0, user: 10, system: 10, idle: 10, nice: 10)
        XCTAssertNil(CPUUsageCalculator.calculate(previous: [zero], current: [zero]))

        let reset = ProcessorCPUTicks(identifier: 0, user: 9, system: 10, idle: 10, nice: 10)
        XCTAssertNil(CPUUsageCalculator.calculate(previous: [zero], current: [reset]))
    }

    func testCoolingTelemetryHealthTransitionsAndMissingState() {
        let now = Date(timeIntervalSince1970: 10000)
        let health = CoolingTelemetryHealth(
            lastSuccessfulSampleAt: now.addingTimeInterval(-2),
            staleAfter: 8,
            unavailableAfter: 30
        )
        XCTAssertEqual(health.state(at: now), .available)
        XCTAssertEqual(health.state(at: now.addingTimeInterval(7)), .stale)
        XCTAssertEqual(health.state(at: now.addingTimeInterval(30)), .unavailable)

        let noSample = CoolingTelemetryHealth(
            lastSuccessfulSampleAt: nil,
            staleAfter: 8,
            unavailableAfter: 30
        )
        XCTAssertEqual(noSample.state(at: now), .unavailable)
    }

    func testSharedFreshnessTransitionsAndLastGoodSemantics() {
        let now = Date(timeIntervalSince1970: 10000)
        let health = TelemetryHealth(
            lastAttemptAt: now,
            lastSuccessfulSampleAt: now.addingTimeInterval(-2),
            consecutiveFailures: 1,
            staleAfter: 8,
            unavailableAfter: 30
        )

        XCTAssertEqual(health.freshness(at: now), .fresh)
        XCTAssertEqual(health.freshness(at: now.addingTimeInterval(8)), .stale)
        XCTAssertEqual(health.freshness(at: now.addingTimeInterval(30)), .unavailable)

        let noSample = TelemetryHealth(
            lastAttemptAt: now,
            lastSuccessfulSampleAt: nil,
            consecutiveFailures: 1,
            staleAfter: 8,
            unavailableAfter: 30
        )
        XCTAssertEqual(noSample.freshness(at: now), .unavailable)
    }

    func testBoundedHistoryRetainsOnlyMostRecentSamples() {
        var history = BoundedHistory<Int>(limit: 3)
        (0 ... 5).forEach { history.append($0) }

        XCTAssertEqual(history.values, [3, 4, 5])
        XCTAssertEqual(history.values.count, 3)
    }

    func testValidZeroIsDistinctFromUnknownAndUnavailable() {
        let zero = NetworkSnapshot(
            timestamp: .now,
            freshness: .fresh,
            source: .networkInterfaces,
            sentBytes: 0,
            receivedBytes: 0,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0
        )

        XCTAssertEqual(zero.uploadBytesPerSecond, 0)
        XCTAssertEqual(zero.downloadBytesPerSecond, 0)
        XCTAssertNotEqual(zero.freshness, .unavailable)
        XCTAssertNil(NetworkSnapshot.unavailable.uploadBytesPerSecond)
        XCTAssertNil(NetworkSnapshot.unavailable.downloadBytesPerSecond)
    }

    func testUnavailableSnapshotDoesNotInventZero() {
        XCTAssertEqual(CPUSnapshot.empty.freshness, .unavailable)
        XCTAssertEqual(CPUSnapshot.empty.totalUtilization, 0)
        XCTAssertNil(StorageSnapshot.unavailable.freeBytes)
        XCTAssertNil(StorageSnapshot.unavailable.totalBytes)
        XCTAssertEqual(MemorySnapshot.unavailable.telemetry.pressure, .unavailable)
    }

    private func cpuResult(busy: UInt64, idle: UInt64) -> CPUAggregateResult {
        let previous = ProcessorCPUTicks(identifier: 0, user: 0, system: 0, idle: 0, nice: 0)
        let current = ProcessorCPUTicks(identifier: 0, user: busy, system: 0, idle: idle, nice: 0)
        guard let result = CPUUsageCalculator.calculate(previous: [previous], current: [current]) else {
            XCTFail("Expected a valid synthetic CPU delta")
            return CPUAggregateResult(
                totalUtilization: 0,
                userUtilization: 0,
                systemUtilization: 0,
                idleUtilization: 0,
                logicalCPUCount: 0,
                perCoreUtilization: [:]
            )
        }
        return result
    }
}
