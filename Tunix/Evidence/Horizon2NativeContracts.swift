// swiftlint:disable line_length trailing_comma identifier_name
import CryptoKit
import Foundation

enum EvidenceSourceHealthEvent: String, Codable, Equatable, Sendable {
    case started = "STARTED"
    case stopped = "STOPPED"
    case startupFailure = "STARTUP_FAILURE"
    case callbackRegistrationFailure = "CALLBACK_REGISTRATION_FAILURE"
    case sourceUnavailable = "SOURCE_UNAVAILABLE"
    case reconciliationFailure = "RECONCILIATION_FAILURE"
    case reconciliationRequired = "RECONCILIATION_REQUIRED"
    case reconciliationCompleted = "RECONCILIATION_COMPLETED"
    case duplicateSuppressed = "DUPLICATE_SUPPRESSED"
}

enum EvidenceAdapterEmission: Sendable {
    case raw(Horizon2RawEvent)
    case health(EvidenceSourceHealthUpdate)

    var sourceID: Horizon2SourceID {
        switch self {
        case let .raw(raw):
            switch raw {
            case .storage: return .storage
            case .power: return .power
            case .network: return .network
            case .lifecycle: return .sleepWake
            }
        case let .health(update):
            return update.sourceID
        }
    }
}

struct EvidenceSourceHealthUpdate: Sendable {
    let sourceID: Horizon2SourceID
    let event: EvidenceSourceHealthEvent
    let reason: EvidenceUnknownReason
    let suppressedCount: Int
    let observedAt: Date
    let detail: String?
}

protocol Horizon2EvidenceAdapter: AnyObject, Sendable {
    var sourceID: Horizon2SourceID { get }
    func start()
    func stop()
    func reconcileAfterWake()
}

enum Horizon2RawEvent: Sendable {
    case storage(StorageRawEvent)
    case power(PowerRawTransition)
    case network(NetworkRawTransition)
    case lifecycle(SleepWakeRawEvent)
}

struct NormalizedEvidenceFact: Sendable {
    let sourceID: Horizon2SourceID
    let domain: EvidenceDomain
    let eventKind: EvidenceEventKind
    let subject: EvidenceSubject
    let provenance: EvidenceProvenance
    let availability: EvidenceAvailability
    let previousState: EvidenceValue?
    let currentState: EvidenceValue?
    let attributes: [String: EvidenceValue]
    let sensitivity: EvidenceSensitivityRegistry
    let sourceOccurrence: EvidenceSourceOccurrence?
    let lifecycleBoundary: EvidenceLifecycleBoundary
}

enum EvidenceIdentityDigest {
    static func make(scope: String, material: [String]) -> String? {
        let values = material.filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        let canonical = ([scope] + values).joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func makeUUID(scope: String, material: [String]) -> UUID? {
        guard let hex = make(scope: scope, material: material), hex.count >= 32 else { return nil }
        let characters = Array(hex.prefix(32))
        let groups = [
            String(characters[0 ..< 8]),
            String(characters[8 ..< 12]),
            String(characters[12 ..< 16]),
            String(characters[16 ..< 20]),
            String(characters[20 ..< 32]),
        ]
        return UUID(uuidString: groups.joined(separator: "-"))
    }
}

struct StorageRawIdentity: Equatable, Sendable {
    let volumeName: String?
    let filesystemPath: String?
    let serialNumber: String?
    let hardwareUUID: String?
    let mediaUUID: String?
    let bsdName: String?
    let isWholeDisk: Bool?

    var quality: EvidenceIdentityQuality {
        if mediaUUID != nil || hardwareUUID != nil || serialNumber != nil {
            return .qualified
        }
        if volumeName != nil || filesystemPath != nil || bsdName != nil {
            return .weak
        }
        return .unavailable
    }

    var digestMaterial: [String] {
        [mediaUUID, hardwareUUID, serialNumber, volumeName, filesystemPath, bsdName]
            .compactMap { $0 }
    }
}

enum StorageRawEventKind: String, Equatable, Sendable {
    case diskAppeared
    case diskDisappeared
    case volumeMounted
    case volumeUnmounted
}

struct StorageDuplicateGate: Sendable {
    private let maximumEntries: Int
    private var deliveredTokens: Set<String> = []
    private var tokenOrder: [String] = []

