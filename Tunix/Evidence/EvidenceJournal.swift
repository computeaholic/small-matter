import Foundation

enum EvidenceJournalAvailability: String, Codable, Equatable, Sendable {
    case available = "AVAILABLE"
    case unavailable = "UNAVAILABLE"
    case capacityUnavailable = "CAPACITY_UNAVAILABLE"
}

enum EvidenceJournalError: Error, Equatable, Sendable {
    case duplicateObservationID
    case observationPayloadMismatch
    case unavailable
    case capacityUnavailable
    case invalidSensitivity(String)
    case incompatibleSchema
    case schemaMetadataMismatch
    case corruption
    case busy
    case oversizedRecord
    case invalidIncident
    case resetFailed
    case evidenceSetConflict(UUID)
    case invalidCorrelationInput(String)
    case inferenceConflict(UUID)
    case invalidInferenceInput(String)
}

struct EvidenceJournalQuery: Codable, Equatable, Sendable {
    let start: Date?
    let end: Date?
    let sourceID: Horizon2SourceID?
    let subjectIdentityDigest: String?
    let limit: Int?
    let newestFirst: Bool

    init(
        start: Date? = nil,
        end: Date? = nil,
        sourceID: Horizon2SourceID? = nil,
        subjectIdentityDigest: String? = nil,
        limit: Int? = nil,
        newestFirst: Bool = false
    ) {
        self.start = start
        self.end = end
        self.sourceID = sourceID
        self.subjectIdentityDigest = subjectIdentityDigest
        self.limit = limit.map { max(1, $0) }
        self.newestFirst = newestFirst
    }
}

struct EvidenceSourceHealthRecord: Codable, Equatable, Sendable {
    let id: UUID
    let sourceID: Horizon2SourceID
    let observationID: UUID?
    let event: EvidenceSourceHealthEvent
    let reason: EvidenceUnknownReason
    let suppressedCount: Int
    let observedAt: Date
    let detail: String?

    init(
        id: UUID,
        sourceID: Horizon2SourceID,
        observationID: UUID? = nil,
        event: EvidenceSourceHealthEvent = .sourceUnavailable,
        reason: EvidenceUnknownReason,
        suppressedCount: Int = 0,
        observedAt: Date,
        detail: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.observationID = observationID
        self.event = event
        self.reason = reason
        self.suppressedCount = suppressedCount
        self.observedAt = observedAt
        self.detail = detail
    }
}

struct EvidenceRetentionStatus: Codable, Equatable, Sendable {
    let availability: EvidenceJournalAvailability
    let bytes: Int
    let protectedIncidentCount: Int
}

protocol EvidenceJournal: Sendable {
    func append(_ observation: Observation) async throws
    func appendBatch(_ observations: [Observation]) async throws
    func observation(id: UUID) async -> Observation?
    func query(_ query: EvidenceJournalQuery) async -> [Observation]
    func recordSourceHealth(_ record: EvidenceSourceHealthRecord) async throws
    func sourceHealth() async -> [EvidenceSourceHealthRecord]
    func beginIncidentCapture(_ session: IncidentCaptureSession) async throws
    func activeIncidentCaptures() async -> [IncidentCaptureSession]
    func finalizeIncidentCapture(_ package: IncidentPackage) async throws
    func incident(id: UUID) async -> IncidentPackage?
    func incidentSummaries(limit: Int) async -> [IncidentPackage]
    func deleteIncident(id: UUID) async throws
    func recordIncidentMembership(incidentID: UUID, observationIDs: [UUID]) async throws
    func incidentObservationIDs(incidentID: UUID) async -> [UUID]
    func persistEvidenceSets(incidentID: UUID, sets: [EvidenceSet]) async throws
    func evidenceSets(incidentID: UUID) async -> [EvidenceSet]
    func persistInferences(
        incidentID: UUID,
        inferences: [Inference],
        catalogEntries: [NextTestCatalogEntry]
    ) async throws
    func inferences(incidentID: UUID, currentOnly: Bool) async -> [Inference]
    func inference(id: UUID) async -> Inference?
    func nextTestSnapshots(inferenceID: UUID) async -> [NextTestCatalogEntry]
    func retentionStatus() async -> EvidenceRetentionStatus
    func clearUnprotectedHistory() async throws -> EvidenceDeletionResult
}

extension EvidenceJournal {
    func appendBatch(_ observations: [Observation]) async throws {
        for observation in observations {
            try await append(observation)
        }
    }

