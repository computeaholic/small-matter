import Foundation

enum EvidenceDomain: Codable, Equatable, Sendable {
    case display
    case storage
    case network
    case power
    case sleepWake
    case thermal
    case usb
    case systemContext
    case unknown(String)

    private enum Known: String, Codable {
        case display = "DISPLAY"
        case storage = "STORAGE"
        case network = "NETWORK"
        case power = "POWER"
        case sleepWake = "SLEEP_WAKE"
        case thermal = "THERMAL"
        case usb = "USB"
        case systemContext = "SYSTEM_CONTEXT"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let known = Known(rawValue: value) else {
            self = .unknown(value)
            return
        }
        switch known {
        case .display: self = .display
        case .storage: self = .storage
        case .network: self = .network
        case .power: self = .power
        case .sleepWake: self = .sleepWake
        case .thermal: self = .thermal
        case .usb: self = .usb
        case .systemContext: self = .systemContext
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .display: try container.encode(Known.display.rawValue)
        case .storage: try container.encode(Known.storage.rawValue)
        case .network: try container.encode(Known.network.rawValue)
        case .power: try container.encode(Known.power.rawValue)
        case .sleepWake: try container.encode(Known.sleepWake.rawValue)
        case .thermal: try container.encode(Known.thermal.rawValue)
        case .usb: try container.encode(Known.usb.rawValue)
        case .systemContext: try container.encode(Known.systemContext.rawValue)
        case let .unknown(value): try container.encode(value)
        }
    }
}

enum EvidenceEventKind: Codable, Equatable, Sendable {
    case storageDiskLifecycle
    case storageMountLifecycle
    case networkPathTransition
    case powerSourceTransition
    case sleepWakeBoundary(EvidenceLifecycleBoundary)
    case sourceUnavailable
    case sourceSuppressed
    case unknown(String)

    private enum Known: String, Codable {
        case storageDiskLifecycle = "STORAGE_DISK_LIFECYCLE"
        case storageMountLifecycle = "STORAGE_MOUNT_LIFECYCLE"
        case networkPathTransition = "NETWORK_PATH_TRANSITION"
        case powerSourceTransition = "POWER_SOURCE_TRANSITION"
        case sourceUnavailable = "SOURCE_UNAVAILABLE"
        case sourceSuppressed = "SOURCE_SUPPRESSED"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case boundary
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.eventKind(from: value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "SLEEP_WAKE_BOUNDARY" else {
            self = .unknown(kind)
            return
        }
        self = try .sleepWakeBoundary(container.decode(EvidenceLifecycleBoundary.self, forKey: .boundary))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .storageDiskLifecycle: try encode(Known.storageDiskLifecycle.rawValue, with: encoder)
        case .storageMountLifecycle: try encode(Known.storageMountLifecycle.rawValue, with: encoder)
        case .networkPathTransition: try encode(Known.networkPathTransition.rawValue, with: encoder)
        case .powerSourceTransition: try encode(Known.powerSourceTransition.rawValue, with: encoder)
        case let .sleepWakeBoundary(boundary):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("SLEEP_WAKE_BOUNDARY", forKey: .kind)
            try container.encode(boundary, forKey: .boundary)
        case .sourceUnavailable: try encode(Known.sourceUnavailable.rawValue, with: encoder)
        case .sourceSuppressed: try encode(Known.sourceSuppressed.rawValue, with: encoder)
        case let .unknown(value): try encode(value, with: encoder)
        }
    }

    private func encode(_ value: String, with encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func eventKind(from value: String) -> EvidenceEventKind {
        switch value {
        case Known.storageDiskLifecycle.rawValue: return .storageDiskLifecycle
        case Known.storageMountLifecycle.rawValue: return .storageMountLifecycle
        case Known.networkPathTransition.rawValue: return .networkPathTransition
        case Known.powerSourceTransition.rawValue: return .powerSourceTransition
        case Known.sourceUnavailable.rawValue: return .sourceUnavailable
        case Known.sourceSuppressed.rawValue: return .sourceSuppressed
        case "SLEEP_WAKE_BOUNDARY": return .sleepWakeBoundary(.sleepWake)
        default: return .unknown(value)
        }
    }
}

struct Observation: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = Horizon2EvidenceConfiguration.observationSchemaVersion

    let id: UUID
    let domain: EvidenceDomain
    let eventKind: EvidenceEventKind
    let sourceID: Horizon2SourceID
    let subject: EvidenceSubject
    let provenance: EvidenceProvenance
    let time: EvidenceTime
    let availability: EvidenceAvailability
    let previousState: EvidenceValue?
    let currentState: EvidenceValue?
    let attributes: [String: EvidenceValue]
    let sensitivity: EvidenceSensitivityRegistry
    let schemaVersion: Int

    init(
        id: UUID,
        domain: EvidenceDomain,
        eventKind: EvidenceEventKind,
        sourceID: Horizon2SourceID,
        subject: EvidenceSubject,
        provenance: EvidenceProvenance,
        time: EvidenceTime,
        availability: EvidenceAvailability = .available,
        previousState: EvidenceValue? = nil,
        currentState: EvidenceValue? = nil,
        attributes: [String: EvidenceValue] = [:],
        sensitivity: EvidenceSensitivityRegistry = .init(),
        schemaVersion: Int = Observation.currentSchemaVersion
    ) {
        self.id = id
        self.domain = domain
        self.eventKind = eventKind
        self.sourceID = sourceID
        self.subject = subject
        self.provenance = provenance
        self.time = time
        self.availability = availability
        self.previousState = previousState
        self.currentState = currentState
        self.attributes = attributes
        self.sensitivity = sensitivity
        self.schemaVersion = schemaVersion
    }

    func deterministicData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
