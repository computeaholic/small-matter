import Foundation

enum NextTestRiskClass: String, Codable, Equatable, Sendable {
    case safe = "SAFE"
    case caution = "CAUTION"
}

enum NextTestPrerequisite: String, Codable, Equatable, Sendable {
    case storageSafelyUnmounted = "STORAGE_SAFELY_UNMOUNTED"
    case noActiveWrites = "NO_ACTIVE_WRITES"
    case sufficientBattery = "SUFFICIENT_BATTERY"
    case userConfirmedInterruption = "USER_CONFIRMED_INTERRUPTION"
}

enum NextTestActionKind: String, Codable, Equatable, Sendable {
    case inspect = "INSPECT"
    case observe = "OBSERVE"
    case disconnectStorage = "DISCONNECT_STORAGE"
    case privileged = "PRIVILEGED"
    case hardwareWrite = "HARDWARE_WRITE"
    case disableSecurity = "DISABLE_SECURITY"
    case arbitraryShell = "ARBITRARY_SHELL"
    case hiddenNetwork = "HIDDEN_NETWORK"
}

enum NextTestValidationIssue: String, Error, Codable, Equatable, Sendable {
    case privilegedAction = "PRIVILEGED_ACTION"
    case hardwareWrite = "HARDWARE_WRITE"
    case disablesSecurity = "DISABLES_SECURITY"
    case arbitraryShell = "ARBITRARY_SHELL"
    case hiddenNetworkActivity = "HIDDEN_NETWORK_ACTIVITY"
    case storagePrerequisiteMissing = "STORAGE_PREREQUISITE_MISSING"
    case stoppingConditionMissing = "STOPPING_CONDITION_MISSING"
    case catalogVersionMismatch = "CATALOG_VERSION_MISMATCH"
    case incompleteCatalogEntry = "INCOMPLETE_CATALOG_ENTRY"
    case duplicateCatalogReference = "DUPLICATE_CATALOG_REFERENCE"
}

struct NextTestReference: Codable, Equatable, Sendable {
    let testID: String
    let catalogVersion: String
    let purpose: String
    let evidenceExpected: String
}

struct NextTestCatalogEntry: Codable, Equatable, Sendable {
    let reference: NextTestReference
    let prerequisites: [NextTestPrerequisite]
    let prerequisiteExplanation: String?
    let riskClass: NextTestRiskClass
    let actionKind: NextTestActionKind
    let userAction: String
    let stoppingCondition: String
    let expectedObservations: String
    let safetyWarning: String
    let catalogProvenance: String

    init(
        reference: NextTestReference,
        prerequisites: [NextTestPrerequisite],
        prerequisiteExplanation: String? = nil,
        riskClass: NextTestRiskClass,
        actionKind: NextTestActionKind,
        userAction: String,
        stoppingCondition: String,
        expectedObservations: String,
        safetyWarning: String,
        catalogProvenance: String
    ) {
        self.reference = reference
        self.prerequisites = prerequisites
        self.prerequisiteExplanation = prerequisiteExplanation
        self.riskClass = riskClass
        self.actionKind = actionKind
        self.userAction = userAction
        self.stoppingCondition = stoppingCondition
        self.expectedObservations = expectedObservations
        self.safetyWarning = safetyWarning
        self.catalogProvenance = catalogProvenance
    }

    func validatedReference() throws -> NextTestReference {
        switch actionKind {
        case .privileged:
            throw NextTestValidationIssue.privilegedAction
        case .hardwareWrite:
            throw NextTestValidationIssue.hardwareWrite
        case .disableSecurity:
            throw NextTestValidationIssue.disablesSecurity
        case .arbitraryShell:
            throw NextTestValidationIssue.arbitraryShell
        case .hiddenNetwork:
            throw NextTestValidationIssue.hiddenNetworkActivity
        case .disconnectStorage:
            guard prerequisites.contains(.storageSafelyUnmounted),
                  prerequisites.contains(.noActiveWrites)
            else {
                throw NextTestValidationIssue.storagePrerequisiteMissing
            }
            guard !stoppingCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NextTestValidationIssue.stoppingConditionMissing
            }
        case .inspect, .observe:
            break
        }
        return reference
    }
}

struct NextTestCatalogSnapshot: Codable, Equatable, Sendable {
    let version: String
    let entries: [NextTestCatalogEntry]

    func entry(for reference: NextTestReference) -> NextTestCatalogEntry? {
        entries.first {
            $0.reference.testID == reference.testID
                && $0.reference.catalogVersion == reference.catalogVersion
        }
    }

    func validated() throws -> NextTestCatalogSnapshot {
        var references = Set<String>()
        for entry in entries {
            guard entry.reference.catalogVersion == version else {
                throw NextTestValidationIssue.catalogVersionMismatch
            }
            guard references.insert("\(entry.reference.testID)|\(entry.reference.catalogVersion)").inserted else {
                throw NextTestValidationIssue.duplicateCatalogReference
            }
            _ = try entry.validatedReference()
            guard !entry.reference.testID.isEmpty,
                  !entry.reference.purpose.isEmpty,
                  !entry.reference.evidenceExpected.isEmpty,
                  !entry.userAction.isEmpty,
                  !entry.stoppingCondition.isEmpty,
                  !entry.expectedObservations.isEmpty,
                  !entry.catalogProvenance.isEmpty
            else {
                throw NextTestValidationIssue.incompleteCatalogEntry
            }
        }
        return self
    }
}

enum Horizon2NextTestCatalog {
    static let currentVersion = "1.0.0"

    static let production = NextTestCatalogSnapshot(
        version: currentVersion,
        entries: [
            NextTestCatalogEntry(
                reference: NextTestReference(
                    testID: "INSPECT_STORAGE_STATE",
                    catalogVersion: currentVersion,
                    purpose: "Inspect whether macOS currently presents the expected storage device or volume.",
                    evidenceExpected: "A current storage disk or mounted-volume lifecycle fact."
                ),
                prerequisites: [],
                riskClass: .safe,
                actionKind: .inspect,
                userAction: "Inspect the current storage state in macOS.",
                stoppingCondition: "Stop when the current storage presentation is recorded.",
                expectedObservations: "The expected disk or volume is present, absent, mounted, or unmounted.",
                safetyWarning: "Small Matter does not disconnect hardware or change storage state.",
                catalogProvenance: "Horizon 2 I7 production catalog"
            ),
            NextTestCatalogEntry(
                reference: NextTestReference(
                    testID: "INSPECT_NETWORK_INTERFACE_STATE",
                    catalogVersion: currentVersion,
                    purpose: "Inspect current macOS Network interface and path state.",
                    evidenceExpected: "A current network path or normalized interface availability fact."
                ),
                prerequisites: [],
                riskClass: .safe,
                actionKind: .inspect,
                userAction: "Inspect the current Network interface and path state in macOS.",
                stoppingCondition: "Stop when the current interface and path state is recorded.",
                expectedObservations: "The path is available, unavailable, or an interface availability state is shown.",
                safetyWarning: "Small Matter does not ping, connect to, or modify the network.",
                catalogProvenance: "Horizon 2 I7 production catalog"
            ),
        ]
    )
}
