import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    // Why: ordered canonical flow.
    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    func persist(incident: IncidentPackage, retentionProtected: Bool = false) throws {
        let packageJSON = try String(bytes: JSONEncoder.horizon2.encode(incident), encoding: .utf8) ?? ""
        let contextJSON = try String(
            bytes: JSONEncoder.horizon2.encode(incident.materializedContext),
            encoding: .utf8
        ) ??
            ""
        try ensureCapacity(for: packageJSON.utf8.count + contextJSON.utf8.count + 8192)
        var committed = false
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO incidents(
                    incident_id, marker_observation_id, marker_wall, pre_window_seconds,
                    post_window_seconds, status, schema_version, created_at_wall,
                    completed_at_wall, failure_reason, retention_protected, package_json
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(incident.id.uuidString, at: 1, to: statement); bind(
                incident.marker.observationID?.uuidString,
                at: 2,
                to: statement
            ); bind(Self.dateString(incident.marker.wallTime), at: 3, to: statement)
            bind(Int64(incident.preWindowSeconds), at: 4, to: statement); bind(
                Int64(incident.postWindowSeconds),
                at: 5,
                to: statement
            ); bind(incident.status.rawValue, at: 6, to: statement); bind(
                Int64(incident.schemaVersion),
                at: 7,
                to: statement
            ); bind(Self.dateString(Date()), at: 8, to: statement); bind(
                incident.completedAt.map(Self.dateString),
                at: 9,
                to: statement
            ); bind(incident.failureReason?.rawValue, at: 10, to: statement); bind(
                Int64(retentionProtected ? 1 : 0),
                at: 11,
                to: statement
            ); bind(packageJSON, at: 12, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
            try connection.exec("DELETE FROM incident_observations WHERE incident_id='\(incident.id.uuidString)'")
            try insertIncidentMembership(incidentID: incident.id, observationIDs: incident.observationIDs)
            try connection.exec("DELETE FROM incident_context WHERE incident_id='\(incident.id.uuidString)'")
            try insertIncidentContext(
                incidentID: incident.id,
                observedAt: incident.marker.wallTime,
                kind: "MATERIALIZED_CONTEXT",
                payload: contextJSON
            )
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
                try? removePersistedIncident(incidentID: incident.id)
            }
            if (error as? EvidenceJournalError) == .capacityUnavailable {
                markCapacityUnavailable()
            }
            try reclaimPhysicalSpaceAfterRejectedMutation()
            throw error
        }
    }

    func incident(id: UUID) -> IncidentPackage? {
        do {
            let statement = try connection.prepare("SELECT package_json FROM incidents WHERE incident_id=?")
            defer { sqlite3_finalize(statement) }; bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let packageJSON = sqlite3_column_text(statement, 0)
            else { return nil }
            return try JSONDecoder.horizon2.decode(IncidentPackage.self, from: Data(String(cString: packageJSON).utf8))
        } catch { return nil }
    }

    func deleteIncident(id: UUID) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection
                .prepare("DELETE FROM incidents WHERE incident_id=?"); defer { sqlite3_finalize(statement) }; bind(
                id.uuidString,
                at: 1,
                to: statement
            ); guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }; try connection
                .exec("COMMIT"); try checkpoint(force: true)
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    func removePersistedIncident(incidentID: UUID) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("DELETE FROM incidents WHERE incident_id=?")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    func setIncidentRetentionProtection(incidentID: UUID, protected: Bool) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        try ensureCapacity(for: 4096)
        let statement = try connection.prepare("UPDATE incidents SET retention_protected=? WHERE incident_id=?")
        defer { sqlite3_finalize(statement) }
        bind(Int64(protected ? 1 : 0), at: 1, to: statement)
        bind(incidentID.uuidString, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
    }

    static func evidenceReasonID(setID: UUID, observationID: UUID,
                                 reason: EvidenceMembershipReason) -> UUID {
        let material = "\(setID.uuidString)|\(observationID.uuidString)|\(reason.canonicalValue)"
        return EvidenceIdentityDigest.makeUUID(scope: "evidence-reason", material: [material])!
    }

    func deleteHistory(olderThan cutoff: Date? = nil) throws -> EvidenceDeletionResult {
        let date = cutoff.map(Self.dateString)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            var deleted = 0
            while true {
                let whereClause = date == nil ? "1=1" : "observed_wall < '\(date!)'"
                let statement = try connection.prepare("""
                    DELETE FROM observations
                    WHERE observation_id IN (
                        SELECT o.observation_id FROM observations o WHERE \(whereClause)
                        AND NOT EXISTS (SELECT 1 FROM incident_observations i WHERE i.observation_id = o.observation_id)
                        AND NOT EXISTS (SELECT 1 FROM evidence_members e WHERE e.observation_id = o.observation_id)
                        AND NOT EXISTS (SELECT 1 FROM evidence_reasons r WHERE r.observation_id = o.observation_id)
                        AND NOT EXISTS (SELECT 1 FROM inference_support s WHERE s.observation_id = o.observation_id)
                        AND NOT EXISTS (
                            SELECT 1 FROM inference_contradictions c
                            WHERE c.observation_id = o.observation_id
                        )
                        ORDER BY o.observed_wall, o.observation_id LIMIT \(retentionBatchSize)
                    )
                """)
                defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_DONE
                else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }; let count = Int(sqlite3_changes(connection.database)); deleted += count; if count == 0 {
                    break
                }
            }
            try connection.exec("COMMIT"); try checkpoint(force: true)
            return EvidenceDeletionResult(
                observationsDeleted: deleted,
                incidentsDeleted: 0,
                healthRecordsDeleted: 0,
                finalStatus: retentionStatus()
            )
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    func performRetention(now: Date = Date()) throws -> EvidenceRetentionStatus {
        guard availabilityState != .unavailable else { throw EvidenceJournalError.unavailable }
        let ordinaryCutoff = Self.dateString(now.addingTimeInterval(-Double(retentionDays) * 86400))
        let incidentCutoff = Self
            .dateString(now.addingTimeInterval(-Double(Horizon2EvidenceConfiguration.maximumRetentionDays) * 86400))
        try deleteExpiredObservations(before: ordinaryCutoff)
        try deleteExpiredIncidents(before: incidentCutoff)
        try deleteExpiredObservations(before: ordinaryCutoff)
        if stableFootprintBytes() > maximumJournalBytes {
            try connection.exec("VACUUM")
            try checkpoint(force: true)
        }
        while stableFootprintBytes() > maximumJournalBytes {
            guard let incidentID = try oldestEvictableIncident() else { break }
            try deleteIncident(id: incidentID)
            try deleteExpiredObservations(before: ordinaryCutoff)
            if stableFootprintBytes() > maximumJournalBytes {
                try connection.exec("VACUUM")
                try checkpoint(force: true)
            }
        }
        let status = retentionStatus()
        if status.bytes > maximumJournalBytes {
            markCapacityUnavailable()
            return EvidenceRetentionStatus(
                availability: .capacityUnavailable,
                bytes: status.bytes,
                protectedIncidentCount: status.protectedIncidentCount
            )
        }
        availabilityState = .available
        capacityRecoveryBlocked = false
        return EvidenceRetentionStatus(
            availability: .available,
            bytes: status.bytes,
            protectedIncidentCount: status.protectedIncidentCount
        )
    }

    func reset() throws {
        availabilityState = .unavailable
        try connection.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.close()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: walURL)
        try? fileManager.removeItem(at: shmURL)
        try fileManager.removeItem(at: databaseURL)
    }

    func retentionStatus() -> EvidenceRetentionStatus {
        guard availabilityState != .unavailable else {
            return EvidenceRetentionStatus(
                availability: .unavailable,
                bytes: stableFootprintBytes(),
                protectedIncidentCount: 0
            )
        }
        let protected = (try? connection.scalar("SELECT COUNT(*) FROM incidents WHERE retention_protected=1")) ?? "0"
        let availability: EvidenceJournalAvailability = availabilityState
        return EvidenceRetentionStatus(
            availability: availability,
            bytes: stableFootprintBytes(),
            protectedIncidentCount: Int(protected) ?? 0
        )
    }

    func schemaTableNames() -> [String] {
        (try? scalarRows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")) ?? []
    }

    func schemaIndexNames() -> [String] {
        (
            try? scalarRows(
                "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY name"
            )
        ) ??
            []
    }

    #if HORIZON2_MEASUREMENT
        func measurementJournalFootprint(initialStableBytes: Int) -> Horizon2MeasurementJournalFootprint {
            let mainBytes = fileSize(databaseURL)
            let walBytes = fileSize(walURL)
            let shmBytes = fileSize(shmURL)
            return Horizon2MeasurementJournalFootprint(
                initialStableBytes: initialStableBytes,
                appendProfile: horizon2MeasurementAppendProfile(measurementAppendTimings),
                transactionHeadroom: Horizon2MeasurementTransactionHeadroom(
                    transactions: measurementTransactionCount,
                    minimumBaselineBytes: measurementTransactionCount == 0 ? 0 :
                        measurementMinBaselineBytes,
                    maximumBaselineBytes: measurementMaxBaselineBytes,
                    maximumPeakBytes: measurementMaxPeakBytes,
                    maximumDeltaBytes: measurementMaxDeltaBytes
                ),
                finalMainBytes: mainBytes,
                finalWALBytes: walBytes,
                finalSHMBytes: shmBytes,
                finalStableBytes: mainBytes + walBytes + shmBytes
            )
        }

        func measurementRecordTransaction(baselineBytes: Int, peakBytes: Int) {
            let delta = max(0, peakBytes - baselineBytes)
            measurementTransactionCount += 1
            measurementMinBaselineBytes = min(measurementMinBaselineBytes, baselineBytes)
            measurementMaxBaselineBytes = max(measurementMaxBaselineBytes, baselineBytes)
            measurementMaxPeakBytes = max(measurementMaxPeakBytes, peakBytes)
            measurementMaxDeltaBytes = max(measurementMaxDeltaBytes, delta)
        }

        func measurementMilliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        }

        func fileSize(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        }
    #endif

    func explainQueryPlan(_ query: EvidenceJournalQuery) -> [String] {
        let hasSource = query.sourceID != nil
        let hasSubject = query.subjectIdentityDigest != nil
        let sql: String
        if hasSubject {
            sql = "EXPLAIN QUERY PLAN SELECT o.* FROM observations o JOIN subjects s " +
                "ON s.subject_id=o.subject_id WHERE s.identity_digest=? AND o.observed_wall >= ? " +
                "ORDER BY o.observed_wall,o.local_sequence"
        } else if hasSource {
            sql = "EXPLAIN QUERY PLAN SELECT * FROM observations WHERE source_id=? " +
                "AND observed_wall >= ? ORDER BY observed_wall,local_sequence"
        } else {
            sql = "EXPLAIN QUERY PLAN SELECT * FROM observations WHERE observed_wall >= ? " +
                "ORDER BY observed_wall,local_sequence"
        }
        guard let statement = try? connection.prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        if let subjectIdentityDigest = query.subjectIdentityDigest {
            bind(subjectIdentityDigest, at: 1, to: statement)
            bind(Self.dateString(query.start ?? .distantPast), at: 2, to: statement)
        } else if let sourceID = query.sourceID {
            bind(sourceID.rawValue, at: 1, to: statement)
            bind(Self.dateString(query.start ?? .distantPast), at: 2, to: statement)
        } else {
            bind(Self.dateString(query.start ?? .distantPast), at: 1, to: statement)
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 3)))
        }
        return rows
    }

    #if DEBUG
        func setTestMaximumPageCount(_ pageCount: Int) throws {
            try connection.exec("PRAGMA max_page_count=\(max(1, pageCount))")
        }

        func pageCountForTesting() throws -> Int {
            try Int(connection.scalar("PRAGMA page_count")) ?? 0
        }

        func setTestMaximumJournalBytes(_ bytes: Int) {
            maximumJournalBytes = max(1, bytes)
        }

        func forceCapacityUnavailableForTesting() {
            availabilityState = .capacityUnavailable
            capacityRecoveryBlocked = false
        }

        func checkpointForTesting() throws {
            try checkpoint(force: true)
        }

        func foreignKeyViolationsForTesting() -> [String] {
            (try? scalarRows("PRAGMA foreign_key_check")) ?? []
        }
    #endif

    func ensureCapacity(for estimatedBytes: Int) throws {
        let currentBytes = stableFootprintBytes()
        if currentBytes < maximumJournalBytes,
           currentBytes + estimatedBytes <= maximumJournalBytes {
            return
        }
        _ = try performRetention()
        guard availabilityState == .available,
              stableFootprintBytes() + estimatedBytes <= maximumJournalBytes
        else {
            markCapacityUnavailable()
            throw EvidenceJournalError.capacityUnavailable
        }
    }

    func markCapacityUnavailable() {
        availabilityState = .capacityUnavailable
        capacityRecoveryBlocked = true
    }
}
