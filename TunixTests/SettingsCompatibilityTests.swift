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
        XCTAssertEqual(settings.temperatureUnit, .system)
    }

    func testTemperaturePresentationUsesCanonicalCelsiusForExplicitUnits() {
        XCTAssertTrue(
            TemperaturePresentation.string(celsius: 30.5, unit: .celsius, locale: Locale(identifier: "en_US"))
                .hasSuffix("°C")
        )
        XCTAssertTrue(
            TemperaturePresentation.string(celsius: 30.5, unit: .fahrenheit, locale: Locale(identifier: "en_US"))
                .hasSuffix("°F")
        )
        XCTAssertTrue(
            TemperaturePresentation.string(celsius: 30.5, unit: .system, locale: Locale(identifier: "en_US"))
                .hasSuffix("°F")
        )
        XCTAssertTrue(
            TemperaturePresentation.string(celsius: 30.5, unit: .system, locale: Locale(identifier: "de_DE"))
                .hasSuffix("°C")
        )
    }

    func testTemperaturePreferenceRoundTripsAndLegacyDefaultsRemainStable() throws {
        var settings = AppSettings()
        settings.temperatureUnit = .fahrenheit
        let data = try PropertyListEncoder().encode(settings)
        let decoded = try PropertyListDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.temperatureUnit, .fahrenheit)

        let legacy = try PropertyListSerialization.data(
            fromPropertyList: ["refreshInterval": 3.0, "safeCleanupMode": true],
            format: .binary,
            options: 0
        )
        XCTAssertEqual(try PropertyListDecoder().decode(AppSettings.self, from: legacy).temperatureUnit, .system)
    }
}

// swiftlint:enable trailing_comma
