@testable import Tunix
import XCTest

final class TunixDARPATests: XCTestCase {
    func testThermalPressureIsDeterministic() {
        var state = ThermalState(cpuTemp: 60, batteryTemp: 36, cpuLoad: 0)
        XCTAssertEqual(state.pressure, .nominal)
        state.cpuTemp = 100
        XCTAssertEqual(state.pressure, .critical)
    }

    func testRiskBannerOnlyReflectsTelemetry() {
        XCTAssertFalse(ThermalState(cpuTemp: 70, batteryTemp: 35).risk.shouldShowBanner)
        XCTAssertTrue(ThermalState(cpuTemp: 101, batteryTemp: 35).risk.shouldShowBanner)
    }
}
