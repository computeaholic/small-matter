@testable import Tunix
import XCTest

final class BatteryCapabilityTruthTests: XCTestCase {
    func testBatteryModelHasNoPrivilegedTelemetryDependency() {
        XCTAssertEqual(BatterySnapshot.unavailable.source, .unavailable)
        XCTAssertFalse(BatterySnapshot.unavailable.present)
    }
}
