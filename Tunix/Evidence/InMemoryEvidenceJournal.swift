import Foundation

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
}
