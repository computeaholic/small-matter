import AppKit
@testable import Tunix
import XCTest

@MainActor
final class KeepAwakeTests: XCTestCase {
    func testStartsInactiveWithoutPersistence() {
        let backend = StubKeepAwakeBackend()
        let controller = KeepAwakeController(backend: backend, notificationCenter: NotificationCenter())

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(backend.createCount, 0)
    }

    func testEnableCreatesExactlyOneAssertion() {
        let backend = StubKeepAwakeBackend()
        let controller = KeepAwakeController(backend: backend, notificationCenter: NotificationCenter())

        controller.enable()
        controller.enable()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertTrue(backend.releasedIDs.isEmpty)
    }

    func testDisableReleasesAssertion() {
        let backend = StubKeepAwakeBackend()
        let controller = KeepAwakeController(backend: backend, notificationCenter: NotificationCenter())

        controller.enable()
        controller.disable()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(backend.releasedIDs, [42])
    }

    func testTerminationReleasesAssertion() {
        let backend = StubKeepAwakeBackend()
        let notificationCenter = NotificationCenter()
        let controller = KeepAwakeController(backend: backend, notificationCenter: notificationCenter)

        controller.enable()
        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(backend.releasedIDs, [42])
    }

    func testFailedAssertionCreationStaysInactive() {
        let backend = StubKeepAwakeBackend(assertionID: nil)
        let controller = KeepAwakeController(backend: backend, notificationCenter: NotificationCenter())

        controller.enable()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.lastError, "Keep Awake could not be enabled.")
        XCTAssertEqual(backend.createCount, 1)
    }
}

private final class StubKeepAwakeBackend: KeepAwakeAssertionBackend {
    let assertionID: UInt32?
    private(set) var createCount = 0
    private(set) var releasedIDs: [UInt32] = []

    init(assertionID: UInt32? = 42) {
        self.assertionID = assertionID
    }

    func createAssertion() -> UInt32? {
        createCount += 1
        return assertionID
    }

    func releaseAssertion(_ assertionID: UInt32) {
        releasedIDs.append(assertionID)
    }
}
