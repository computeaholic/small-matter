import Foundation

enum EvidenceSensitivity: String, Codable, CaseIterable, Equatable, Sendable {
    case none = "NONE"
    case deviceMetadata = "DEVICE_METADATA"
    case networkMetadata = "NETWORK_METADATA"
    case applicationMetadata = "APPLICATION_METADATA"
    case filesystemMetadata = "FILESYSTEM_METADATA"
    case personal = "PERSONAL"
}

enum EvidencePseudonymizationPolicy: Codable, Equatable, Sendable {
    case notApplicable
    case allowed(scope: String)
    case required(scope: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case state
        case scope
    }

    private enum State: String, Codable {
        case notApplicable = "NOT_APPLICABLE"
        case allowed = "ALLOWED"
        case required = "REQUIRED"
        case unknown = "UNKNOWN"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .notApplicable:
            self = .notApplicable
        case .allowed:
            self = try .allowed(scope: container.decode(String.self, forKey: .scope))
        case .required:
            self = try .required(scope: container.decode(String.self, forKey: .scope))
        case .unknown:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notApplicable:
            try container.encode(State.notApplicable, forKey: .state)
        case let .allowed(scope):
            try container.encode(State.allowed, forKey: .state)
            try container.encode(scope, forKey: .scope)
        case let .required(scope):
            try container.encode(State.required, forKey: .state)
            try container.encode(scope, forKey: .scope)
        case .unknown:
            try container.encode(State.unknown, forKey: .state)
        }
    }
}

struct EvidenceFieldPath: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct EvidenceFieldSensitivity: Codable, Equatable, Sendable {
    let path: EvidenceFieldPath
    let classification: EvidenceSensitivity
    let pseudonymization: EvidencePseudonymizationPolicy
}

struct EvidenceSensitivityRegistry: Codable, Equatable, Sendable {
    let fields: [EvidenceFieldSensitivity]

    init(fields: [EvidenceFieldSensitivity] = []) {
        self.fields = fields
    }

    func classification(for path: EvidenceFieldPath) -> EvidenceSensitivity? {
        fields.first(where: { $0.path == path })?.classification
    }

    func metadata(for path: EvidenceFieldPath) -> EvidenceFieldSensitivity? {
        fields.first(where: { $0.path == path })
    }
}
