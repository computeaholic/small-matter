import Foundation

enum EvidenceTimestampQuality: String, Codable, Equatable, Sendable {
    case exact = "EXACT"
    case estimated = "ESTIMATED"
    case unavailable = "UNAVAILABLE"
    case unknown = "UNKNOWN"
}

enum EvidenceClockKind: String, Codable, Equatable, Sendable {
    case wall = "WALL"
    case continuous = "CONTINUOUS"
    case processUptime = "PROCESS_UPTIME"
}

enum EvidenceLifecycleBoundary: String, Codable, Equatable, Sendable {
    case none = "NONE"
    case processRestart = "PROCESS_RESTART"
    case sleepWake = "SLEEP_WAKE"
}

struct EvidenceOrderingDomain: Codable, Equatable, Hashable, Sendable {
    let sourceID: Horizon2SourceID
    let processRunID: UUID
    let clockDomainID: String
}

struct EvidenceSourceOccurrence: Codable, Equatable, Sendable {
    let wallTime: Date?
    let continuousNanoseconds: UInt64?
    let quality: EvidenceTimestampQuality
}

struct EvidenceTime: Codable, Equatable, Sendable {
    let observedWallTime: Date
    let continuousNanoseconds: UInt64?
    let processUptimeNanoseconds: UInt64?
    let processRunID: UUID
    let bootSessionID: String?
    let localSequence: UInt64
    let sourceTimestampQuality: EvidenceTimestampQuality
    let orderingDomain: EvidenceOrderingDomain
    let sourceOccurrence: EvidenceSourceOccurrence?
    let lifecycleBoundary: EvidenceLifecycleBoundary
    /// A runtime-owned generation that changes at sleep/wake boundaries. It is
    /// deliberately separate from source identity and local sequence.
    let correlationEpochID: UUID

    private enum CodingKeys: String, CodingKey {
        case observedWallTime
        case continuousNanoseconds
        case processUptimeNanoseconds
        case processRunID
        case bootSessionID
        case localSequence
        case sourceTimestampQuality
        case orderingDomain
        case sourceOccurrence
        case lifecycleBoundary
        case correlationEpochID
    }

    init(
        observedWallTime: Date,
        continuousNanoseconds: UInt64?,
        processUptimeNanoseconds: UInt64?,
        processRunID: UUID,
        bootSessionID: String?,
        localSequence: UInt64,
        sourceTimestampQuality: EvidenceTimestampQuality,
        orderingDomain: EvidenceOrderingDomain,
        sourceOccurrence: EvidenceSourceOccurrence?,
        lifecycleBoundary: EvidenceLifecycleBoundary = .none,
        correlationEpochID: UUID = EvidenceTime.zeroCorrelationEpoch
    ) {
        self.observedWallTime = observedWallTime
        self.continuousNanoseconds = continuousNanoseconds
        self.processUptimeNanoseconds = processUptimeNanoseconds
        self.processRunID = processRunID
        self.bootSessionID = bootSessionID
        self.localSequence = localSequence
        self.sourceTimestampQuality = sourceTimestampQuality
        self.orderingDomain = orderingDomain
        self.sourceOccurrence = sourceOccurrence
        self.lifecycleBoundary = lifecycleBoundary
        self.correlationEpochID = correlationEpochID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lifecycleBoundary = try container.decodeIfPresent(
            EvidenceLifecycleBoundary.self,
            forKey: .lifecycleBoundary
        ) ?? .none
        let correlationEpochID = try container.decodeIfPresent(
            UUID.self,
            forKey: .correlationEpochID
        ) ?? Self.zeroCorrelationEpoch
        try self.init(
            observedWallTime: container.decode(Date.self, forKey: .observedWallTime),
            continuousNanoseconds: container.decodeIfPresent(UInt64.self, forKey: .continuousNanoseconds),
            processUptimeNanoseconds: container.decodeIfPresent(UInt64.self, forKey: .processUptimeNanoseconds),
            processRunID: container.decode(UUID.self, forKey: .processRunID),
            bootSessionID: container.decodeIfPresent(String.self, forKey: .bootSessionID),
            localSequence: container.decode(UInt64.self, forKey: .localSequence),
            sourceTimestampQuality: container.decode(EvidenceTimestampQuality.self, forKey: .sourceTimestampQuality),
            orderingDomain: container.decode(EvidenceOrderingDomain.self, forKey: .orderingDomain),
            sourceOccurrence: container.decodeIfPresent(EvidenceSourceOccurrence.self, forKey: .sourceOccurrence),
            lifecycleBoundary: lifecycleBoundary,
            correlationEpochID: correlationEpochID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observedWallTime, forKey: .observedWallTime)
        try container.encodeIfPresent(continuousNanoseconds, forKey: .continuousNanoseconds)
        try container.encodeIfPresent(processUptimeNanoseconds, forKey: .processUptimeNanoseconds)
        try container.encode(processRunID, forKey: .processRunID)
        try container.encodeIfPresent(bootSessionID, forKey: .bootSessionID)
        try container.encode(localSequence, forKey: .localSequence)
        try container.encode(sourceTimestampQuality, forKey: .sourceTimestampQuality)
        try container.encode(orderingDomain, forKey: .orderingDomain)
        try container.encodeIfPresent(sourceOccurrence, forKey: .sourceOccurrence)
        try container.encode(lifecycleBoundary, forKey: .lifecycleBoundary)
        try container.encode(correlationEpochID, forKey: .correlationEpochID)
    }

    func compare(to other: EvidenceTime) -> EvidenceOrderResult {
        guard lifecycleBoundary == .none, other.lifecycleBoundary == .none else {
            return EvidenceOrderResult(relation: .incomparable, basis: .none)
        }

        guard correlationEpochID == other.correlationEpochID else {
            return EvidenceOrderResult(relation: .incomparable, basis: .none)
        }

        if orderingDomain == other.orderingDomain {
            if localSequence < other.localSequence {
                return EvidenceOrderResult(relation: .before, basis: .localSequence)
            }
            if localSequence > other.localSequence {
                return EvidenceOrderResult(relation: .after, basis: .localSequence)
            }
            return EvidenceOrderResult(relation: .equal, basis: .localSequence)
        }

        guard processRunID == other.processRunID,
              bootSessionID == other.bootSessionID,
              orderingDomain.clockDomainID == other.orderingDomain.clockDomainID,
              let continuousNanoseconds,
              let otherContinuousNanoseconds = other.continuousNanoseconds
        else {
            return EvidenceOrderResult(relation: .incomparable, basis: .none)
        }

        if continuousNanoseconds < otherContinuousNanoseconds {
            return EvidenceOrderResult(relation: .before, basis: .continuousClock)
        }
        if continuousNanoseconds > otherContinuousNanoseconds {
            return EvidenceOrderResult(relation: .after, basis: .continuousClock)
        }
        return EvidenceOrderResult(relation: .equal, basis: .continuousClock)
    }

    private static let zeroCorrelationEpoch = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

enum EvidenceOrderRelation: String, Codable, Equatable, Sendable {
    case before = "BEFORE"
    case equal = "EQUAL"
    case after = "AFTER"
    case incomparable = "INCOMPARABLE"
}

enum EvidenceOrderingBasis: String, Codable, Equatable, Sendable {
    case localSequence = "LOCAL_SEQUENCE"
    case continuousClock = "CONTINUOUS_CLOCK"
    case none = "NONE"
}

struct EvidenceOrderResult: Codable, Equatable, Sendable {
    let relation: EvidenceOrderRelation
    let basis: EvidenceOrderingBasis
}