    func sourceHealth(in interval: DateInterval) async -> [EvidenceSourceHealthRecord] {
        await sourceHealth().filter { interval.contains($0.observedAt) }
    }
}

struct EvidenceDeletionResult: Codable, Equatable, Sendable {
    let observationsDeleted: Int
    let incidentsDeleted: Int
    let healthRecordsDeleted: Int
    let finalStatus: EvidenceRetentionStatus
}

/// The production journal can be unavailable without pretending that an
/// in-memory substitute is durable. It is intentionally a small fail-closed
/// implementation so the rest of V1 can remain usable while Horizon 2
/// exposes an explicit unavailable status.
actor UnavailableEvidenceJournal: EvidenceJournal {
    private let failure: EvidenceJournalError

    init(failure: EvidenceJournalError) {
        self.failure = failure
    }

    func append(_: Observation) throws {
        throw failure
    }

    func observation(id _: UUID) -> Observation? {
        nil
    }

    func query(_: EvidenceJournalQuery) -> [Observation] {
        []
    }

    func recordSourceHealth(_: EvidenceSourceHealthRecord) throws {
        throw failure
    }

    func sourceHealth() -> [EvidenceSourceHealthRecord] {
        []
    }

    func beginIncidentCapture(_: IncidentCaptureSession) throws {
        throw failure
    }

    func activeIncidentCaptures() -> [IncidentCaptureSession] {
        []
    }

    func finalizeIncidentCapture(_: IncidentPackage) throws {
        throw failure
    }

    func incident(id _: UUID) -> IncidentPackage? {
        nil
    }

    func incidentSummaries(limit _: Int) -> [IncidentPackage] {
        []
    }

    func deleteIncident(id _: UUID) throws {
        throw failure
    }

    func recordIncidentMembership(incidentID _: UUID, observationIDs _: [UUID]) throws {
        throw failure
    }

    func incidentObservationIDs(incidentID _: UUID) -> [UUID] {
        []
    }

    func persistEvidenceSets(incidentID _: UUID, sets _: [EvidenceSet]) throws {
        throw failure
    }

    func evidenceSets(incidentID _: UUID) -> [EvidenceSet] {
        []
    }

    func persistInferences(
        incidentID _: UUID,
        inferences _: [Inference],
        catalogEntries _: [NextTestCatalogEntry]
    ) throws {
        throw failure
    }

    func inferences(incidentID _: UUID, currentOnly _: Bool) -> [Inference] {
        []
    }

    func inference(id _: UUID) -> Inference? {
        nil
    }

    func nextTestSnapshots(inferenceID _: UUID) -> [NextTestCatalogEntry] {
        []
    }

    func retentionStatus() -> EvidenceRetentionStatus {
        EvidenceRetentionStatus(
            availability: failure == .capacityUnavailable ? .capacityUnavailable : .unavailable,
            bytes: 0,
            protectedIncidentCount: 0
        )
    }

    func clearUnprotectedHistory() throws -> EvidenceDeletionResult {
        throw failure
    }
}

