import Foundation
import XCTest

@MainActor
// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
final class TunixUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "Tunix-LLC.Tunix")
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-UITesting"]
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Small Matter did not terminate before launch")
        }
        launchAndWaitForMainWindow()
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

    func testOverviewRendersValuesAndDynamicIdentifiers() {
        let performanceHeading = app.staticTexts["Current performance"]
        XCTAssertTrue(performanceHeading.waitForExistence(timeout: 5), app.debugDescription)

        let hierarchy = app.debugDescription
        for literalExpression in [
            "(stats.memoryPressureLabel)",
            "(freePercent)",
            "(stats.diskTotalText)",
            "(destination.rawValue)",
            "(title), (value), (detail)",
            "(stats.cpuUsageText)",
            "(row.timeText) · (row.sourceText)",
            "(row.title), (row.summary), (row.timeText)"
        ] {
            XCTAssertFalse(
                hierarchy.contains(literalExpression),
                "Overview exposed source-code text: \(literalExpression)\n\(hierarchy)"
            )
        }

        XCTAssertTrue(hierarchy.contains("Current performance"), hierarchy)
        XCTAssertTrue(hierarchy.contains("Total ut"), hierarchy)
        XCTAssertTrue(hierarchy.contains("Memory,"), hierarchy)

        for identifier in [
            "overview-open-recent-changes",
            "overview-open-system-health",
            "overview-open-performance",
            "overview-open-battery"
        ] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing contextual identifier \(identifier)")
            XCTAssertEqual(button.identifier, identifier)
        }
    }

    func testNavigationShowsMonitoringDestinations() {
        // swiftformat:disable trailingCommas
        let destinations = [
            ("Performance", "Performance"),
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

    func testCoolingTemperatureGroupsHaveStableAccessibilityIdentifiers() {
        app.staticTexts["navigation-System Health"].click()
        app.buttons["system-health-open-cooling"].click()

        let cpuTemperature = app.descendants(matching: .any)["cooling-temperature-cpu"]
        let batteryTemperature = app.descendants(matching: .any)["cooling-temperature-battery"]

        XCTAssertTrue(cpuTemperature.waitForExistence(timeout: 5))
        XCTAssertTrue(batteryTemperature.waitForExistence(timeout: 5))
        XCTAssertEqual(cpuTemperature.identifier, "cooling-temperature-cpu")
        XCTAssertEqual(batteryTemperature.identifier, "cooling-temperature-battery")
    }

    func testSettingsOpensNativeSettingsSurface() {
        let settingsMenu = app.menuItems["Settings…"]
        settingsMenu.click()
        let windowCount = app.windows.count
        XCTAssertTrue(windowCount > 1, "Native Settings window did not appear")
        XCTAssertTrue(app.descendants(matching: .any)["temperature-unit-picker"].waitForExistence(timeout: 5))
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

    func testRecentChangesLoadedFixtureIsFactsFirstAndNavigable() {
        relaunchRecentChangesFixture("loaded")
        app.staticTexts["navigation-Recent Changes"].click()

        XCTAssertEqual(app.windows.firstMatch.title, "Recent Changes")
        let diskRow = app.descendants(matching: .any)["recent-change-row-00000000-0000-0000-0000-000000000101"]
        XCTAssertFalse(diskRow.waitForExistence(timeout: 2))
        let volumeRow = app.descendants(matching: .any)["recent-change-row-00000000-0000-0000-0000-000000000102"]
        XCTAssertFalse(volumeRow.exists)
        let unavailableStorageRow = app.descendants(matching: .any)[
            "recent-change-row-00000000-0000-0000-0000-000000000105"
        ]
        XCTAssertTrue(unavailableStorageRow.waitForExistence(timeout: 5))

        let networkRow = app.descendants(matching: .any)["recent-change-row-00000000-0000-0000-0000-000000000104"]
        XCTAssertTrue(networkRow.waitForExistence(timeout: 5))
        XCTAssertTrue(networkRow.label.contains("Supplemental"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'digest'")).firstMatch.exists)
        app.buttons["recent-changes-refresh"].click()

        networkRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["recent-change-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["recent-change-source"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["recent-change-time"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["recent-change-status"].exists)
        XCTAssertTrue(app.staticTexts["Supplemental limitation"].exists)
    }

    func testRecentChangesDoesNotPresentInferenceRows() {
        relaunchRecentChangesFixture("loaded")
        app.staticTexts["navigation-Recent Changes"].click()

        XCTAssertFalse(app.staticTexts["Inferred"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'inference'")).firstMatch.exists)
    }

    func testRecentChangesEmptyStateIsNotUnavailable() {
        relaunchRecentChangesFixture("empty")
        app.staticTexts["navigation-Recent Changes"].click()

        let emptyDescription = app.debugDescription
        XCTAssertTrue(emptyDescription.contains("recent-changes-empty-state"))
        XCTAssertTrue(app.staticTexts["recent-changes-empty-state"].waitForExistence(timeout: 5))
        XCTAssertFalse(emptyDescription.contains("Recent Changes is unavailable."))
    }

    func testRecentChangesUnavailableAndCapacityStatesAreExplicit() {
        relaunchRecentChangesFixture("unavailable")
        app.staticTexts["navigation-Recent Changes"].click()
        let unavailableDescription = app.debugDescription
        XCTAssertTrue(unavailableDescription.contains("recent-changes-unavailable-state"))
        XCTAssertTrue(unavailableDescription.contains("Recent Changes is"))
        XCTAssertFalse(unavailableDescription.contains("No meaningful recent changes"))

        relaunchRecentChangesFixture("capacity")
        app.staticTexts["navigation-Recent Changes"].click()
        let capacityDescription = app.debugDescription
        XCTAssertTrue(capacityDescription.contains("recent-changes-capacity-state"))
        XCTAssertTrue(capacityDescription.contains("Recent changes may"))
    }

    func testRecentChangesIncompleteCoverageDoesNotCreateHealthRow() {
        relaunchRecentChangesFixture("incomplete")
        app.staticTexts["navigation-Recent Changes"].click()

        let incompleteDescription = app.debugDescription
        XCTAssertTrue(incompleteDescription.contains("recent-changes-incomplete-state"))
        XCTAssertTrue(incompleteDescription.contains("Some changes may b"))
        XCTAssertFalse(incompleteDescription.contains("fixture coverage warning"))
    }

    func testIncidentCaptureStartsAndShowsFrozenWindow() {
        relaunchIncidentFixture("idle")
        app.staticTexts["navigation-Recent Changes"].click()

        let capture = app.buttons["incident-capture-start"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.click()

        XCTAssertTrue(app.descendants(matching: .any)["incident-capture-capturing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["incident-capture-window"].exists)
        XCTAssertFalse(capture.isEnabled, "A second capture must not start while the first is active")
    }

    func testIncidentHistorySummaryIsFactsOnlyAndDeletable() {
        relaunchIncidentFixture("history")
        app.staticTexts["navigation-Recent Changes"].click()

        let row = app.buttons["incident-history-row-00000000-0000-0000-0000-000000000302"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        XCTAssertTrue(app.descendants(matching: .any)["incident-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Captured successfully"].exists)
        XCTAssertTrue(app.staticTexts["CHANGES OBSERVED"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'digest'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["incident-delete"].exists)
    }

    func testIncidentIncompleteSummaryPreservesUnknownReason() {
        relaunchIncidentFixture("incomplete")
        app.staticTexts["navigation-Recent Changes"].click()

        let row = app.buttons["incident-history-row-00000000-0000-0000-0000-000000000304"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["incident-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Captured with limitations"].exists)
        XCTAssertTrue(app.staticTexts["Small Matter was closed before this capture finished."].exists)
    }

    func testZeroEventCaptureStatesNoChangesAndNoInference() {
        relaunchIncidentFixture("zero-event")
        app.staticTexts["navigation-Recent Changes"].click()

        let row = app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        XCTAssertTrue(app.staticTexts["WHAT WAS HAPPENING"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CHANGES OBSERVED"].exists)
        let noObservation = "No qualifying change observation was captured in this window. " +
            "This does not establish that nothing changed."
        XCTAssertTrue(app.staticTexts[noObservation].exists)
        XCTAssertTrue(app
            .staticTexts["No interpretation was generated because no qualifying change observation was captured."]
            .exists)
    }

    func testIncidentUnavailableIsNotPresentedAsEmpty() {
        relaunchIncidentFixture("unavailable")
        app.staticTexts["navigation-Recent Changes"].click()

        XCTAssertTrue(app.staticTexts["recent-changes-unavailable-state"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["recent-changes-empty-state"].exists)
        XCTAssertFalse(app.buttons["incident-capture-start"].isEnabled)
    }

    func testStorageInferenceShowsEpistemicSupportAndNextTest() {
        relaunchIncidentFixture("storage-inference-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        let row = app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let status = app.descendants(matching: .any)["inference-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let statusText = status.value as? String ?? status.label
        XCTAssertTrue(statusText.contains("Supported"), "status text: \(statusText.debugDescription)")
        XCTAssertTrue(app.staticTexts["Observed support"].exists)
        XCTAssertTrue(app
            .descendants(matching: .any)["inference-support-observation-00000000-0000-0000-0000-000000000101"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Next Test"].exists)
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'confidence' OR label CONTAINS[c] '%'")).firstMatch.exists)
    }

    func testNetworkInferenceKeepsCauseUnknownAndAlternativesUnranked() {
        relaunchIncidentFixture("network-inference-alternatives")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        let status = app.descendants(matching: .any)["inference-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let statusText = status.value as? String ?? status.label
        XCTAssertTrue(statusText.contains("Supported"), "status text: \(statusText.debugDescription)")
        XCTAssertTrue(app.staticTexts["Unknown"].exists)
        XCTAssertTrue(app.staticTexts["Alternative"].exists)
        XCTAssertTrue(app.staticTexts["Next Test"].exists)
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'router' AND label CONTAINS[c] 'failed'")).firstMatch
            .exists)
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'likely' OR label CONTAINS[c] 'probably'")).firstMatch
            .exists)
    }

    func testInsufficientInferenceShowsUnknownWithoutSupportedConclusion() {
        relaunchIncidentFixture("inference-insufficient")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        let status = app.descendants(matching: .any)["inference-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let statusText = status.value as? String ?? status.label
        XCTAssertTrue(statusText.contains("Insufficient evidence"), "status text: \(statusText.debugDescription)")
        XCTAssertTrue(app.staticTexts["Unknown"].exists)
        XCTAssertTrue(app.staticTexts["Observed contradiction"].exists)
        XCTAssertTrue(app
            .descendants(matching: .any)["inference-contradiction-observation-00000000-0000-0000-0000-000000000106"]
            .waitForExistence(timeout: 5))
    }

    func testInferencePresentationUsesCurrentOnlyAndExactSupportRows() {
        relaunchIncidentFixture("inference-current-and-historical")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()

        XCTAssertTrue(app.descendants(matching: .any)["incident-inference-section"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "incident-inference-section").count, 1)
        XCTAssertTrue(app
            .descendants(matching: .any)["inference-support-observation-00000000-0000-0000-0000-000000000101"]
            .waitForExistence(timeout: 5))
    }

    func testInferenceSupportDoesNotClaimUnrelatedCapturedObservation() {
        relaunchIncidentFixture("inference-multi-source")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()

        XCTAssertTrue(app
            .descendants(matching: .any)["inference-support-observation-00000000-0000-0000-0000-000000000101"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app
            .descendants(matching: .any)["inference-support-observation-00000000-0000-0000-0000-000000000104"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app
            .descendants(matching: .any)["inference-support-observation-00000000-0000-0000-0000-000000000103"].exists)
    }

    func testStorageAndVolumeInferenceUseSpecificSubjectLanguage() {
        relaunchIncidentFixture("storage-inference-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        XCTAssertTrue(app.staticTexts["Captured evidence supports a storage disk lifecycle change."]
            .waitForExistence(timeout: 5))

        relaunchIncidentFixture("volume-inference-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        XCTAssertTrue(app.staticTexts["Captured evidence supports a mounted volume lifecycle change."]
            .waitForExistence(timeout: 5))
    }

    func testNextTestShowsPersistedSnapshotFields() {
        relaunchIncidentFixture("inference-snapshot")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()

        XCTAssertTrue(app.staticTexts["Record the persisted fixture storage presentation."]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The fixture storage disk lifecycle fact is visible."]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stop after the fixture storage presentation is recorded."]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This persisted fixture does not change storage state."]
            .waitForExistence(timeout: 5))
    }

    func testEvidenceExportPreviewUsesCanonicalRedactedPackage() {
        relaunchIncidentFixture("export-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()

        XCTAssertFalse(app.buttons["evidence-export-save-json"].exists)
        app.buttons["incident-preview-evidence-export"].click()

        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-status"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-observed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-inferred"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-next-tests"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-source-manifest"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-redaction-manifest"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-version-manifest"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-alternatives"].exists)
        XCTAssertTrue(app.staticTexts["Physical cause was not established by this evidence."].exists)
        for _ in 0 ..< 3 {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(app.buttons["evidence-export-save-json"].exists)
        XCTAssertTrue(app.buttons["evidence-export-save-text"].exists)
        XCTAssertFalse(app.debugDescription.contains("fixture-storage-digest"))
        XCTAssertFalse(app.debugDescription.contains("fixture-volume-digest"))
    }

    func testIncompleteExportRemainsIncompleteAndPowerOnlyHasNoInference() {
        relaunchIncidentFixture("export-incomplete")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Captured with limitations"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-incomplete-warning"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-membership"].exists)
        XCTAssertTrue(app.staticTexts["Network capture ended before the incident was complete."].exists)

        relaunchIncidentFixture("export-power-only")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-observed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No inferred interpretations."].exists)
        XCTAssertFalse(app.staticTexts["EXTERNAL_STORAGE_LIFECYCLE"].exists)
        XCTAssertFalse(app.staticTexts["NETWORK_PATH_TRANSITION"].exists)
    }

    private func relaunchRecentChangesFixture(_ mode: String) {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Small Matter did not terminate before fixture relaunch")
        app = XCUIApplication(bundleIdentifier: "Tunix-LLC.Tunix")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-UITesting", "-UITestingRecentChanges=\(mode)"
        ]
        launchAndWaitForMainWindow()
    }

    private func relaunchIncidentFixture(_ mode: String, exportDestination: String? = nil) {
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "Small Matter did not terminate before incident fixture relaunch"
        )
        app = XCUIApplication(bundleIdentifier: "Tunix-LLC.Tunix")
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-UITesting", "-UITestingRecentChanges=loaded",
            "-UITestingIncident=\(mode)"
        ]
        if let exportDestination {
            app.launchArguments.append("-UITestingEvidenceExportDestination=\(exportDestination)")
        }
        launchAndWaitForMainWindow()
    }

    private func launchAndWaitForMainWindow() {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Small Matter did not reach the foreground")
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            let newWindow = app.menuItems["New Window"]
            if newWindow.waitForExistence(timeout: 2) {
                newWindow.click()
            }
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
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

extension TunixUITests {
    func testSystemHealthSeparatesCurrentSnapshotFromNoCaptureEvidence() {
        app.staticTexts["navigation-System Health"].click()

        XCTAssertTrue(app.windows.firstMatch.title == "System Health")
        XCTAssertTrue(app.descendants(matching: .any)["system-health-evidence-section"].waitForExistence(timeout: 5))
        expandDiagnosticsIfNeeded()
        let contentScrollView = app.scrollViews.firstMatch
        if contentScrollView.waitForExistence(timeout: 2) {
            contentScrollView.swipeUp()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["system-health-copy-current-snapshot"].exists,
            app.debugDescription
        )
        XCTAssertTrue(app.descendants(matching: .any)["system-health-current-snapshot"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["system-health-no-capture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Copy Support Snapshot"].exists)
    }

    private func expandDiagnosticsIfNeeded() {
        let disclosureTriangle = app.disclosureTriangles["Diagnostics"]
        if disclosureTriangle.waitForExistence(timeout: 2) {
            if let value = disclosureTriangle.value as? NSNumber, value.boolValue {
                return
            }
            disclosureTriangle.click()
            return
        }

        let disclosureButton = app.buttons["Diagnostics"]
        if disclosureButton.waitForExistence(timeout: 2) {
            disclosureButton.click()
            return
        }

        let disclosureLabel = app.staticTexts["Diagnostics"]
        if disclosureLabel.waitForExistence(timeout: 2) {
            disclosureLabel.click()
        }
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    func testSystemHealthShowsIncompleteLatestCapture() {
        relaunchIncidentFixture("incomplete")
        app.staticTexts["navigation-System Health"].click()

        let latest = app.descendants(matching: .any)["system-health-latest-capture"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(latest, containing: "Captured with limitations"))
        let preview = app.buttons["system-health-preview-latest-evidence"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.click()
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Captured with limitations"].exists)
        XCTAssertTrue(app.staticTexts["Small Matter was closed before this capture finished."].exists)
    }

    func testSystemHealthPreservesReadableHistoryWhenCapacityIsUnavailable() {
        relaunchIncidentFixture("capacity-complete")
        app.staticTexts["navigation-System Health"].click()
        let completeStatus = app.descendants(matching: .any)["system-health-evidence-status"]
        XCTAssertTrue(completeStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(completeStatus, containing: "Storage full"),
            "status=\(completeStatus.label) value=\(completeStatus.value ?? "")\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            waitForLabel(
                app.descendants(matching: .any)["system-health-latest-capture"],
                containing: "Captured successfully"
            ),
            app.debugDescription
        )
        XCTAssertTrue(app.buttons["system-health-preview-latest-evidence"].exists)

        relaunchIncidentFixture("capacity-incomplete")
        app.staticTexts["navigation-System Health"].click()
        let incompleteStatus = app.descendants(matching: .any)["system-health-evidence-status"]
        XCTAssertTrue(incompleteStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(incompleteStatus, containing: "Storage full"),
            "status=\(incompleteStatus.label) value=\(incompleteStatus.value ?? "")\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            waitForLabel(
                app.descendants(matching: .any)["system-health-latest-capture"],
                containing: "Captured with limitations"
            ),
            app.debugDescription
        )
        XCTAssertTrue(app.buttons["system-health-preview-latest-evidence"].exists)
    }

    func testSystemHealthKeepsCaptureVisibleWhenPackageAssemblyFails() {
        relaunchIncidentFixture("package-failure")
        app.staticTexts["navigation-System Health"].click()
        XCTAssertTrue(app.descendants(matching: .any)["system-health-latest-capture"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(
                app.descendants(matching: .any)["system-health-latest-capture"],
                containing: "Captured successfully"
            ),
            app.debugDescription
        )
        app.buttons["system-health-preview-latest-evidence"].click()
        XCTAssertTrue(app.staticTexts["Unable to prepare the evidence package."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["system-health-latest-capture"].exists)
    }

    func testSystemHealthPreviewsLatestCaptureThroughCanonicalPath() {
        relaunchIncidentFixture("history")
        app.staticTexts["navigation-System Health"].click()

        let preview = app.buttons["system-health-preview-latest-evidence"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["evidence-export-preview"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-version-manifest"].exists, app.debugDescription)
    }

    func testEvidenceExportSaveActionsUseProductionWriter() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-i81-ui-\(UUID().uuidString)", isDirectory: true)
        let jsonDestination = temporaryDirectory.appendingPathComponent("evidence.json")
        let textDestination = temporaryDirectory.appendingPathComponent("evidence.txt")
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        ))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        relaunchIncidentFixture("export-supported", exportDestination: jsonDestination.path)
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        app.buttons["evidence-export-save-json"].click()

        let jsonResult = app.descendants(matching: .any)["evidence-export-save-result"]
        XCTAssertTrue(jsonResult.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonDestination.path))
        let jsonAttributes = try? FileManager.default.attributesOfItem(atPath: jsonDestination.path)
        XCTAssertEqual((jsonAttributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        relaunchIncidentFixture("export-supported", exportDestination: textDestination.path)
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        app.buttons["evidence-export-save-text"].click()

        let textResult = app.descendants(matching: .any)["evidence-export-save-result"]
        XCTAssertTrue(textResult.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: textDestination.path))
        let textAttributes = try? FileManager.default.attributesOfItem(atPath: textDestination.path)
        XCTAssertEqual((textAttributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEvidenceExportSaveActionsUseRealUserSelectedDestination() throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let suffix = UUID().uuidString
        let jsonDestination = documents.appendingPathComponent("Small-Matter-UI-\(suffix).json")
        let textDestination = documents.appendingPathComponent("Small-Matter-UI-\(suffix).text")
        defer {
            try? FileManager.default.removeItem(at: jsonDestination)
            try? FileManager.default.removeItem(at: textDestination)
        }

        relaunchIncidentFixture("export-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        saveThroughRealSavePanel(button: "evidence-export-save-json", filename: jsonDestination.lastPathComponent)
        let jsonData = try Data(contentsOf: jsonDestination)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: jsonData), "The JSON export must be valid JSON.")
        XCTAssertFalse(String(data: jsonData, encoding: .utf8)?.contains(documents.path) == true)
        XCTAssertEqual(try permissions(of: jsonDestination), 0o600)

        relaunchIncidentFixture("export-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        saveThroughRealSavePanel(button: "evidence-export-save-json", filename: jsonDestination.lastPathComponent)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(contentsOf: jsonDestination)))
        XCTAssertEqual(try permissions(of: jsonDestination), 0o600)

        relaunchIncidentFixture("export-supported")
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        saveThroughRealSavePanel(button: "evidence-export-save-text", filename: textDestination.lastPathComponent)
        XCTAssertTrue(try String(data: Data(contentsOf: textDestination), encoding: .utf8)?
            .contains("SMALL MATTER") == true)
        XCTAssertEqual(try permissions(of: textDestination), 0o600)
    }

    private func saveThroughRealSavePanel(button: String, filename: String) {
        app.buttons[button].click()
        let panel = app.descendants(matching: .any)["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        let wherePopup = app.popUpButtons["where popup"]
        if wherePopup.waitForExistence(timeout: 2), (wherePopup.value as? String) != "Documents" {
            wherePopup.click()
            let documentsItem = app.menuItems["Documents"]
            if documentsItem.waitForExistence(timeout: 2) {
                documentsItem.click()
            }
        }
        let nameField = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), app.debugDescription)
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(filename)
        app.buttons["OKButton"].click()
        if app.buttons["action-button-1"].waitForExistence(timeout: 2) {
            app.buttons["action-button-1"].click()
        }
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    func testEvidenceExportSaveFailureIsVisibleWithoutDebugDetails() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-i81-ui-missing-\(UUID().uuidString)", isDirectory: true)
        let destination = missingDirectory.appendingPathComponent("evidence.json")
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        relaunchIncidentFixture("export-supported", exportDestination: destination.path)
        app.staticTexts["navigation-Recent Changes"].click()
        app.buttons["incident-history-row-00000000-0000-0000-0000-000000000305"].click()
        app.buttons["incident-preview-evidence-export"].click()
        app.buttons["evidence-export-save-json"].click()

        let failure = app.descendants(matching: .any)["evidence-export-save-error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unable to save the evidence export."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["evidence-export-save-result"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["evidence-export-preview"].exists)
        XCTAssertFalse(app.debugDescription.contains(destination.path))
        XCTAssertFalse(app.debugDescription.contains("NSError"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        // Why: cohesive reviewed boundary.
    }
} // swiftlint:disable:this file_length
