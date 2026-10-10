import Foundation

enum NetworkPathStatus: String, Codable, Equatable, Sendable {
    case satisfied = "SATISFIED"
    case unsatisfied = "UNSATISFIED"
    case requiresConnection = "REQUIRES_CONNECTION"
}

enum NetworkInterfaceFact: String, Codable, Equatable, Sendable, CaseIterable {
    case wifi = "WIFI"
    case wiredEthernet = "WIRED_ETHERNET"
    case cellular = "CELLULAR"
    case loopback = "LOOPBACK"
    case other = "OTHER"
}

struct NetworkRawPath: Codable, Equatable, Sendable {
    let status: NetworkPathStatus
    let interfaces: Set<NetworkInterfaceFact>
}

struct NetworkRawTransition: Equatable, Sendable {
    let previous: NetworkRawPath
    let current: NetworkRawPath
    let occurrence: EvidenceSourceOccurrence
}

enum NetworkPathNormalizer {
    // swiftlint:disable:next function_body_length
    static func normalize(_ raw: NetworkRawTransition) -> NormalizedEvidenceFact? {
        guard raw.previous != raw.current else { return nil }
        let interfaces = raw.current.interfaces.sorted { $0.rawValue < $1.rawValue }
        return NormalizedEvidenceFact(
            sourceID: .network,
            domain: .network,
            eventKind: .networkPathTransition,
            subject: EvidenceSubject(
                type: .networkInterface,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: "Network path"
            ),
            provenance: EvidenceProvenance(
                sourceID: .network,
                apiName: "Network.framework",
                apiVersion: nil,
                captureChannel: "NWPathMonitor",
                sourceTimestampQuality: raw.occurrence.quality,
                normalizationRuleID: "H2_NETWORK_PATH_NORMALIZE",
                normalizationRuleVersion: "1.0.0",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: nil
            ),
            availability: .available,
            previousState: .object([
                "status": .string(raw.previous.status.rawValue),
                "interfaces": .array(raw.previous.interfaces.sorted { $0.rawValue < $1.rawValue }
                    .map { .string($0.rawValue) })
            ]),
            currentState: .object([
                "status": .string(raw.current.status.rawValue),
                "interfaces": .array(interfaces.map { .string($0.rawValue) })
            ]),
            attributes: [
                "supplemental": .boolean(true),
                "interfaceTypes": .array(interfaces.map { .string($0.rawValue) })
            ],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("previousState.status"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("previousState.interfaces[*]"),
                    classification: .networkMetadata,
                    pseudonymization: .allowed(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.status"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.interfaces[*]"),
                    classification: .networkMetadata,
                    pseudonymization: .allowed(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.supplemental"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.interfaceTypes[*]"),
                    classification: .networkMetadata,
                    pseudonymization: .allowed(scope: "package")
                )
            ]),
            sourceOccurrence: raw.occurrence,
            lifecycleBoundary: .none
        )
    }
}

enum SleepWakeEventKind: String, Sendable {
    case willSleep
    case didWake
}

struct SleepWakeRawEvent: Sendable {
    let kind: SleepWakeEventKind
    let observedAt: EvidenceClockReading?
    let ingressOrder: UInt64?

    init(
        kind: SleepWakeEventKind,
        observedAt: EvidenceClockReading? = nil,
        ingressOrder: UInt64? = nil
    ) {
        self.kind = kind
        self.observedAt = observedAt
        self.ingressOrder = ingressOrder
    }
}