/// Holds native collectors behind a durable-journal resolution barrier. The
/// wrapper is unavailable until production bootstrap resolves it, so no
/// caller can mistake pre-bootstrap writes for durable evidence.
actor DeferredEvidenceJournal: EvidenceJournal {
    private var resolved: (any EvidenceJournal)?
    private let bootstrapFailure: EvidenceJournalError

    init(bootstrapFailure: EvidenceJournalError = .unavailable) {
        self.bootstrapFailure = bootstrapFailure
    }

    func resolve(_ journal: any EvidenceJournal) {
        resolved = journal
    }

    func isResolved() -> Bool {
        resolved != nil
    }

    func append(_ observation: Observation) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.append(observation)
    }

    func appendBatch(_ observations: [Observation]) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.appendBatch(observations)
    }

    func observation(id: UUID) async -> Observation? {
        guard let resolved else { return nil }
        return await resolved.observation(id: id)
    }

    func query(_ query: EvidenceJournalQuery) async -> [Observation] {
        guard let resolved else { return [] }
        return await resolved.query(query)
    }

    func recordSourceHealth(_ record: EvidenceSourceHealthRecord) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.recordSourceHealth(record)
    }

    func sourceHealth() async -> [EvidenceSourceHealthRecord] {
        guard let resolved else { return [] }
        return await resolved.sourceHealth()
    }

    func beginIncidentCapture(_ session: IncidentCaptureSession) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.beginIncidentCapture(session)
    }

    func activeIncidentCaptures() async -> [IncidentCaptureSession] {
        guard let resolved else { return [] }
        return await resolved.activeIncidentCaptures()
    }

    func finalizeIncidentCapture(_ package: IncidentPackage) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.finalizeIncidentCapture(package)
    }

    func incident(id: UUID) async -> IncidentPackage? {
        guard let resolved else { return nil }
        return await resolved.incident(id: id)
    }

    func incidentSummaries(limit: Int) async -> [IncidentPackage] {
        guard let resolved else { return [] }
        return await resolved.incidentSummaries(limit: limit)
    }

    func deleteIncident(id: UUID) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.deleteIncident(id: id)
    }

    func recordIncidentMembership(incidentID: UUID, observationIDs: [UUID]) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.recordIncidentMembership(incidentID: incidentID, observationIDs: observationIDs)
    }

    func incidentObservationIDs(incidentID: UUID) async -> [UUID] {
        guard let resolved else { return [] }
        return await resolved.incidentObservationIDs(incidentID: incidentID)
    }

    func persistEvidenceSets(incidentID: UUID, sets: [EvidenceSet]) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.persistEvidenceSets(incidentID: incidentID, sets: sets)
    }

    func evidenceSets(incidentID: UUID) async -> [EvidenceSet] {
        guard let resolved else { return [] }
        return await resolved.evidenceSets(incidentID: incidentID)
    }

    func persistInferences(
        incidentID: UUID,
        inferences: [Inference],
        catalogEntries: [NextTestCatalogEntry]
    ) async throws {
        guard let resolved else { throw bootstrapFailure }
        try await resolved.persistInferences(
            incidentID: incidentID,
            inferences: inferences,
            catalogEntries: catalogEntries
        )
    }

    func inferences(incidentID: UUID, currentOnly: Bool) async -> [Inference] {
        guard let resolved else { return [] }
        return await resolved.inferences(incidentID: incidentID, currentOnly: currentOnly)
    }

    func inference(id: UUID) async -> Inference? {
        guard let resolved else { return nil }
        return await resolved.inference(id: id)
    }

    func nextTestSnapshots(inferenceID: UUID) async -> [NextTestCatalogEntry] {
        guard let resolved else { return [] }
        return await resolved.nextTestSnapshots(inferenceID: inferenceID)
    }

    func retentionStatus() async -> EvidenceRetentionStatus {
        guard let resolved else {
            return EvidenceRetentionStatus(availability: .unavailable, bytes: 0, protectedIncidentCount: 0)
        }
        return await resolved.retentionStatus()
    }

    func clearUnprotectedHistory() async throws -> EvidenceDeletionResult {
        guard let resolved else { throw bootstrapFailure }
        return try await resolved.clearUnprotectedHistory()
    }
}

