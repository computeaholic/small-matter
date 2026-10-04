import XCTest

@MainActor
final class CapacityRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "Tunix-LLC.Tunix")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-UITesting", "-UITestingRecentChanges=capacity",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        try super.tearDownWithError()
    }

    func testCapacityOffersConfirmedSafeRecovery() {
        app.staticTexts["navigation-Recent Changes"].click()

        let recovery = app.buttons["incident-capture-capacity-recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        recovery.click()

        let confirm = app.sheets.buttons["Remove Unprotected Evidence"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(app.staticTexts["recent-changes-empty-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["incident-capture-start"].isEnabled)
        XCTAssertTrue(app.staticTexts["Evidence storage recovery"].waitForExistence(timeout: 5))
    }
}
