import Foundation

enum EvidenceOrderingQuality: String, Codable, Equatable, Sendable {
    case totalWithinDomain = "TOTAL_WITHIN_DOMAIN"
    case partial = "PARTIAL"
    case incomparable = "INCOMPARABLE"
}

enum EvidenceTemporalBasis: String, Codable, Equatable, Sendable {
    case continuousClock = "CONTINUOUS_CLOCK"
    case wallClockFallback = "WALL_CLOCK_FALLBACK"
    case legacyUnspecified = "LEGACY_UNSPECIFIED"
}

struct EvidenceTimeBounds: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
}

enum EvidenceMembershipReason: Codable, Equatable, Sendable {
    case temporalEligibility(seconds: Int, basis: EvidenceTemporalBasis)
    case sameSubject
    case knownTopology(String)
    case explicitScenarioRule(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case basis
    }

    private enum Kind: String, Codable {
        case temporalEligibility = "TEMPORAL_ELIGIBILITY"
        case sameSubject = "SAME_SUBJECT"
        case knownTopology = "KNOWN_TOPOLOGY"
        case explicitScenarioRule = "EXPLICIT_SCENARIO_RULE"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .temporalEligibility:
            self = try .temporalEligibility(
                seconds: container.decode(Int.self, forKey: .value),
                basis: container.decodeIfPresent(EvidenceTemporalBasis.self, forKey: .basis)
                    ?? .legacyUnspecified
            )
        case .sameSubject:
            self = .sameSubject
        case .knownTopology:
            self = try .knownTopology(container.decode(String.self, forKey: .value))
        case .explicitScenarioRule:
            self = try .explicitScenarioRule(container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .temporalEligibility(seconds, basis):
            try container.encode(Kind.temporalEligibility, forKey: .kind)
            try container.encode(seconds, forKey: .value)
            // I6.1's basis field was added after the original v1 reason
            // representation. Preserve the old wire shape when re-encoding
            // a legacy reason; all current multi-member output is explicit.
            if basis != .legacyUnspecified {
                try container.encode(basis, forKey: .basis)
            }
        case .sameSubject:
            try container.encode(Kind.sameSubject, forKey: .kind)
        case let .knownTopology(value):
            try container.encode(Kind.knownTopology, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .explicitScenarioRule(value):
            try container.encode(Kind.explicitScenarioRule, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    var stableCode: String {
        switch self {
        case .temporalEligibility: return "TEMPORAL_ELIGIBILITY"
        case .sameSubject: return "SAME_SUBJECT"
        case .knownTopology: return "KNOWN_TOPOLOGY"
        case .explicitScenarioRule: return "EXPLICIT_SCENARIO_RULE"
        }
    }

    var canonicalValue: String {
        switch self {
        case let .temporalEligibility(seconds, basis): return "\(stableCode)|\(seconds)|\(basis.rawValue)"
        case .sameSubject: return stableCode
        case let .knownTopology(value): return "\(stableCode)|\(value)"
        case let .explicitScenarioRule(value): return "\(stableCode)|\(value)"
        }
    }

    static func temporalEligibility(seconds: Int) -> Self {
        .temporalEligibility(seconds: seconds, basis: .legacyUnspecified)
    }
}

struct EvidenceMembership: Codable, Equatable, Sendable {
    let observationID: UUID
    let reasons: [EvidenceMembershipReason]
}

struct EvidenceSet: Codable, Equatable, Sendable, Identifiable {
    static let legacySchemaVersion = Horizon2EvidenceConfiguration.legacyEvidenceSetSchemaVersion
    static let currentSchemaVersion = Horizon2EvidenceConfiguration.evidenceSetSchemaVersion

    let id: UUID
    let members: [EvidenceMembership]
    let ruleID: String?
    let ruleVersion: String?
    let temporalBounds: EvidenceTimeBounds
    let orderingQuality: EvidenceOrderingQuality
    let evidenceSetSchemaVersion: Int

    var schemaVersion: Int {
        evidenceSetSchemaVersion
    }

    init(
        id: UUID,
        members: [EvidenceMembership],
        ruleID: String?,
        ruleVersion: String?,
        temporalBounds: EvidenceTimeBounds,
        orderingQuality: EvidenceOrderingQuality,
        schemaVersion: Int? = nil,
        evidenceSetSchemaVersion: Int = EvidenceSet.currentSchemaVersion
    ) {
        self.id = id
        self.members = members
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.temporalBounds = temporalBounds
        self.orderingQuality = orderingQuality
        self.evidenceSetSchemaVersion = schemaVersion ?? evidenceSetSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case members
        case ruleID
        case ruleVersion
        case temporalBounds
        case orderingQuality
        case evidenceSetSchemaVersion
        case legacySchemaVersion = "schemaVersion"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            members: container.decode([EvidenceMembership].self, forKey: .members),
            ruleID: container.decodeIfPresent(String.self, forKey: .ruleID),
            ruleVersion: container.decodeIfPresent(String.self, forKey: .ruleVersion),
            temporalBounds: container.decode(EvidenceTimeBounds.self, forKey: .temporalBounds),
            orderingQuality: container.decode(EvidenceOrderingQuality.self, forKey: .orderingQuality),
            evidenceSetSchemaVersion: container.decodeIfPresent(Int.self, forKey: .evidenceSetSchemaVersion)
                ?? container.decodeIfPresent(Int.self, forKey: .legacySchemaVersion)
                ?? EvidenceSet.legacySchemaVersion
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(members, forKey: .members)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(ruleVersion, forKey: .ruleVersion)
        try container.encode(temporalBounds, forKey: .temporalBounds)
        try container.encode(orderingQuality, forKey: .orderingQuality)
        try container.encode(evidenceSetSchemaVersion, forKey: .evidenceSetSchemaVersion)
    }

    var memberObservationIDs: [UUID] {
        members.map(\.observationID)
    }

    var explanation: String {
        let rule = ruleID ?? "the approved grouping rule"
        if members.count == 1 {
            return "Evidence context: one observation matched \(rule)."
        }
        let reasons = members.flatMap(\.reasons).reduce(into: [String]()) { result, reason in
            let text: String
            switch reason {
            case let .temporalEligibility(seconds, basis):
                switch basis {
                case .continuousClock:
                    text = "within \(seconds) seconds by continuous clock"
                case .wallClockFallback:
                    text = "within \(seconds) seconds by wall-clock fallback"
                case .legacyUnspecified:
                    text = "within \(seconds) seconds with legacy timing basis unavailable"
                }
            case .sameSubject: text = "same qualified subject"
            case let .knownTopology(value): text = "known topology \(value)"
            case let .explicitScenarioRule(value): text = "matched grouping rule \(value)"
            }
            if !result.contains(text) {
                result.append(text)
            }
        }
        return "Evidence context: \(reasons.joined(separator: "; "))."
    }
}
