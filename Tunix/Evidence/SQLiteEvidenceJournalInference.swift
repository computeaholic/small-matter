import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    // Why: explicit fail-closed matrix.
    // Why: ordered canonical flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func persistInferences(
        incidentID: UUID,
        inferences: [Inference],
        catalogEntries: [NextTestCatalogEntry]
    ) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        guard let incident = incident(id: incidentID),
              incident.status == .complete || incident.status == .incomplete
        else {
            throw EvidenceJournalError.invalidIncident
        }
        var catalog: [String: NextTestCatalogEntry] = [:]
        for entry in catalogEntries {
            let key = "\(entry.reference.testID)|\(entry.reference.catalogVersion)"
            guard catalog[key] == nil else {
                throw EvidenceJournalError.invalidInferenceInput("NextTest catalog contains duplicate references.")
            }
            catalog[key] = entry
        }
        let persistedSets = Dictionary(uniqueKeysWithValues: evidenceSets(incidentID: incidentID).map { ($0.id, $0) })

        // Validate the complete batch before opening the transaction. This
        // keeps an invalid NextTest or cross-set reference from partially
        // persisting a derived result.
        for inference in inferences {
            guard let set = persistedSets[inference.evidenceSetID],
                  try evidenceSetIncidentID(id: inference.evidenceSetID) == incidentID,
                  inference.referencesOnly(Set(set.memberObservationIDs))
            else {
                throw EvidenceJournalError
                    .invalidInferenceInput("Inference references an invalid EvidenceSet or Observation.")
            }
            for reference in inference.nextTests {
                guard let entry = catalog["\(reference.testID)|\(reference.catalogVersion)"],
                      (try? entry.validatedReference()) == reference
                else {
                    throw EvidenceJournalError
                        .invalidInferenceInput("Inference references an invalid NextTest catalog entry.")
                }
            }
            if let existing = try loadInference(id: inference.id) {
                let existingSnapshots = try loadNextTestSnapshots(inferenceID: inference.id)
                let expectedSnapshots = inference.nextTests.compactMap { reference in
                    catalog["\(reference.testID)|\(reference.catalogVersion)"]
                }
                guard existing == inference, existingSnapshots == expectedSnapshots else {
                    throw EvidenceJournalError.inferenceConflict(inference.id)
                }
            }
        }

        let encodedInferences = try inferences.reduce(into: 0) { total, inference in
            total += try JSONEncoder.horizon2.encode(inference).count
        }
        try ensureCapacity(for: encodedInferences + catalogEntries.count * 512 + 16384)

        try connection.exec("BEGIN IMMEDIATE")
        do {
            for inference in inferences {
                if try loadInference(id: inference.id) != nil {
                    continue
                }
                let insert = try connection
                    .prepare(
                        "INSERT INTO inferences(" +
                            "inference_id, evidence_set_id, rule_id, rule_version, evidence_class, " +
                            "output_json, created_at_wall) VALUES(?,?,?,?,?,?,?)"
                    )
                defer { sqlite3_finalize(insert) }
                bind(inference.id.uuidString, at: 1, to: insert)
                bind(inference.evidenceSetID.uuidString, at: 2, to: insert)
                bind(inference.ruleID, at: 3, to: insert)
                bind(inference.ruleVersion, at: 4, to: insert)
                bind(inference.evidenceClass.rawValue, at: 5, to: insert)
                let output = try String(bytes: JSONEncoder.horizon2.encode(inference), encoding: .utf8) ?? ""
                bind(output, at: 6, to: insert)
                bind(Self.dateString(inference.generatedAt), at: 7, to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE
                else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }

                for observationID in inference.supportingObservationIDs {
                    let support = try connection
                        .prepare(
                            "INSERT INTO inference_support(inference_id,observation_id,support_kind) VALUES(?,?,?)"
                        )
                    defer { sqlite3_finalize(support) }
                    bind(inference.id.uuidString, at: 1, to: support)
                    bind(observationID.uuidString, at: 2, to: support)
                    bind("SUPPORT", at: 3, to: support)
                    guard sqlite3_step(support) == SQLITE_DONE
                    else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
                }
                for observationID in inference.contradictingObservationIDs {
                    let contradiction = try connection
                        .prepare(
                            "INSERT INTO inference_contradictions(" +
                                "inference_id, observation_id, contradiction_kind, details_json) VALUES(?,?,?,?)"
                        )
                    defer { sqlite3_finalize(contradiction) }
                    bind(inference.id.uuidString, at: 1, to: contradiction)
                    bind(observationID.uuidString, at: 2, to: contradiction)
                    bind("RULE_CONTRADICTION", at: 3, to: contradiction)
                    bind("{}", at: 4, to: contradiction)
                    guard sqlite3_step(contradiction) == SQLITE_DONE
                    else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
                }
                for reference in inference.nextTests {
                    guard let entry = catalog["\(reference.testID)|\(reference.catalogVersion)"] else {
                        throw EvidenceJournalError.invalidInferenceInput("Missing NextTest snapshot.")
                    }
                    let nextTest = try connection
                        .prepare(
                            "INSERT INTO next_test_references(" +
                                "inference_id, catalog_id, catalog_version, purpose, evidence_expected, " +
                                "prerequisites_json, risk_class, user_action, stopping_condition, " +
                                "expected_observations, safety_warning, catalog_provenance) " +
                                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)"
                        )
                    defer { sqlite3_finalize(nextTest) }
                    bind(inference.id.uuidString, at: 1, to: nextTest)
                    bind(entry.reference.testID, at: 2, to: nextTest)
                    bind(entry.reference.catalogVersion, at: 3, to: nextTest)
                    bind(entry.reference.purpose, at: 4, to: nextTest)
                    bind(entry.reference.evidenceExpected, at: 5, to: nextTest)
                    try bind(
                        String(bytes: JSONEncoder.horizon2.encode(entry.prerequisites), encoding: .utf8) ?? "",
                        at: 6,
                        to: nextTest
                    )
                    bind(entry.riskClass.rawValue, at: 7, to: nextTest)
                    bind(entry.userAction, at: 8, to: nextTest)
                    bind(entry.stoppingCondition, at: 9, to: nextTest)
                    bind(entry.expectedObservations, at: 10, to: nextTest)
                    bind(entry.safetyWarning, at: 11, to: nextTest)
                    // The v1 table has one opaque provenance column. Store the
                    // complete immutable catalog entry there so reload never
                    // resolves a historical reference against a newer catalog.
                    try bind(
                        String(bytes: JSONEncoder.horizon2.encode(entry), encoding: .utf8) ?? "",
                        at: 12,
                        to: nextTest
                    )
                    guard sqlite3_step(nextTest) == SQLITE_DONE
                    else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
                }
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    /// Explicit user recovery removes only observations with no incident,
    /// evidence-set, or inference references, then compacts the physical
    /// journal so a capacity failure can genuinely return to available.
    func clearUnprotectedHistory() throws -> EvidenceDeletionResult {
        guard availabilityState != .unavailable else { throw currentError() }
        let deletion = try deleteHistory(olderThan: nil)
        do {
            try connection.exec("VACUUM")
            try checkpoint(force: true)
            try protectJournalFiles()
        } catch {
            markCapacityUnavailable()
            throw error
        }
        let status = retentionStatus()
        if status.bytes <= maximumJournalBytes {
            availabilityState = .available
            capacityRecoveryBlocked = false
        } else {
            markCapacityUnavailable()
        }
        return EvidenceDeletionResult(
            observationsDeleted: deletion.observationsDeleted,
            incidentsDeleted: deletion.incidentsDeleted,
            healthRecordsDeleted: deletion.healthRecordsDeleted,
            finalStatus: retentionStatus()
        )
    }

    func inferences(incidentID: UUID, currentOnly: Bool) -> [Inference] {
        do {
            let statement = try connection
                .prepare(
                    "SELECT i.inference_id FROM inferences i JOIN evidence_sets e " +
                        "ON e.evidence_set_id=i.evidence_set_id WHERE e.incident_id=? " +
                        "ORDER BY i.inference_id"
                )
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            var result: [Inference] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))),
                      let inference = try loadInference(id: id)
                else { continue }
                if currentOnly,
                   try !InferenceVersionPolicy.isCurrent(
                       inference: inference,
                       evidenceSet: loadEvidenceSet(id: inference.evidenceSetID)
                   ) {
                    continue
                }
                result.append(inference)
            }
            return result
        } catch { return [] }
    }

    func inference(id: UUID) -> Inference? {
        try? loadInference(id: id)
    }

    func nextTestSnapshots(inferenceID: UUID) -> [NextTestCatalogEntry] {
        (try? loadNextTestSnapshots(inferenceID: inferenceID)) ?? []
    }

    func loadInference(id: UUID) throws -> Inference? {
        let statement = try connection.prepare("SELECT output_json FROM inferences WHERE inference_id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let json = String(cString: sqlite3_column_text(statement, 0))
        guard let inference = try? JSONDecoder.horizon2.decode(Inference.self, from: Data(json.utf8)) else {
            throw EvidenceJournalError.corruption
        }
        return inference
    }

    func loadNextTestSnapshots(inferenceID: UUID) throws -> [NextTestCatalogEntry] {
        let statement = try connection
            .prepare(
                "SELECT catalog_id, catalog_version, purpose, evidence_expected, prerequisites_json, risk_class, " +
                    "user_action, stopping_condition, expected_observations, safety_warning, catalog_provenance " +
                    "FROM next_test_references WHERE inference_id=? ORDER BY catalog_id,catalog_version"
            )
        defer { sqlite3_finalize(statement) }
        bind(inferenceID.uuidString, at: 1, to: statement)
        var entries: [NextTestCatalogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let risk = NextTestRiskClass(rawValue: String(cString: sqlite3_column_text(statement, 5))),
                  let prerequisites = try? JSONDecoder.horizon2.decode(
                      [NextTestPrerequisite].self,
                      from: Data(String(cString: sqlite3_column_text(statement, 4)).utf8)
                  )
            else { throw EvidenceJournalError.corruption }
            let storedProvenance = String(cString: sqlite3_column_text(statement, 10))
            if let completeEntry = try? JSONDecoder.horizon2.decode(
                NextTestCatalogEntry.self,
                from: Data(storedProvenance.utf8)
            ) {
                entries.append(completeEntry)
                continue
            }
            entries.append(NextTestCatalogEntry(
                reference: NextTestReference(
                    testID: String(cString: sqlite3_column_text(statement, 0)),
                    catalogVersion: String(cString: sqlite3_column_text(statement, 1)),
                    purpose: String(cString: sqlite3_column_text(statement, 2)),
                    evidenceExpected: String(cString: sqlite3_column_text(statement, 3))
                ),
                prerequisites: prerequisites,
                riskClass: risk,
                actionKind: .inspect,
                userAction: String(cString: sqlite3_column_text(statement, 6)),
                stoppingCondition: String(cString: sqlite3_column_text(statement, 7)),
                expectedObservations: String(cString: sqlite3_column_text(statement, 8)),
                safetyWarning: String(cString: sqlite3_column_text(statement, 9)),
                catalogProvenance: storedProvenance
            ))
        }
        return entries
    }
}
