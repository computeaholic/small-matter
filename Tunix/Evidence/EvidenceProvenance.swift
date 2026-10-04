import Foundation

enum EvidenceHostScope: String, Codable, Equatable, Sendable {
    case provenOnTestedHost = "PROVEN_ON_TESTED_HOST"
    case supportedProductBehavior = "SUPPORTED_PRODUCT_BEHAVIOR"
    case unknown = "UNKNOWN"
}

struct EvidenceProvenance: Codable, Equatable, Sendable {
    let sourceID: Horizon2SourceID
    let apiName: String
    let apiVersion: String?
    let captureChannel: String
    let sourceTimestampQuality: EvidenceTimestampQuality
    let normalizationRuleID: String
    let normalizationRuleVersion: String
    let hostScope: EvidenceHostScope
    let rawReferenceDigest: String?
}
