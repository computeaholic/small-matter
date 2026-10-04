import Foundation

indirect enum EvidenceValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    /// Decimal values are kept as a canonical string to avoid binary floating-point loss.
    case decimal(String)
    case boolean(Bool)
    case date(Date)
    case bytes(Data)
    case array([EvidenceValue])
    case object([String: EvidenceValue])
    case null

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case unsigned
        case decimal
        case boolean
        case date
        case bytes
        case array
        case object
        case null
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .string:
            self = try .string(container.decode(String.self, forKey: .value))
        case .integer:
            self = try .integer(container.decode(Int64.self, forKey: .value))
        case .unsigned:
            self = try .unsigned(container.decode(UInt64.self, forKey: .value))
        case .decimal:
            self = try .decimal(container.decode(String.self, forKey: .value))
        case .boolean:
            self = try .boolean(container.decode(Bool.self, forKey: .value))
        case .date:
            self = try .date(container.decode(Date.self, forKey: .value))
        case .bytes:
            self = try .bytes(container.decode(Data.self, forKey: .value))
        case .array:
            self = try .array(container.decode([EvidenceValue].self, forKey: .value))
        case .object:
            self = try .object(container.decode([String: EvidenceValue].self, forKey: .value))
        case .null:
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .unsigned(value):
            try container.encode(Kind.unsigned, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .bytes(value):
            try container.encode(Kind.bytes, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .array(value):
            try container.encode(Kind.array, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .object(value):
            try container.encode(Kind.object, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        }
    }

    func deterministicData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum EvidenceUnknownReason: String, Codable, Equatable, Sendable {
    case sourceUnavailable = "SOURCE_UNAVAILABLE"
    case permissionOrAPIUnavailable = "PERMISSION_API_UNAVAILABLE"
    case identityUnavailable = "IDENTITY_UNAVAILABLE"
    case clockUnavailable = "CLOCK_UNAVAILABLE"
    case notObserved = "NOT_OBSERVED"
    case redacted = "REDACTED"
    case contradictoryEvidence = "CONTRADICTORY_EVIDENCE"
    case incompleteCapture = "INCOMPLETE_CAPTURE"
    case journalCapacityUnavailable = "JOURNAL_CAPACITY_UNAVAILABLE"
    case processInterrupted = "PROCESS_INTERRUPTED"
    case contextUnavailable = "CONTEXT_UNAVAILABLE"
    case wallClockDiscontinuity = "WALL_CLOCK_DISCONTINUITY"
    case sourceCoverageGap = "SOURCE_COVERAGE_GAP"
}

enum EvidenceAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(EvidenceUnknownReason)
    case unknown(EvidenceUnknownReason)

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case available
        case unavailable
        case unknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available:
            self = .available
        case .unavailable:
            self = try .unavailable(container.decode(EvidenceUnknownReason.self, forKey: .reason))
        case .unknown:
            self = try .unknown(container.decode(EvidenceUnknownReason.self, forKey: .reason))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case let .unavailable(reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .reason)
        case let .unknown(reason):
            try container.encode(State.unknown, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}
