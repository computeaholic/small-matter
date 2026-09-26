@testable import Tunix
import XCTest

final class MemoryTelemetryTests: XCTestCase {
    func testLargeRAMWithNormalPressureStaysNormal() {
        let physical = 128 * 1024 * 1024 * 1024
        let used = 88 * 1024 * 1024 * 1024

        let condition = MemoryPressureCondition.classify(
            observed: .normal,
            swapUsedBytes: 64 * 1024 * 1024,
            physicalBytes: UInt64(physical)
        )
        let telemetry = MemoryTelemetry(
            pressure: condition,
            usedBytes: UInt64(used),
            physicalBytes: UInt64(physical),
            appBytes: nil,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedBytes: nil,
            swapUsedBytes: 64 * 1024 * 1024
        )

        XCTAssertEqual(telemetry.pressure, .normal)
        XCTAssertEqual(telemetry.usedBytes, UInt64(used))
        XCTAssertEqual(telemetry.usedPercent ?? -1, 68.75, accuracy: 0.001)
    }

    func testUnavailablePressureOnlyUsesSignificantSwapAsFallback() {
        let physical = UInt64(16 * 1024 * 1024 * 1024)

        XCTAssertEqual(
            MemoryPressureCondition.classify(
                observed: .unavailable,
                swapUsedBytes: 0,
                physicalBytes: physical
            ),
            .normal
        )
        XCTAssertEqual(
            MemoryPressureCondition.classify(
                observed: .unavailable,
                swapUsedBytes: physical / 2,
                physicalBytes: physical
            ),
            .elevated
        )
    }

    func testProductVocabularyIsStable() {
        XCTAssertEqual(MemoryPressureCondition.normal.label, "Normal")
        XCTAssertEqual(MemoryPressureCondition.elevated.label, "Elevated")
        XCTAssertEqual(MemoryPressureCondition.high.label, "High")
        XCTAssertEqual(MemoryPressureCondition.critical.label, "Critical")
    }
}
