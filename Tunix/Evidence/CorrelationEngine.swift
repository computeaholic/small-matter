// swiftformat:disable trailingCommas
import Foundation

enum CorrelationEngineError: Error, Equatable, Sendable {
    case invalidIncidentStatus
    case missingObservation(UUID)
    case duplicateObservationConflict(UUID)
    case unlistedObservation(UUID)
    case invalidObservationSet(String)
}

struct CorrelationRuleDefinition: Equatable, Sendable {
    let id: String
    let version: String
}

enum InitialCorrelationRule {
    // 1.0.0 is retained only as the historical rule identity. Current
    // correlation after I6.1's temporal-basis hardening is 1.0.1.
    static let legacyVersion = "1.0.0"
    static let currentVersion = "1.0.1"
    static let storage = CorrelationRuleDefinition(id: "H2-CORR-STORAGE-LIFECYCLE", version: currentVersion)
    static let network = CorrelationRuleDefinition(id: "H2-CORR-NETWORK-PATH-TRANSITION", version: currentVersion)
}

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
struct CorrelationEngine: Sendable {
    func correlate(incident: IncidentPackage, observations: [Observation]) throws -> [EvidenceSet] {
        guard incident.status == .complete || incident.status == .incomplete else {
            throw CorrelationEngineError.invalidIncidentStatus
        }
        var unique: [UUID: Observation] = [:]
        for observation in observations {
            if let existing = unique[observation.id] {
                guard existing == observation else {
                    throw CorrelationEngineError.duplicateObservationConflict(observation.id)
                }
            } else {
                unique[observation.id] = observation
            }
        }
        let packageIDs = Set(incident.observationIDs)
        guard packageIDs.count == incident.observationIDs.count else {
            throw CorrelationEngineError.invalidObservationSet("Incident package contains duplicate observation IDs.")
        }
        for observationID in packageIDs where unique[observationID] == nil {
            throw CorrelationEngineError.missingObservation(observationID)
        }
        for observationID in unique.keys where !packageIDs.contains(observationID) {
            throw CorrelationEngineError.unlistedObservation(observationID)
        }

        let eligible = unique.values.filter { observation in
            guard case .available = observation.availability else { return false }
            guard observation.time.lifecycleBoundary == .none else { return false }
            return isCorrelationEligible(observation)
        }
        var sets = makeStorageSets(eligible.filter { $0.sourceID == .storage }, incidentID: incident.id)
        sets.append(contentsOf: makeNetworkSets(eligible.filter { $0.sourceID == .network }, incidentID: incident.id))
        return sets.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func isCorrelationEligible(_ observation: Observation) -> Bool {
        guard observation.sourceID == .storage,
              let role = IncidentChangeProjection.semanticRole(for: observation)
        else {
            return observation.sourceID != .storage
                || observation.eventKind == .storageDiskLifecycle
                || observation.eventKind == .storageMountLifecycle
        }
        return role == .transition
    }

    private func makeStorageSets(_ observations: [Observation], incidentID: UUID) -> [EvidenceSet] {
        let eligible = observations.filter {
            $0.eventKind == .storageDiskLifecycle || $0.eventKind == .storageMountLifecycle
        }
        var sets: [EvidenceSet] = []
        for group in Dictionary(grouping: eligible, by: storageKey) {
            let sorted = group.value.sorted(by: canonicalOrder)
            if group.key.identityDigest == nil || !isGroupable(group.key.quality) {
                sets.append(contentsOf: sorted.map {
                    singleton($0, rule: InitialCorrelationRule.storage, incidentID: incidentID)
                })
            } else {
                if let basis = temporalBasis(for: sorted) {
                    sets.append(contentsOf: cluster(
                        sorted,
                        rule: InitialCorrelationRule.storage,
                        includeSubjectReason: true,
                        basis: basis,
                        incidentID: incidentID
                    ))
                } else {
                    sets.append(contentsOf: sorted.map {
                        singleton($0, rule: InitialCorrelationRule.storage, incidentID: incidentID)
                    })
                }
            }
        }
        return sets
    }

    private func makeNetworkSets(_ observations: [Observation], incidentID: UUID) -> [EvidenceSet] {
        let eligible = observations.filter { $0.eventKind == .networkPathTransition }
        var sets: [EvidenceSet] = []
        for group in Dictionary(grouping: eligible, by: networkKey) {
            let sorted = group.value.sorted(by: canonicalOrder)
            if let basis = temporalBasis(for: sorted) {
                sets.append(contentsOf: cluster(
                    sorted,
                    rule: InitialCorrelationRule.network,
                    includeSubjectReason: false,
                    basis: basis,
                    incidentID: incidentID
                ))
            } else {
                sets.append(contentsOf: sorted.map {
                    singleton($0, rule: InitialCorrelationRule.network, incidentID: incidentID)
                })
            }
        }
        return sets
    }

    private func cluster(
        _ observations: [Observation],
        rule: CorrelationRuleDefinition,
        includeSubjectReason: Bool,
        basis: EvidenceTemporalBasis,
        incidentID: UUID
    ) -> [EvidenceSet] {
        guard !observations.isEmpty else { return [] }
        var result: [EvidenceSet] = []
        var current: [Observation] = []
        var minimumContinuous: UInt64?
        var maximumContinuous: UInt64?
        var minimumWall: Date?
        var maximumWall: Date?
        for observation in observations {
            let canAppend = current.isEmpty || spanIncluding(
                observation,
                basis: basis,
                minimumContinuous: minimumContinuous,
                maximumContinuous: maximumContinuous,
                minimumWall: minimumWall,
                maximumWall: maximumWall
            )
            if !canAppend, !current.isEmpty {
                result.append(makeSet(
                    current,
                    rule: rule,
                    includeSubjectReason: includeSubjectReason,
                    basis: basis,
                    incidentID: incidentID
                ))
                current = []
                minimumContinuous = nil
                maximumContinuous = nil
                minimumWall = nil
                maximumWall = nil
            }
            current.append(observation)
            updateSpan(
                with: observation,
                basis: basis,
                minimumContinuous: &minimumContinuous,
                maximumContinuous: &maximumContinuous,
                minimumWall: &minimumWall,
                maximumWall: &maximumWall
            )
        }
        if !current.isEmpty {
            result.append(makeSet(
                current,
                rule: rule,
                includeSubjectReason: includeSubjectReason,
                basis: basis,
                incidentID: incidentID
            ))
        }
        return result
    }

    private func makeSet(
        _ observations: [Observation],
        rule: CorrelationRuleDefinition,
        includeSubjectReason: Bool,
        basis: EvidenceTemporalBasis?,
        incidentID: UUID
    ) -> EvidenceSet {
        let ordered = observations.sorted(by: canonicalOrder)
        let reasons: [EvidenceMembershipReason] = {
            if ordered.count == 1 {
                return [.explicitScenarioRule(rule.id)]
            }
            var values: [EvidenceMembershipReason] = [
                .explicitScenarioRule(rule.id),
                .temporalEligibility(
                    seconds: Horizon2EvidenceConfiguration.temporalEligibilitySeconds,
                    basis: basis ?? .legacyUnspecified
                )
            ]
            if includeSubjectReason {
                values.append(.sameSubject)
            }
            return values.sorted { $0.canonicalValue < $1.canonicalValue }
        }()
        let members = ordered.map { EvidenceMembership(observationID: $0.id, reasons: reasons) }
        let idMaterial = [incidentID.uuidString, rule.id, rule.version] + ordered.map { $0.id.uuidString }
        let id = EvidenceIdentityDigest.makeUUID(scope: "horizon2-evidence-set", material: idMaterial)!
        return EvidenceSet(
            id: id,
            members: members,
            ruleID: rule.id,
            ruleVersion: rule.version,
            temporalBounds: EvidenceTimeBounds(
                start: ordered.first!.time.observedWallTime,
                end: ordered.last!.time.observedWallTime
            ),
            orderingQuality: .totalWithinDomain,
            evidenceSetSchemaVersion: EvidenceSet.currentSchemaVersion
        )
    }

    private func singleton(
        _ observation: Observation,
        rule: CorrelationRuleDefinition,
        incidentID: UUID
    ) -> EvidenceSet {
        makeSet(
            [observation],
            rule: rule,
            includeSubjectReason: false,
            basis: nil,
            incidentID: incidentID
        )
    }

    private struct StorageKey: Hashable {
        let type: EvidenceSubjectType
        let identityDigest: String?
        let quality: EvidenceIdentityQuality
        let processRunID: UUID
        let correlationEpochID: UUID
        let orderingDomain: EvidenceOrderingDomain
    }

    private struct NetworkKey: Hashable {
        let processRunID: UUID
        let correlationEpochID: UUID
        let orderingDomain: EvidenceOrderingDomain
    }

    private func storageKey(_ observation: Observation) -> StorageKey {
        StorageKey(
            type: observation.subject.type,
            identityDigest: observation.subject.identityDigest,
            quality: observation.subject.quality,
            processRunID: observation.time.processRunID,
            correlationEpochID: observation.time.correlationEpochID,
            orderingDomain: observation.time.orderingDomain
        )
    }

    private func networkKey(_ observation: Observation) -> NetworkKey {
        NetworkKey(
            processRunID: observation.time.processRunID,
            correlationEpochID: observation.time.correlationEpochID,
            orderingDomain: observation.time.orderingDomain
        )
    }

    private func isGroupable(_ quality: EvidenceIdentityQuality) -> Bool {
        quality == .provenStable || quality == .qualified || quality == .transientRunLocal
    }

    private func temporalBasis(for observations: [Observation]) -> EvidenceTemporalBasis? {
        guard observations.allSatisfy({ isComparableTimestampQuality($0.time.sourceTimestampQuality) }) else {
            return nil
        }
        if observations.allSatisfy({ $0.time.continuousNanoseconds != nil }) {
            return .continuousClock
        }
        return .wallClockFallback
    }

    private func isComparableTimestampQuality(_ quality: EvidenceTimestampQuality) -> Bool {
        quality == .exact || quality == .estimated
    }

    private func temporalBoundNanoseconds() -> UInt64 {
        UInt64(Horizon2EvidenceConfiguration.temporalEligibilitySeconds) * 1_000_000_000
    }

    // Why: complete canonical inputs.
    // Why: complete canonical inputs.
    // swiftlint:disable:next function_parameter_count
    private func spanIncluding(
        _ observation: Observation,
        basis: EvidenceTemporalBasis,
        minimumContinuous: UInt64?,
        maximumContinuous: UInt64?,
        minimumWall: Date?,
        maximumWall: Date?
    ) -> Bool {
        switch basis {
        case .continuousClock:
            guard let candidate = observation.time.continuousNanoseconds,
                  let minimumContinuous,
                  let maximumContinuous
            else { return false }
            let newMinimum = min(minimumContinuous, candidate)
            let newMaximum = max(maximumContinuous, candidate)
            guard newMaximum >= newMinimum else { return false }
            return newMaximum - newMinimum <= temporalBoundNanoseconds()
        case .wallClockFallback:
            guard isComparableTimestampQuality(observation.time.sourceTimestampQuality),
                  let minimumWall,
                  let maximumWall
            else { return false }
            let newMinimum = min(minimumWall, observation.time.observedWallTime)
            let newMaximum = max(maximumWall, observation.time.observedWallTime)
            let span = newMaximum.timeIntervalSince(newMinimum)
            return span.isFinite && span >= 0
                && span <= Double(Horizon2EvidenceConfiguration.temporalEligibilitySeconds)
        case .legacyUnspecified:
            return false
        }
    }

    // Why: complete canonical inputs.
    // Why: complete canonical inputs.
    // swiftlint:disable:next function_parameter_count
    private func updateSpan(
        with observation: Observation,
        basis: EvidenceTemporalBasis,
        minimumContinuous: inout UInt64?,
        maximumContinuous: inout UInt64?,
        minimumWall: inout Date?,
        maximumWall: inout Date?
    ) {
        switch basis {
        case .continuousClock:
            guard let coordinate = observation.time.continuousNanoseconds else { return }
            minimumContinuous = min(minimumContinuous ?? coordinate, coordinate)
            maximumContinuous = max(maximumContinuous ?? coordinate, coordinate)
        case .wallClockFallback:
            minimumWall = min(minimumWall ?? observation.time.observedWallTime, observation.time.observedWallTime)
            maximumWall = max(maximumWall ?? observation.time.observedWallTime, observation.time.observedWallTime)
        case .legacyUnspecified:
            break
        }
    }

    private func canonicalOrder(_ lhs: Observation, _ rhs: Observation) -> Bool {
        if lhs.time.observedWallTime != rhs.time.observedWallTime {
            return lhs.time.observedWallTime < rhs.time.observedWallTime
        }
        if lhs.time.localSequence != rhs.time.localSequence {
            return lhs.time.localSequence < rhs.time.localSequence
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct IncidentCorrelationService: Sendable {
    let journal: any EvidenceJournal
    let engine = CorrelationEngine()

    func process(incidentID: UUID) async throws -> [EvidenceSet] {
        guard let incident = await journal.incident(id: incidentID) else { throw EvidenceJournalError.invalidIncident }
        let observations = await withTaskGroup(of: Observation?.self, returning: [Observation].self) { group in
            for observationID in incident.observationIDs {
                group.addTask { await journal.observation(id: observationID) }
            }
            var found: [Observation] = []
            for await observation in group {
                if let observation {
                    found.append(observation)
                }
            }
            return found
        }
        let sets = try engine.correlate(incident: incident, observations: observations)
        try await journal.persistEvidenceSets(incidentID: incidentID, sets: sets)
        return sets
    }
}