    init(maximumEntries: Int = 256) {
        self.maximumEntries = max(1, maximumEntries)
    }

    mutating func shouldSuppress(_ raw: StorageRawEvent) -> Bool {
        guard let callbackToken = raw.callbackToken else { return false }
        let token = [raw.kind.rawValue, callbackToken, raw.identity.digestMaterial.joined(separator: "\u{1F}")]
            .joined(separator: "\u{1E}")
        guard !deliveredTokens.contains(token) else { return true }
        deliveredTokens.insert(token)
        tokenOrder.append(token)
        if tokenOrder.count > maximumEntries, let retired = tokenOrder.first {
            tokenOrder.removeFirst()
            deliveredTokens.remove(retired)
        }
        return false
    }

    var countForTesting: Int {
        deliveredTokens.count
    }
}

enum StorageEventNormalizer {
    // swiftlint:disable:next function_body_length
    static func normalize(_ raw: StorageRawEvent, identityScope: String) -> NormalizedEvidenceFact {
        let identityDigest = EvidenceIdentityDigest.make(scope: identityScope, material: raw.identity.digestMaterial)
        let subjectType: EvidenceSubjectType = raw.kind == .volumeMounted || raw.kind == .volumeUnmounted
            ? .mountedVolume
            : .storageDisk
        let eventKind: EvidenceEventKind = raw.kind == .volumeMounted || raw.kind == .volumeUnmounted
            ? .storageMountLifecycle
            : .storageDiskLifecycle
        let state = EvidenceValue.object([
            "lifecycle": .string(raw.kind.rawValue),
            "identityQuality": .string(raw.identity.quality.rawValue),
        ])
        let attributes: [String: EvidenceValue] = [
            "lifecycle": .string(raw.kind.rawValue),
            "identityQuality": .string(raw.identity.quality.rawValue),
            "isWholeDisk": raw.identity.isWholeDisk.map(EvidenceValue.boolean) ?? .null,
        ]
        return NormalizedEvidenceFact(
            sourceID: .storage,
            domain: .storage,
            eventKind: eventKind,
            subject: EvidenceSubject(
                type: subjectType,
                identityDigest: identityDigest,
                quality: raw.identity.quality,
                safeDisplayLabel: subjectType == .storageDisk ? "Storage device" : "Mounted volume"
            ),
            provenance: EvidenceProvenance(
                sourceID: .storage,
                apiName: raw.kind == .volumeMounted || raw.kind == .volumeUnmounted ? "NSWorkspace" : "Disk Arbitration",
                apiVersion: nil,
                captureChannel: raw.kind == .volumeMounted || raw.kind == .volumeUnmounted ? "NSWorkspace volume notification" : "Disk Arbitration callback",
                sourceTimestampQuality: raw.occurrence.quality,
                normalizationRuleID: "H2_STORAGE_LIFECYCLE_NORMALIZE",
                normalizationRuleVersion: "1.0.0",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: identityDigest
            ),
            availability: .available,
            previousState: nil,
            currentState: state,
            attributes: attributes.merging([
                "semanticRole": .string(raw.semanticRole.rawValue),
            ]) { current, _ in current },
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(path: EvidenceFieldPath("subject.identityDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("provenance.rawReferenceDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.lifecycle"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.identityQuality"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.isWholeDisk"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.lifecycle"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.identityQuality"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.isWholeDisk"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.semanticRole"), classification: .none, pseudonymization: .notApplicable),
            ]),
            sourceOccurrence: raw.occurrence,
            lifecycleBoundary: .none
        )
    }
}

enum PowerSourceKind: String, Codable, Equatable, Sendable {
    case ac = "AC"
    case battery = "BATTERY"
    case unknown = "UNKNOWN"
}

struct PowerRawState: Codable, Equatable, Sendable {
    let externalPowerConnected: Bool
    let source: PowerSourceKind
    let charging: Bool?
    let currentCapacity: Int?
    let maximumCapacity: Int?

