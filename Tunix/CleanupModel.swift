import Foundation

enum CleanupDistributionContext: String, Codable {
    case appStore = "Mac App Store"
    case direct = "Direct distribution"

    var allowsUserSelectedPermanentDeletion: Bool {
        self == .direct
    }

    static var current: Self {
        #if MAC_APP_STORE
            return .appStore
        #else
            return .direct
        #endif
    }
}

enum CleanupAccessState: String, Codable, Equatable {
    case eligible
    case restricted
    case excluded

    var label: String {
        switch self {
        case .eligible: return "Eligible"
        case .restricted: return "Restricted"
        case .excluded: return "Skipped"
        }
    }
}

enum CleanupRootScope: String, Codable, Equatable {
    case appOwned
    case xcodeDerivedData
}

enum CleanupSkipReason: String, Codable, Equatable, CaseIterable {
    case directory = "Directory not deleted recursively"
    case symbolicLink = "Symbolic link"
    case hardLink = "Hard-linked file"
    case unreadable = "Unreadable"
    case unwritable = "Not writable"
    case metadataUnavailable = "Metadata unavailable"
    case outsideApprovedScope = "Outside approved scope"
    case hidden = "Hidden file"
    case activeDevelopmentProcess = "Active development process"
    case processDetectionUnavailable = "Development-process detection unavailable"
    case inventoryLimitReached = "Inventory limit reached; scan incomplete"
    case scanCancelled = "Scan cancelled"

    var label: String {
        rawValue
    }
}

struct CleanupRoot: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let explanation: String
    let scope: CleanupRootScope

    init(
        id: String,
        name: String,
        url: URL,
        explanation: String,
        scope: CleanupRootScope = .appOwned
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.explanation = explanation
        self.scope = scope
    }
}

struct CleanupFileMetadata: Equatable {
    let identity: String
    let path: String
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let modificationDate: Date?
    let resourceIdentifier: String?
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let hardLinkCount: UInt64
    let isReadable: Bool
    let isWritable: Bool

    var fingerprint: CleanupFileFingerprint {
        CleanupFileFingerprint(
            identity: identity,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier
        )
    }
}

struct CleanupFileFingerprint: Codable, Equatable {
    let identity: String
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let modificationDate: Date?
    let resourceIdentifier: String?
}

struct CleanupCandidate: Identifiable, Codable, Equatable {
    let id: String
    let rootID: String
    let category: String
    let path: String
    let displayName: String
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let evidence: String
    let approvedRootResourceIdentifier: String?
    let access: CleanupAccessState
    let exclusionReason: String?
    let fingerprint: CleanupFileFingerprint
}

struct CleanupSkipSummary: Identifiable, Equatable {
    let reason: CleanupSkipReason
    let count: Int

    var id: String {
        reason.rawValue
    }
}

struct CleanupInventory: Equatable {
    let scannedItemCount: Int
    let candidates: [CleanupCandidate]
    let skipped: [CleanupSkipSummary]
    let roots: [CleanupRoot]
    let distribution: CleanupDistributionContext
    let scannedAt: Date
    let isComplete: Bool

    var estimatedAllocatedBytes: UInt64 {
        candidates.reduce(0) { $0 + $1.allocatedBytes }
    }
}

struct CleanupDiagnostic: Identifiable, Equatable {
    let category: String
    let reason: String
    let count: Int

    var id: String {
        "\(category)-\(reason)"
    }
}

struct CleanupDeletionResult: Equatable {
    let scannedItemCount: Int
    let attemptedCount: Int
    let deletedCount: Int
    let staleCount: Int
    let failedCount: Int
    let estimatedAllocatedBytes: UInt64
    let observedSpaceReclaimedBytes: UInt64?
    let availableBytesBefore: UInt64?
    let availableBytesAfter: UInt64?
    let diagnostics: [CleanupDiagnostic]
    let completedAt: Date

    var isSuccessful: Bool {
        attemptedCount > 0 && failedCount == 0 && staleCount == 0 && deletedCount == attemptedCount
    }
}

struct CleanupDeletionRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let deletedCount: Int
    let failedCount: Int
    let staleCount: Int
    let estimatedAllocatedBytes: UInt64
    let observedSpaceReclaimedBytes: UInt64?
}
