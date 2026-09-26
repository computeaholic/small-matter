@testable import Tunix
import XCTest

@MainActor
final class NativeThermalTelemetryTests: XCTestCase {
    func testNativeThermalTelemetryIsAppProcessOwned() {
        let stats = SystemStatsModel(refreshInterval: 60, thermalManager: ThermalManager())

        stats.update()

        XCTAssertEqual(stats.telemetrySnapshot.thermal.source, .processInfo)
        XCTAssertEqual(stats.telemetrySnapshot.thermal.freshness, .fresh)
        XCTAssertFalse(stats.telemetrySnapshot.thermal.lowPowerMode && !ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
