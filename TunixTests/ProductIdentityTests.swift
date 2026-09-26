@testable import Tunix
import XCTest

final class ProductIdentityTests: XCTestCase {
    func testPublicIdentityUsesSmallMatter() {
        XCTAssertEqual(ProductIdentity.displayName, "Small Matter")
        XCTAssertEqual(ProductIdentity.shortName, "Small Matter")
        XCTAssertEqual(ProductIdentity.supportExportFilenameStem, "Small-Matter-Support-Snapshot")
    }

    func testLegacyCompatibilityIdentifiersRemainStable() {
        XCTAssertEqual(ProductIdentity.stableApplicationSupportDirectoryName, "Tunix")
        XCTAssertEqual(ProductIdentity.stableBundleIdentifier, "Tunix-LLC.Tunix")
        XCTAssertEqual(ProductIdentity.stableSubsystem, "com.tunix")
    }
}
