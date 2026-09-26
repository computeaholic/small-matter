@testable import Tunix
import XCTest

final class SecurityHardeningTests: XCTestCase {
    func testCoolingSnapshotKeepsPolicyOwnershipWithMacOS() {
        XCTAssertTrue(CoolingSnapshot.unavailable.macOSPolicyOwner)
    }
}
