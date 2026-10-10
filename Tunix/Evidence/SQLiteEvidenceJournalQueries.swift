import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    func observation(id: UUID) -> Observation? {
        guard availabilityState != .unavailable else { return nil }
        do {
            let statement = try connection
                .prepare("SELECT canonical_value_json FROM observations WHERE observation_id=?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeObservation(String(cString: sqlite3_column_text(statement, 0)))
        } catch { return nil }
    }

    // Why: explicit fail-closed matrix.
    // Why: explicit fail-closed matrix.
    // swiftlint:disable:next cyclomatic_complexity
    func query(_ query: EvidenceJournalQuery) -> [Observation] {
        guard availabilityState != .unavailable else { return [] }
        var clauses: [String] = []
        var values: [(String?, Int64?)] = []
        if let start = query.start {
            clauses.append("o.observed_wall >= ?"); values.append((Self.dateString(start), nil))
        }
        if let end = query.end {
            clauses.append("o.observed_wall <= ?"); values.append((Self.dateString(end), nil))
        }
        if let sourceID = query.sourceID {
            clauses.append("o.source_id = ?"); values.append((sourceID.rawValue, nil))
        }
        if let digest = query.subjectIdentityDigest {
            clauses.append("s.identity_digest = ?"); values.append((digest, nil))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let direction = query.newestFirst ? "DESC" : "ASC"
        let limitClause = query.limit == nil ? "" : " LIMIT ?"
        let sql = "SELECT o.canonical_value_json FROM observations o LEFT JOIN subjects s " +
            "ON s.subject_id=o.subject_id \(whereClause) ORDER BY o.observed_wall \(direction), " +
            "o.local_sequence \(direction),o.observation_id \(direction)\(limitClause)"
        do {
            let statement = try connection.prepare(sql)
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            for (text, integer) in values {
                if let text {
                    Self.bind(text, at: index, to: statement)
                } else {
                    Self.bind(integer, at: index, to: statement)
                }
                index += 1
            }
            if let limit = query.limit {
                Self.bind(Int64(limit), at: index, to: statement)
            }
            var result: [Observation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let observation = decodeObservation(String(cString: sqlite3_column_text(statement, 0))) {
                    result.append(observation)
                }
            }
            return result
        } catch { return [] }
    }

    // Why: explicit fail-closed matrix.
    // Why: ordered canonical flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func recordSourceHealth(_ record: EvidenceSourceHealthRecord) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        if availabilityState == .capacityUnavailable {
            guard !capacityRecoveryBlocked else { throw currentError() }
            _ = try performRetention()
            guard availabilityState == .available else { throw currentError() }
        }
        try validateHealthDetail(record.detail)
        try ensureCapacity(for: 4096)
        var committed = false
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO source_health_or_suppression(record_id,source_id,observation_id,record_kind,
                reason_code,suppressed_count,first_observed_wall,last_observed_wall,details_json)
                VALUES(?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(record.id.uuidString, at: 1, to: statement)
            bind(record.sourceID.rawValue, at: 2, to: statement)
            bind(record.observationID?.uuidString, at: 3, to: statement)
            bind(record.event.rawValue, at: 4, to: statement)
            bind(record.reason.rawValue, at: 5, to: statement)
            bind(Int64(record.suppressedCount), at: 6, to: statement)
            bind(Self.dateString(record.observedAt), at: 7, to: statement)
            bind(Self.dateString(record.observedAt), at: 8, to: statement)
            try bind(detailsJSON(record.detail), at: 9, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
            while try Int(connection.scalar("SELECT COUNT(*) FROM source_health_or_suppression")) ?? 0 > 4096 {
                let cleanup = try connection
                    .prepare(
                        "DELETE FROM source_health_or_suppression WHERE record_id IN (" +
                            "SELECT record_id FROM source_health_or_suppression " +
                            "ORDER BY last_observed_wall ASC, record_id ASC LIMIT ?)"
                    )
                defer { sqlite3_finalize(cleanup) }
                bind(Int64(retentionBatchSize), at: 1, to: cleanup)
                guard sqlite3_step(cleanup) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
            }
            try connection.exec("COMMIT")
            committed = true
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
        do {
            try checkpoint(force: true)
            try protectJournalFiles()
            guard stableFootprintBytes() <= maximumJournalBytes else {
                throw EvidenceJournalError.capacityUnavailable
            }
        } catch {
            if committed {
                try? removeHealthRecord(record.id)
            }
            try reclaimPhysicalSpaceAfterRejectedMutation()
            markCapacityUnavailable()
            throw error
        }
    }

    func sourceHealth() -> [EvidenceSourceHealthRecord] {
        do {
            let statement = try connection
                .prepare(
                    "SELECT record_id, source_id, observation_id, record_kind, reason_code, suppressed_count, " +
                        "last_observed_wall, details_json FROM source_health_or_suppression ORDER BY record_id"
                )
            defer { sqlite3_finalize(statement) }
            var records: [EvidenceSourceHealthRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))),
                      let source = Horizon2SourceID(rawValue: String(cString: sqlite3_column_text(statement, 1))),
                      let event = EvidenceSourceHealthEvent(rawValue: String(cString: sqlite3_column_text(
                          statement,
                          3
                      ))),
                      let reason = EvidenceUnknownReason(rawValue: String(cString: sqlite3_column_text(statement, 4))),
                      let date = Self.date(from: String(cString: sqlite3_column_text(statement, 6))) else { continue }
                let observationID = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil :
                    UUID(uuidString: String(cString: sqlite3_column_text(
                        statement,
                        2
                    )))
                records.append(EvidenceSourceHealthRecord(
                    id: id,
                    sourceID: source,
                    observationID: observationID,
                    event: event,
                    reason: reason,
                    suppressedCount: Int(sqlite3_column_int64(statement, 5)),
                    observedAt: date,
                    detail: detail(from: String(cString: sqlite3_column_text(statement, 7)))
                ))
            }
            return records
        } catch { return [] }
    }

    func beginIncidentCapture(_ session: IncidentCaptureSession) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        let sessionJSON = try String(bytes: JSONEncoder.horizon2.encode(session), encoding: .utf8) ?? ""
        try ensureCapacity(for: sessionJSON.utf8.count + session.observationIDs.count * 256 + 8192)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO incidents(
                    incident_id, marker_observation_id, marker_wall, pre_window_seconds,
                    post_window_seconds, status, schema_version, created_at_wall,
                    completed_at_wall, failure_reason, retention_protected, package_json
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,0,NULL)
            """)
            defer { sqlite3_finalize(statement) }
            bind(session.id.uuidString, at: 1, to: statement)
            bind(session.marker.observationID?.uuidString, at: 2, to: statement)
            bind(Self.dateString(session.marker.wallTime), at: 3, to: statement)
            bind(Int64(session.preWindowSeconds), at: 4, to: statement)
            bind(Int64(session.postWindowSeconds), at: 5, to: statement)
            bind("CAPTURING", at: 6, to: statement)
            bind(Int64(session.schemaVersion), at: 7, to: statement)
            bind(Self.dateString(session.startedAt), at: 8, to: statement)
            bind(nil as String?, at: 9, to: statement)
            bind(nil as String?, at: 10, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
            try connection.exec("DELETE FROM incident_observations WHERE incident_id='\(session.id.uuidString)'")
            try insertIncidentMembership(incidentID: session.id, observationIDs: session.observationIDs)
            try connection.exec("DELETE FROM incident_context WHERE incident_id='\(session.id.uuidString)'")
            try insertIncidentContext(
                incidentID: session.id,
                observedAt: session.marker.wallTime,
                kind: "ACTIVE_CAPTURE_SESSION",
                payload: sessionJSON
            )
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    func activeIncidentCaptures() -> [IncidentCaptureSession] {
        do {
            let statement = try connection.prepare("""
                SELECT i.incident_id, c.payload_json
                FROM incidents i
                JOIN incident_context c ON c.incident_id=i.incident_id
                WHERE i.status='CAPTURING' AND c.context_kind='ACTIVE_CAPTURE_SESSION'
                ORDER BY i.marker_wall, i.incident_id
            """)
            defer { sqlite3_finalize(statement) }
            var sessions: [IncidentCaptureSession] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let payload = String(cString: sqlite3_column_text(statement, 1))
                if let session = try? JSONDecoder.horizon2.decode(
                    IncidentCaptureSession.self,
                    from: Data(payload.utf8)
                ) {
                    sessions.append(session)
                }
            }
            return sessions
        } catch { return [] }
    }

    func finalizeIncidentCapture(_ package: IncidentPackage) throws {
        try persist(incident: package)
    }

    func incidentSummaries(limit: Int) -> [IncidentPackage] {
        do {
            let statement = try connection.prepare("""
                SELECT package_json FROM incidents
                WHERE package_json IS NOT NULL
                ORDER BY marker_wall DESC, incident_id DESC
                LIMIT ?
            """)
            defer { sqlite3_finalize(statement) }
            bind(Int64(max(1, limit)), at: 1, to: statement)
            var packages: [IncidentPackage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let payload = String(cString: sqlite3_column_text(statement, 0))
                if let package = try? JSONDecoder.horizon2.decode(IncidentPackage.self, from: Data(payload.utf8)) {
                    packages.append(package)
                }
            }
            return packages
        } catch { return [] }
    }

    func insertIncidentMembership(incidentID: UUID, observationIDs: [UUID]) throws {
        for observationID in observationIDs {
            let statement = try connection
                .prepare(
                    "INSERT OR IGNORE INTO incident_observations(" +
                        "incident_id, observation_id, membership_role) VALUES(?,?,?)"
                )
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            bind(observationID.uuidString, at: 2, to: statement)
            bind("MEMBER", at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        }
    }

    func insertIncidentContext(incidentID: UUID, observedAt: Date, kind: String, payload: String) throws {
        let context = try connection
            .prepare(
                "INSERT OR REPLACE INTO incident_context(" +
                    "context_id, incident_id, context_kind, observed_wall, payload_json, " +
                    "sensitivity_policy, immutable) VALUES(?,?,?,?,?,?,1)"
            )
        defer { sqlite3_finalize(context) }
        bind(incidentID.uuidString, at: 1, to: context)
        bind(incidentID.uuidString, at: 2, to: context)
        bind(kind, at: 3, to: context)
        bind(Self.dateString(observedAt), at: 4, to: context)
        bind(payload, at: 5, to: context)
        bind("LOCAL_ONLY", at: 6, to: context)
        guard sqlite3_step(context) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
    }

    func recordIncidentMembership(incidentID: UUID, observationIDs: [UUID]) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        try ensureCapacity(for: observationIDs.count * 256 + 8192)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let incident = try connection
                .prepare(
                    "INSERT OR IGNORE INTO incidents(" +
                        "incident_id, marker_wall, pre_window_seconds, post_window_seconds, status, " +
                        "schema_version, created_at_wall) VALUES(?,?,?,?,?,?,?)"
                )
            defer { sqlite3_finalize(incident) }
            bind(incidentID.uuidString, at: 1, to: incident)
            bind(Self.dateString(Date()), at: 2, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPreWindowSeconds), at: 3, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPostWindowSeconds), at: 4, to: incident)
            bind(IncidentCaptureStatus.incomplete.rawValue, at: 5, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPackageSchemaVersion), at: 6, to: incident)
            bind(Self.dateString(Date()), at: 7, to: incident)
            guard sqlite3_step(incident) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
            try insertIncidentMembership(incidentID: incidentID, observationIDs: observationIDs)
            try connection.exec("COMMIT")
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    func incidentObservationIDs(incidentID: UUID) -> [UUID] {
        do {
            let statement = try connection
                .prepare("SELECT observation_id FROM incident_observations WHERE incident_id=? ORDER BY observation_id")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            var IDs: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: String(cString: sqlite3_column_text(
                statement,
                0
            ))) {
                IDs.append(id)
            }
            return IDs
        } catch { return [] }
    }
}