// swiftlint:disable:next type_body_length
actor InMemoryEvidenceJournal: EvidenceJournal {
    private var observations: [UUID: Observation] = [:]
    private var encodedObservationBytes: [UUID: Int] = [:]
    private var healthRecords: [UUID: EvidenceSourceHealthRecord] = [:]
    private var incidentMembership: [UUID: Set<UUID>] = [:]
    private var activeSessions: [UUID: IncidentCaptureSession] = [:]
    private var incidents: [UUID: IncidentPackage] = [:]
    private var evidenceSetsByIncident: [UUID: [UUID: EvidenceSet]] = [:]
    private var inferencesByIncident: [UUID: [UUID: Inference]] = [:]
    private var inferenceSnapshotsByID: [UUID: [NextTestCatalogEntry]] = [:]
    private var journalAvailability: EvidenceJournalAvailability

    init(
        observations: [Observation] = [],
        healthRecords: [EvidenceSourceHealthRecord] = [],
        incidents: [IncidentPackage] = [],
        availability: EvidenceJournalAvailability = .available
    ) {
        journalAvailability = availability
        for observation in observations {
            self.observations[observation.id] = observation
            encodedObservationBytes[observation.id] = (try? observation.deterministicData().count) ?? 0
        }
        for record in healthRecords {
            self.healthRecords[record.id] = record
        }
        for incident in incidents {
            self.incidents[incident.id] = incident
            incidentMembership[incident.id] = Set(incident.observationIDs)
        }
    }

    func append(_ observation: Observation) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        if let existing = observations[observation.id] {
            guard existing == observation else { throw EvidenceJournalError.observationPayloadMismatch }
            return
        }
        let encodedBytes = try observation.deterministicData().count
        observations[observation.id] = observation
        encodedObservationBytes[observation.id] = encodedBytes
    }

    func appendBatch(_ observations: [Observation]) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        var encoded: [(Observation, Int)] = []
        for observation in observations {
            let bytes = try observation.deterministicData().count
            if let existing = self.observations[observation.id] {
                guard existing == observation else { throw EvidenceJournalError.observationPayloadMismatch }
            } else {
                encoded.append((observation, bytes))
            }
        }
        for (observation, bytes) in encoded {
            self.observations[observation.id] = observation
            encodedObservationBytes[observation.id] = bytes
        }
    }

    func observation(id: UUID) -> Observation? {
        observations[id]
    }

    func query(_ query: EvidenceJournalQuery) -> [Observation] {
        let sorted = observations.values
            .filter { observation in
                if let start = query.start, observation.time.observedWallTime < start {
                    return false
                }
                if let end = query.end, observation.time.observedWallTime > end {
                    return false
                }
                if let sourceID = query.sourceID, observation.sourceID != sourceID {
                    return false
                }
                if let digest = query.subjectIdentityDigest, observation.subject.identityDigest != digest {
                    return false
                }
                return true
            }
            .sorted {
                if $0.time.observedWallTime != $1.time.observedWallTime {
                    return query.newestFirst
                        ? $0.time.observedWallTime > $1.time.observedWallTime
                        : $0.time.observedWallTime < $1.time.observedWallTime
                }
                if $0.time.localSequence != $1.time.localSequence {
                    return query.newestFirst
                        ? $0.time.localSequence > $1.time.localSequence
                        : $0.time.localSequence < $1.time.localSequence
                }
                return query.newestFirst
                    ? $0.id.uuidString > $1.id.uuidString
                    : $0.id.uuidString < $1.id.uuidString
            }
        if let limit = query.limit {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    func recordSourceHealth(_ record: EvidenceSourceHealthRecord) throws {
        healthRecords[record.id] = record
    }

    func sourceHealth() -> [EvidenceSourceHealthRecord] {
        healthRecords.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func beginIncidentCapture(_ session: IncidentCaptureSession) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        guard activeSessions.isEmpty else { throw EvidenceJournalError.invalidIncident }
        activeSessions[session.id] = session
        incidentMembership[session.id] = Set(session.observationIDs)
    }

    func activeIncidentCaptures() -> [IncidentCaptureSession] {
        activeSessions.values.sorted {
            if $0.marker.wallTime != $1.marker.wallTime {
                return $0.marker.wallTime < $1.marker.wallTime
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func finalizeIncidentCapture(_ package: IncidentPackage) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        activeSessions.removeValue(forKey: package.id)
        incidents[package.id] = package
        incidentMembership[package.id] = Set(package.observationIDs)
    }

    func incident(id: UUID) -> IncidentPackage? {
        incidents[id]
    }

    func incidentSummaries(limit: Int) -> [IncidentPackage] {
        incidents.values
            .sorted {
                if $0.marker.wallTime != $1.marker.wallTime {
                    return $0.marker.wallTime > $1.marker.wallTime
                }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    func deleteIncident(id: UUID) throws {
        incidents.removeValue(forKey: id)
        activeSessions.removeValue(forKey: id)
        incidentMembership.removeValue(forKey: id)
        evidenceSetsByIncident.removeValue(forKey: id)
        let inferenceIDs = Array(inferencesByIncident.removeValue(forKey: id)?.keys ?? [UUID: Inference]().keys)
        inferenceIDs.forEach { inferenceSnapshotsByID.removeValue(forKey: $0) }
    }

    func persistEvidenceSets(incidentID: UUID, sets: [EvidenceSet]) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        guard let incident = incidents[incidentID],
              incident.status == .complete || incident.status == .incomplete
        else {
            throw EvidenceJournalError.invalidIncident
        }
        let incidentObservationIDs = Set(incident.observationIDs)
        for set in sets {
            guard set.memberObservationIDs.allSatisfy(incidentObservationIDs.contains) else {
                throw EvidenceJournalError.invalidCorrelationInput(
                    "Evidence set references an observation outside its incident package."
                )
            }
            if let existing = evidenceSetsByIncident[incidentID]?[set.id] {
                guard existing == set else { throw EvidenceJournalError.evidenceSetConflict(set.id) }
            }
        }
        for set in sets {
            evidenceSetsByIncident[incidentID, default: [:]][set.id] = set
        }
    }

    func evidenceSets(incidentID: UUID) -> [EvidenceSet] {
        evidenceSetsByIncident[incidentID, default: [:]].values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func persistInferences(
        incidentID: UUID,
        inferences: [Inference],
        catalogEntries: [NextTestCatalogEntry]
    ) throws {
        guard journalAvailability == .available else {
            throw journalAvailability == .capacityUnavailable
                ? EvidenceJournalError.capacityUnavailable
                : EvidenceJournalError.unavailable
        }
        guard let incident = incidents[incidentID],
              incident.status == .complete || incident.status == .incomplete
        else {
            throw EvidenceJournalError.invalidIncident
        }
        let sets = evidenceSetsByIncident[incidentID, default: [:]]
        var entriesByReference: [String: NextTestCatalogEntry] = [:]
        for entry in catalogEntries {
            let key = "\(entry.reference.testID)|\(entry.reference.catalogVersion)"
            guard entriesByReference[key] == nil else {
                throw EvidenceJournalError.invalidInferenceInput("NextTest catalog contains duplicate references.")
            }
            entriesByReference[key] = entry
        }
        for inference in inferences {
            guard let set = sets[inference.evidenceSetID] else {
                throw EvidenceJournalError.invalidInferenceInput("Inference references a missing EvidenceSet.")
            }
            let memberIDs = Set(set.memberObservationIDs)
            guard inference.referencesOnly(memberIDs) else {
                throw EvidenceJournalError.invalidInferenceInput(
                    "Inference references an Observation outside its EvidenceSet."
                )
            }
            let snapshots = try inference.nextTests.map { reference -> NextTestCatalogEntry in
                guard let entry = entriesByReference["\(reference.testID)|\(reference.catalogVersion)"],
                      (try? entry.validatedReference()) == reference
                else {
                    throw EvidenceJournalError.invalidInferenceInput(
                        "Inference references an invalid NextTest catalog entry."
                    )
                }
                return entry
            }
            if let existing = inferencesByIncident[incidentID]?[inference.id] {
                guard existing == inference,
                      inferenceSnapshotsByID[inference.id] == snapshots
                else { throw EvidenceJournalError.inferenceConflict(inference.id) }
            } else {
                inferencesByIncident[incidentID, default: [:]][inference.id] = inference
                inferenceSnapshotsByID[inference.id] = snapshots
            }
        }
    }

    func inferences(incidentID: UUID, currentOnly: Bool) -> [Inference] {
        let values = inferencesByIncident[incidentID, default: [:]].values
        return values
            .filter {
                guard currentOnly else { return true }
                return InferenceVersionPolicy.isCurrent(
                    inference: $0,
                    evidenceSet: evidenceSetsByIncident[incidentID]?[$0.evidenceSetID]
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func inference(id: UUID) -> Inference? {
        inferencesByIncident.values.compactMap { $0[id] }.first
    }

    func nextTestSnapshots(inferenceID: UUID) -> [NextTestCatalogEntry] {
        inferenceSnapshotsByID[inferenceID] ?? []
    }

    func recordIncidentMembership(incidentID: UUID, observationIDs: [UUID]) throws {
        incidentMembership[incidentID, default: []].formUnion(observationIDs)
    }

    func incidentObservationIDs(incidentID: UUID) -> [UUID] {
        (incidentMembership[incidentID] ?? []).sorted { $0.uuidString < $1.uuidString }
    }

    func retentionStatus() -> EvidenceRetentionStatus {
        EvidenceRetentionStatus(
            availability: journalAvailability,
            bytes: encodedObservationBytes.values.reduce(0, +),
            protectedIncidentCount: 0
        )
    }

    func clearUnprotectedHistory() throws -> EvidenceDeletionResult {
        guard journalAvailability != .unavailable else { throw EvidenceJournalError.unavailable }

        let protectedObservationIDs = Set(incidentMembership.values.flatMap { $0 })
            .union(evidenceSetsByIncident.values.flatMap { sets in
                sets.values.flatMap(\.memberObservationIDs)
            })
            .union(inferencesByIncident.values.flatMap { inferences in
                inferences.values.flatMap { inference in
                    inference.supportingObservationIDs + inference.contradictingObservationIDs
                }
            })
        let deletableIDs = observations.keys.filter { !protectedObservationIDs.contains($0) }
        for deletableID in deletableIDs {
            observations.removeValue(forKey: deletableID)
            encodedObservationBytes.removeValue(forKey: deletableID)
        }
        journalAvailability = .available
        return EvidenceDeletionResult(
            observationsDeleted: deletableIDs.count,
            incidentsDeleted: 0,
            healthRecordsDeleted: 0,
            finalStatus: retentionStatus()
        )
    }
} // swiftlint:disable:this file_length
