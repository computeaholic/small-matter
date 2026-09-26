import XCTest

@MainActor
final class TunixUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "Tunix-LLC.Tunix")
        app.launchArguments = ["-UITesting"]
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        if !app.windows.firstMatch.exists {
            let newWindow = app.menuItems["New Window"]
            newWindow.click()
        }
        XCTAssertTrue(app.windows.firstMatch.exists, "Small Matter’s main window did not appear")
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        try super.tearDownWithError()
    }

    func testLaunchShowsOverview() {
        XCTAssertEqual(app.windows.firstMatch.title, "Overview")
    }

    func testNavigationShowsMonitoringDestinations() {
        // swiftformat:disable trailingCommas
        let destinations = [
            ("Performance", "Performance"),
            ("Cooling", "Cooling"),
            ("Battery", "Battery"),
            ("Cleanup", "Cleanup"),
            ("System Health", "System Health")
        ]
        // swiftformat:enable trailingCommas
        for destination in destinations {
            let destinationRow = app.staticTexts["navigation-" + destination.0]
            destinationRow.click()
            XCTAssertEqual(
                app.windows.firstMatch.title,
                destination.1,
                "Destination did not appear: " + destination.1
            )
        }
    }

    func testSettingsOpensNativeSettingsSurface() {
        let settingsMenu = app.menuItems["Settings…"]
        settingsMenu.click()
        let windowCount = app.windows.count
        XCTAssertTrue(windowCount > 1, "Native Settings window did not appear")
    }

    func testKeepAwakeCanBeEnabledAndDisabled() {
        let keepAwake = app.checkBoxes["keep-awake-toggle"]
        defer {
            if toggleIsOn(keepAwake) {
                keepAwake.click()
            }
        }
        XCTAssertFalse(toggleIsOn(keepAwake))

        keepAwake.click()
        XCTAssertTrue(toggleIsOn(keepAwake), "Keep Awake did not report the enabled state")

        keepAwake.click()
        XCTAssertFalse(toggleIsOn(keepAwake), "Keep Awake did not return to the disabled state")
    }

    private func toggleIsOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        if let string = element.value as? String {
            return string == "On" || string == "1"
        }
        return false
    }
}
