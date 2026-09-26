// swiftlint:disable trailing_comma
@testable import Tunix
import XCTest

final class SettingsCompatibilityTests: XCTestCase {
    func testLegacyHardwarePolicySettingsAreIgnored() throws {
        let plist: [String: Any] = [
            "fanMode": "custom",
            "chargeLimit": 80,
            "refreshInterval": 5.0,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        let settings = try PropertyListDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.refreshInterval, 5.0)
        XCTAssertTrue(settings.safeCleanupMode)
    }
}

// swiftlint:enable trailing_comma
