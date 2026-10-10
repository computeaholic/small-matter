import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func persistEvidenceSets(incidentID: UUID, sets: [EvidenceSet]) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        guard let incident = incident(id: incidentID),
              incident.status == .complete || incident.status == .incomplete
        else {
            throw EvidenceJournalError.invalidIncident
        }
        let encodedSets = try sets.reduce(into: 0) { total, set in
            total += try JSONEncoder.horizon2.encode(set).count
        }
        try ensureCapacity(for: encodedSets + sets.reduce(0) { $0 + $1.members.count * 512 } + 16384)
        let incidentObservationIDs = Set(self.incidentObservationIDs(incidentID: incidentID))
        try connection.exec("BEGIN IMMEDIATE")
        do {
            for set in sets {
                guard set.memberObservationIDs.allSatisfy(incidentObservationIDs.contains) else {
                    throw EvidenceJournalError
                        .invalidCorrelationInput("Evidence set references an observation outside its incident package.")
                }
                if let existing = try loadEvidenceSet(id: set.id) {
                    guard try evidenceSetIncidentID(id: set.id) == incidentID else {
                        throw EvidenceJournalError.evidenceSetConflict(set.id)
                    }
                    guard existing == set else { throw EvidenceJournalError.evidenceSetConflict(set.id) }
                    continue
                }
                let insert = try connection.prepare("""
                    INSERT INTO evidence_sets(
                        evidence_set_id, incident_id, rule_id, rule_version, window_start_wall,
                        window_end_wall, order_quality, created_at_wall, schema_version
                    )
                    VALUES(?,?,?,?,?,?,?,?,?)
                """)
                defer { sqlite3_finalize(insert) }
                bind(set.id.uuidString, at: 1, to: insert)
                bind(incidentID.uuidString, at: 2, to: insert)
                bind(set.ruleID, at: 3, to: insert)
                bind(set.ruleVersion, at: 4, to: insert)
                bind(Self.dateString(set.temporalBounds.start), at: 5, to: insert)
                bind(Self.dateString(set.temporalBounds.end), at: 6, to: insert)
                bind(set.orderingQuality.rawValue, at: 7, to: insert)
                bind(Self.dateString(Date()), at: 8, to: insert)
                bind(Int64(set.evidenceSetSchemaVersion), at: 9, to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE
                else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }

                for member in set.members {
                    let memberInsert = try connection
                        .prepare(
                            "INSERT INTO evidence_members(evidence_set_id,observation_id,membership_role) VALUES(?,?,?)"
                        )
                    defer { sqlite3_finalize(memberInsert) }
                    bind(set.id.uuidString, at: 1, to: memberInsert)
                    bind(member.observationID.uuidString, at: 2, to: memberInsert)
                    bind("MEMBER", at: 3, to: memberInsert)
                    guard sqlite3_step(memberInsert) == SQLITE_DONE
                    else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
                    for reason in member.reasons {
                        let reasonInsert = try connection
                            .prepare(
                                "INSERT INTO evidence_reasons(" +
                                    "reason_id, evidence_set_id, observation_id, reason_code, " +
                                    "reason_json, rule_id, rule_version) VALUES(?,?,?,?,?,?,?)"
                            )
                        defer { sqlite3_finalize(reasonInsert) }
                        bind(
                            Self.evidenceReasonID(setID: set.id, observationID: member.observationID, reason: reason)
                                .uuidString,
                            at: 1,
                            to: reasonInsert
                        )
                        bind(set.id.uuidString, at: 2, to: reasonInsert)
                        bind(member.observationID.uuidString, at: 3, to: reasonInsert)
                        bind(reason.stableCode, at: 4, to: reasonInsert)
                        try bind(
                            String(bytes: JSONEncoder.horizon2.encode(reason), encoding: .utf8) ?? "",
                            at: 5,
                            to: reasonInsert
                        )
                        bind(set.ruleID, at: 6, to: reasonInsert)
                        bind(set.ruleVersion ?? "", at: 7, to: reasonInsert)
                        guard sqlite3_step(reasonInsert) == SQLITE_DONE
                        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
                    }
                }
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    func evidenceSets(incidentID: UUID) -> [EvidenceSet] {
        do {
            let statement = try connection
                .prepare("SELECT evidence_set_id FROM evidence_sets WHERE incident_id=? ORDER BY evidence_set_id")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            var result: [EvidenceSet] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) else { continue }
                guard let set = try loadEvidenceSet(id: id) else { continue }
                result.append(set)
            }
            return result
        } catch { return [] }
    }

    // swiftlint:disable:next function_body_length
    func loadEvidenceSet(id: UUID) throws -> EvidenceSet? {
        let setStatement = try connection
            .prepare(
                "SELECT rule_id, rule_version, window_start_wall, window_end_wall, order_quality, " +
                    "schema_version FROM evidence_sets WHERE evidence_set_id=?"
            )
        defer { sqlite3_finalize(setStatement) }
        bind(id.uuidString, at: 1, to: setStatement)
        guard sqlite3_step(setStatement) == SQLITE_ROW else { return nil }
        let ruleID = sqlite3_column_type(setStatement, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(
            setStatement,
            0
        ))
        let ruleVersion = sqlite3_column_type(setStatement, 1) == SQLITE_NULL ? nil :
            String(cString: sqlite3_column_text(
                setStatement,
                1
            ))
        guard let start = Self.date(from: String(cString: sqlite3_column_text(setStatement, 2))),
              let end = Self.date(from: String(cString: sqlite3_column_text(setStatement, 3))),
              let orderQuality = EvidenceOrderingQuality(rawValue: String(cString: sqlite3_column_text(
                  setStatement,
                  4
              )))
        else { throw EvidenceJournalError.corruption }
        let schemaVersion = Int(sqlite3_column_int64(setStatement, 5))

        let memberStatement = try connection.prepare("""
            SELECT m.observation_id
            FROM evidence_members m
            JOIN observations o ON o.observation_id=m.observation_id
            WHERE m.evidence_set_id=?
            ORDER BY o.observed_wall, o.local_sequence, o.observation_id
        """)
        defer { sqlite3_finalize(memberStatement) }
        bind(id.uuidString, at: 1, to: memberStatement)
        var memberIDs: [UUID] = []
        while sqlite3_step(memberStatement) == SQLITE_ROW,
              let memberID = UUID(uuidString: String(cString: sqlite3_column_text(
                  memberStatement,
                  0
              ))) {
            memberIDs.append(memberID)
        }
        var members: [EvidenceMembership] = []
        for memberID in memberIDs {
            let reasonStatement = try connection
                .prepare(
                    "SELECT reason_json FROM evidence_reasons WHERE evidence_set_id=? " +
                        "AND observation_id=? ORDER BY reason_code,reason_json"
                )
            defer { sqlite3_finalize(reasonStatement) }
            bind(id.uuidString, at: 1, to: reasonStatement)
            bind(memberID.uuidString, at: 2, to: reasonStatement)
            var reasons: [EvidenceMembershipReason] = []
            while sqlite3_step(reasonStatement) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(reasonStatement, 0))
                guard let reason = try? JSONDecoder.horizon2
                    .decode(EvidenceMembershipReason.self, from: Data(json.utf8))
                else { throw EvidenceJournalError.corruption }
                reasons.append(reason)
            }
            members.append(EvidenceMembership(
                observationID: memberID,
                reasons: reasons.sorted { $0.canonicalValue < $1.canonicalValue }
            ))
        }
        return EvidenceSet(
            id: id,
            members: members,
            ruleID: ruleID,
            ruleVersion: ruleVersion,
            temporalBounds: EvidenceTimeBounds(start: start, end: end),
            orderingQuality: orderQuality,
            evidenceSetSchemaVersion: schemaVersion
        )
    }

    func evidenceSetIncidentID(id: UUID) throws -> UUID? {
        let statement = try connection.prepare("SELECT incident_id FROM evidence_sets WHERE evidence_set_id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))
    }
}
