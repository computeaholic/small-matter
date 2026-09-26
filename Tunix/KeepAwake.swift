import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI

protocol KeepAwakeAssertionBackend {
    func createAssertion() -> UInt32?
    func releaseAssertion(_ assertionID: UInt32)
}

struct NativeKeepAwakeAssertionBackend: KeepAwakeAssertionBackend {
    func createAssertion() -> UInt32? {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "\(ProductIdentity.displayName) Keep Awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else { return nil }
        return assertionID
    }

    func releaseAssertion(_ assertionID: UInt32) {
        _ = IOPMAssertionRelease(IOPMAssertionID(assertionID))
    }
}

@MainActor
final class KeepAwakeController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    let assertionType = "Prevent idle system sleep"

    private let backend: KeepAwakeAssertionBackend
    private let notificationCenter: NotificationCenter
    private var assertionID: UInt32?
    private var terminationObserver: NSObjectProtocol?

    init(
        backend: KeepAwakeAssertionBackend = NativeKeepAwakeAssertionBackend(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.backend = backend
        self.notificationCenter = notificationCenter
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.disable()
            }
        }
    }

    deinit {
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
        }
        if let assertionID {
            backend.releaseAssertion(assertionID)
        }
    }

    var statusLabel: String {
        isEnabled ? "Active" : "Inactive"
    }

    var statusDetail: String {
        isEnabled
            ? "Keeps this Mac awake while \(ProductIdentity.displayName) is running."
            : "Idle sleep behaves normally."
    }

    var binding: Binding<Bool> {
        Binding(
            get: { self.isEnabled },
            set: { self.setEnabled($0) }
        )
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func enable() {
        guard !isEnabled else { return }
        guard let assertionID = backend.createAssertion() else {
            lastError = "Keep Awake could not be enabled."
            isEnabled = false
            return
        }
        self.assertionID = assertionID
        lastError = nil
        isEnabled = true
    }

    func disable() {
        guard let assertionID else {
            isEnabled = false
            return
        }
        backend.releaseAssertion(assertionID)
        self.assertionID = nil
        isEnabled = false
        lastError = nil
    }
}
