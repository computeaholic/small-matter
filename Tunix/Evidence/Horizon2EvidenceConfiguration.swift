// swiftformat:disable trailingCommas
import Foundation

enum Horizon2EvidenceConfiguration {
    static let specificationVersion = "2.4.0"
    static let architectureSpecificationSHA = "225c6bc1753bc7f4677cd43ad347e9670bb42c7a"
    static let observationSchemaVersion = 1
    static let incidentPackageSchemaVersion = 1
    static let evidencePackageSchemaVersion = 1
    // EvidenceSet v1 remains readable for historical I6 output. Version 2
    // records the temporal-basis semantics introduced by I6.1 explicitly.
    static let legacyEvidenceSetSchemaVersion = 1
    static let evidenceSetSchemaVersion = 2
    static let sqliteSchemaVersion = 1
    static let defaultRetentionDays = 7
    static let maximumRetentionDays = 30
    static let maximumJournalBytes = 16 * 1024 * 1024
    static let incidentPreWindowSeconds = 60
    static let incidentPostWindowSeconds = 120
    static let collectorQueueMaximum = 2048
    // No lower operating point passed the I9.4 repeated lossless-1x and
    // accepted-terminal-latency gates. Keep the current production capacity
    // explicit at the frozen maximum until a later authorized tuning change.
    static let collectorQueueCapacity = 2048
    static let pendingWriteQueueMaximum = 2048
    // The collector has no separate pending-persistence queue, so this is the
    // combined encoded payload budget for retained ingress work.
    static let combinedQueuePayloadMaximumBytes = 8 * 1024 * 1024
    // Measurement builds may override this only to select the production value
    // from repeated evidence; ordinary Release uses this compiled value.
    static let collectorQueueResidenceLimitMilliseconds = 725
    static let maximumBatchCount = 7
    static let maximumBatchPayloadBytes = 256 * 1024
    static let batchFixedOverheadBytes = 8 * 1024
    static let temporalEligibilitySeconds = 15
    static let transactionalHeadroomBytes = 1 * 1024 * 1024

    static func batchFits(count: Int, canonicalPayloadBytes: Int,
                          headroomBytes: Int = transactionalHeadroomBytes) -> Bool {
        count <= maximumBatchCount
            && canonicalPayloadBytes <= maximumBatchPayloadBytes
            && canonicalPayloadBytes + count * batchFixedOverheadBytes <= headroomBytes
    }

    static let sourceDispositions: [Horizon2SourceID: Horizon2SourceDisposition] = [
        .display: .deferred,
        .storage: .production,
        .network: .supplemental,
        .power: .production,
        .sleepWake: .controlBoundary,
        .thermal: .deferred,
        .usb: .deferred,
        .distribution: .controlBoundary,
        .qualification: .controlBoundary,
        .probeIsolation: .controlBoundary
    ]

    static let initialRuleIDs: Set<String> = [
        "EXTERNAL_STORAGE_LIFECYCLE",
        "NETWORK_PATH_TRANSITION"
    ]

    static let deferredRuleIDs: Set<String> = [
        "DOCK_SHARED_UPSTREAM_LOSS",
        "DISPLAY_WAKE_RECONCILIATION",
        "THERMAL_STATE_EPISODE"
    ]

    static let initialCorrelationRuleIDs: Set<String> = [
        "H2-CORR-STORAGE-LIFECYCLE",
        "H2-CORR-NETWORK-PATH-TRANSITION"
    ]
}

enum Horizon2SourceID: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case display = "H2-SOURCE-001"
    case storage = "H2-SOURCE-002"
    case network = "H2-SOURCE-003"
    case power = "H2-SOURCE-004"
    case sleepWake = "H2-SOURCE-005"
    case thermal = "H2-SOURCE-006"
    case usb = "H2-SOURCE-007"
    case distribution = "H2-SOURCE-008"
    case qualification = "H2-SOURCE-009"
    case probeIsolation = "H2-SOURCE-010"
}

enum Horizon2SourceDisposition: String, Codable, Equatable, Sendable {
    case production = "PRODUCTION"
    case supplemental = "SUPPLEMENTAL"
    case controlBoundary = "CONTROL_BOUNDARY"
    case deferred = "DEFERRED"
}

enum Horizon2SourceCapability {
    static func canProvideUserFacingEvidence(_ source: Horizon2SourceID) -> Bool {
        switch Horizon2EvidenceConfiguration.sourceDispositions[source] {
        case .production, .supplemental:
            return true
        case .controlBoundary, .deferred, .none:
            return false
        }
    }

    static func requiresProductionAdapter(_ source: Horizon2SourceID) -> Bool {
        switch Horizon2EvidenceConfiguration.sourceDispositions[source] {
        case .production, .supplemental:
            return true
        case .controlBoundary, .deferred, .none:
            return false
        }
    }
}