    var meaningfulState: EvidenceValue {
        .object([
            "externalPowerConnected": .boolean(externalPowerConnected),
            "source": .string(source.rawValue),
            "charging": charging.map(EvidenceValue.boolean) ?? .null,
            "currentCapacity": currentCapacity.map { .integer(Int64($0)) } ?? .null,
            "maximumCapacity": maximumCapacity.map { .integer(Int64($0)) } ?? .null,
        ])
    }
}

struct PowerRawTransition: Equatable, Sendable {
    let previous: PowerRawState
    let current: PowerRawState
    let occurrence: EvidenceSourceOccurrence
}

enum PowerTransitionNormalizer {
    static func normalize(_ raw: PowerRawTransition) -> NormalizedEvidenceFact? {
        let sourceChanged = raw.previous.source != raw.current.source
            || raw.previous.externalPowerConnected != raw.current.externalPowerConnected
        let chargingChanged = raw.previous.charging != raw.current.charging
        guard sourceChanged || chargingChanged else { return nil }
        return NormalizedEvidenceFact(
            sourceID: .power,
            domain: .power,
            eventKind: .powerSourceTransition,
            subject: EvidenceSubject(type: .powerSource, identityDigest: "power-source", quality: .provenStable, safeDisplayLabel: "Direct power source"),
            provenance: EvidenceProvenance(
                sourceID: .power,
                apiName: "IOPowerSources",
                apiVersion: nil,
                captureChannel: "IOPowerSources notification",
                sourceTimestampQuality: raw.occurrence.quality,
                normalizationRuleID: "H2_POWER_TRANSITION_NORMALIZE",
                normalizationRuleVersion: "1.0.0",
                hostScope: .supportedProductBehavior,
                rawReferenceDigest: nil
            ),
            availability: .available,
            previousState: raw.previous.meaningfulState,
            currentState: raw.current.meaningfulState,
            attributes: [
                "transition": .string(sourceChanged ? "POWER_SOURCE" : "CHARGING_STATE"),
            ],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(path: EvidenceFieldPath("subject.identityDigest"), classification: .deviceMetadata, pseudonymization: .required(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.externalPowerConnected"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.source"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.charging"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.currentCapacity"), classification: .deviceMetadata, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.maximumCapacity"), classification: .deviceMetadata, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.externalPowerConnected"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.source"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.charging"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.currentCapacity"), classification: .deviceMetadata, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.maximumCapacity"), classification: .deviceMetadata, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.transition"), classification: .none, pseudonymization: .notApplicable),
            ]),
            sourceOccurrence: raw.occurrence,
            lifecycleBoundary: .none
        )
    }
}

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
    static func normalize(_ raw: NetworkRawTransition) -> NormalizedEvidenceFact? {
        guard raw.previous != raw.current else { return nil }
        let interfaces = raw.current.interfaces.sorted { $0.rawValue < $1.rawValue }
        return NormalizedEvidenceFact(
            sourceID: .network,
            domain: .network,
            eventKind: .networkPathTransition,
            subject: EvidenceSubject(type: .networkInterface, identityDigest: nil, quality: .unavailable, safeDisplayLabel: "Network path"),
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
                "interfaces": .array(raw.previous.interfaces.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            ]),
            currentState: .object([
                "status": .string(raw.current.status.rawValue),
                "interfaces": .array(interfaces.map { .string($0.rawValue) }),
            ]),
            attributes: [
                "supplemental": .boolean(true),
                "interfaceTypes": .array(interfaces.map { .string($0.rawValue) }),
            ],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.status"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("previousState.interfaces[*]"), classification: .networkMetadata, pseudonymization: .allowed(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.status"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("currentState.interfaces[*]"), classification: .networkMetadata, pseudonymization: .allowed(scope: "package")),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.supplemental"), classification: .none, pseudonymization: .notApplicable),
                EvidenceFieldSensitivity(path: EvidenceFieldPath("attributes.interfaceTypes[*]"), classification: .networkMetadata, pseudonymization: .allowed(scope: "package")),
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

// swiftlint:enable line_length trailing_comma identifier_name
