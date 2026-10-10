import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    func maybeCheckpoint(protect: Bool = true) throws -> Bool {
        let walSize = (try? walURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if appendsSinceCheckpoint >= 64 || walSize > 1_048_576 {
            try checkpoint(force: true, protect: protect)
            return true
        }
        return false
    }

    func checkpoint(force: Bool, protect: Bool = true) throws {
        if force {
            try connection.exec("PRAGMA wal_checkpoint(TRUNCATE)"); appendsSinceCheckpoint = 0
            if protect {
                try protectJournalFiles()
            }
        }
    }

    func stableFootprintBytes() -> Int {
        let paths = [databaseURL, walURL, shmURL]
        return paths.reduce(0) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    func existingCanonical(id: UUID) throws -> Data? {
        let statement = try connection
            .prepare("SELECT canonical_value_json FROM observations WHERE observation_id=?"); defer {
            sqlite3_finalize(statement)
        }; bind(
            id.uuidString,
            at: 1,
            to: statement
        ); guard sqlite3_step(statement) == SQLITE_ROW
        else { return nil }; return Data(String(cString: sqlite3_column_text(
            statement,
            0
        )).utf8)
    }

    func removeRejectedObservation(observationID: UUID, subjectID: String?, provenanceID: String?) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let observation = try connection.prepare("DELETE FROM observations WHERE observation_id=?")
            defer { sqlite3_finalize(observation) }
            bind(observationID.uuidString, at: 1, to: observation)
            guard sqlite3_step(observation) == SQLITE_DONE else {
                throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
            }
            if let subjectID {
                let subject = try connection
                    .prepare(
                        "DELETE FROM subjects WHERE subject_id=? " +
                            "AND NOT EXISTS (SELECT 1 FROM observations WHERE subject_id=?)"
                    )
                defer { sqlite3_finalize(subject) }
                bind(subjectID, at: 1, to: subject)
                bind(subjectID, at: 2, to: subject)
                guard sqlite3_step(subject) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
            }
            if let provenanceID {
                let provenance = try connection
                    .prepare(
                        "DELETE FROM provenance WHERE provenance_id=? " +
                            "AND NOT EXISTS (SELECT 1 FROM observations WHERE provenance_id=?)"
                    )
                defer { sqlite3_finalize(provenance) }
                bind(provenanceID, at: 1, to: provenance)
                bind(provenanceID, at: 2, to: provenance)
                guard sqlite3_step(provenance) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
            try protectJournalFiles()
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    func removeRejectedObservations(_ inserted: [SQLiteInsertedObservation]) throws {
        guard !inserted.isEmpty else { return }
        try connection.exec("BEGIN IMMEDIATE")
        do {
            for item in inserted {
                let observation = try connection.prepare("DELETE FROM observations WHERE observation_id=?")
                defer { sqlite3_finalize(observation) }
                bind(item.observationID.uuidString, at: 1, to: observation)
                guard sqlite3_step(observation) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
                let subject = try connection
                    .prepare(
                        "DELETE FROM subjects WHERE subject_id=? " +
                            "AND NOT EXISTS (SELECT 1 FROM observations WHERE subject_id=?)"
                    )
                defer { sqlite3_finalize(subject) }
                bind(item.subjectID, at: 1, to: subject)
                bind(item.subjectID, at: 2, to: subject)
                guard sqlite3_step(subject) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
                let provenance = try connection
                    .prepare(
                        "DELETE FROM provenance WHERE provenance_id=? " +
                            "AND NOT EXISTS (SELECT 1 FROM observations WHERE provenance_id=?)"
                    )
                defer { sqlite3_finalize(provenance) }
                bind(item.provenanceID, at: 1, to: provenance)
                bind(item.provenanceID, at: 2, to: provenance)
                guard sqlite3_step(provenance) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    func removeHealthRecord(_ recordID: UUID) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("DELETE FROM source_health_or_suppression WHERE record_id=?")
            defer { sqlite3_finalize(statement) }
            bind(recordID.uuidString, at: 1, to: statement)
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

    /// A rejected post-commit mutation may have grown the main database file
    /// even after its rows are removed. Reclaim only on this rare failure path;
    /// normal appends retain the bounded checkpoint policy.
    func reclaimPhysicalSpaceAfterRejectedMutation() throws {
        try checkpoint(force: true)
        guard stableFootprintBytes() > maximumJournalBytes else { return }
        try connection.exec("VACUUM")
        try checkpoint(force: true)
        try protectJournalFiles()
        guard stableFootprintBytes() <= maximumJournalBytes else {
            markCapacityUnavailable()
            throw EvidenceJournalError.capacityUnavailable
        }
    }

    func upsertSubject(_ observation: Observation) throws -> String {
        let identity = observation.subject.identityDigest ?? observation.id.uuidString
        let material = "\(observation.sourceID.rawValue)|\(observation.subject.type.rawValue)|\(identity)"
        let subjectID = EvidenceIdentityDigest.make(scope: "sqlite-subject", material: [material])!
        let statement = try connection
            .prepare(
                "INSERT INTO subjects(subject_id, source_id, subject_type, identity_digest, identity_quality, " +
                    "first_observed_wall, last_observed_wall, created_at_wall) VALUES(?,?,?,?,?,?,?,?) " +
                    "ON CONFLICT(subject_id) DO UPDATE SET last_observed_wall=excluded.last_observed_wall"
            )
        defer { sqlite3_finalize(statement) }; bind(subjectID, at: 1, to: statement); bind(
            observation.sourceID.rawValue,
            at: 2,
            to: statement
        ); bind(observation.subject.type.rawValue, at: 3, to: statement); bind(
            observation.subject.identityDigest,
            at: 4,
            to: statement
        ); bind(observation.subject.quality.rawValue, at: 5, to: statement); bind(
            Self.dateString(observation.time.observedWallTime),
            at: 6,
            to: statement
        ); bind(Self.dateString(observation.time.observedWallTime), at: 7, to: statement); bind(
            Self.dateString(Date()),
            at: 8,
            to: statement
        ); guard sqlite3_step(statement) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }; return subjectID
    }

    func upsertSubject(_ observation: Observation, using statement: OpaquePointer) throws -> String {
        reset(statement: statement)
        let identity = observation.subject.identityDigest ?? observation.id.uuidString
        let material = "\(observation.sourceID.rawValue)|\(observation.subject.type.rawValue)|\(identity)"
        let subjectID = EvidenceIdentityDigest.make(scope: "sqlite-subject", material: [material])!
        bind(subjectID, at: 1, to: statement)
        bind(observation.sourceID.rawValue, at: 2, to: statement)
        bind(observation.subject.type.rawValue, at: 3, to: statement)
        bind(observation.subject.identityDigest, at: 4, to: statement)
        bind(observation.subject.quality.rawValue, at: 5, to: statement)
        bind(Self.dateString(observation.time.observedWallTime), at: 6, to: statement)
        bind(Self.dateString(observation.time.observedWallTime), at: 7, to: statement)
        bind(Self.dateString(Date()), at: 8, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        return subjectID
    }

    func upsertProvenance(_ provenance: EvidenceProvenance) throws -> String {
        // The canonical Observation owns the qualified raw-reference digest.
        // The relational provenance row stores only structural provenance so
        // the digest cannot be silently duplicated outside its policy path.
        let structuralProvenance = EvidenceProvenance(
            sourceID: provenance.sourceID,
            apiName: provenance.apiName,
            apiVersion: provenance.apiVersion,
            captureChannel: provenance.captureChannel,
            sourceTimestampQuality: provenance.sourceTimestampQuality,
            normalizationRuleID: provenance.normalizationRuleID,
            normalizationRuleVersion: provenance.normalizationRuleVersion,
            hostScope: provenance.hostScope,
            rawReferenceDigest: nil
        )
        let details = try JSONEncoder.horizon2.encode(structuralProvenance)
        let id = EvidenceIdentityDigest.make(
            scope: "sqlite-provenance",
            material: [String(bytes: details, encoding: .utf8) ?? ""]
        )!
        let statement = try connection
            .prepare(
                "INSERT OR IGNORE INTO provenance(" +
                    "provenance_id, source_id, api_name, api_version, capture_channel, " +
                    "source_timestamp_quality, host_scope, created_at_wall, details_json) " +
                    "VALUES(?,?,?,?,?,?,?,?,?)"
            )
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement); bind(
            provenance.sourceID.rawValue,
            at: 2,
            to: statement
        ); bind(provenance.apiName, at: 3, to: statement); bind(provenance.apiVersion, at: 4, to: statement); bind(
            provenance.captureChannel,
            at: 5,
            to: statement
        ); bind(provenance.sourceTimestampQuality.rawValue, at: 6, to: statement); bind(
            provenance.hostScope.rawValue,
            at: 7,
            to: statement
        ); bind(Self.dateString(Date()), at: 8, to: statement); bind(
            String(bytes: details, encoding: .utf8) ?? "",
            at: 9,
            to: statement
        ); guard sqlite3_step(statement) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }; return id
    }

    func upsertProvenance(_ provenance: EvidenceProvenance, using statement: OpaquePointer) throws -> String {
        let structuralProvenance = EvidenceProvenance(
            sourceID: provenance.sourceID,
            apiName: provenance.apiName,
            apiVersion: provenance.apiVersion,
            captureChannel: provenance.captureChannel,
            sourceTimestampQuality: provenance.sourceTimestampQuality,
            normalizationRuleID: provenance.normalizationRuleID,
            normalizationRuleVersion: provenance.normalizationRuleVersion,
            hostScope: provenance.hostScope,
            rawReferenceDigest: nil
        )
        let details = try JSONEncoder.horizon2.encode(structuralProvenance)
        let id = EvidenceIdentityDigest.make(
            scope: "sqlite-provenance",
            material: [String(bytes: details, encoding: .utf8) ?? ""]
        )!
        reset(statement: statement)
        bind(id, at: 1, to: statement)
        bind(provenance.sourceID.rawValue, at: 2, to: statement)
        bind(provenance.apiName, at: 3, to: statement)
        bind(provenance.apiVersion, at: 4, to: statement)
        bind(provenance.captureChannel, at: 5, to: statement)
        bind(provenance.sourceTimestampQuality.rawValue, at: 6, to: statement)
        bind(provenance.hostScope.rawValue, at: 7, to: statement)
        bind(Self.dateString(Date()), at: 8, to: statement)
        bind(String(bytes: details, encoding: .utf8) ?? "", at: 9, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE
        else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        return id
    }

    func insertAttributes(for observation: Observation) throws {
        let values = flattenedValues(observation)
        for (path, value) in values {
            guard let metadata = sensitivityMetadata(for: observation.sensitivity, path: path)
            else { throw EvidenceJournalError.invalidSensitivity(path) }
            let statement = try connection
                .prepare(
                    "INSERT INTO observation_attributes(" +
                        "observation_id, field_path, value_type, value_json, sensitivity, redaction_action) " +
                        "VALUES(?,?,?,?,?,?)"
                )
            defer { sqlite3_finalize(statement) }; bind(observation.id.uuidString, at: 1, to: statement); bind(
                path,
                at: 2,
                to: statement
            ); bind(value.typeName, at: 3, to: statement); try bind(
                String(bytes: value.deterministicData(), encoding: .utf8) ?? "",
                at: 4,
                to: statement
            ); bind(metadata.classification.rawValue, at: 5, to: statement); bind(
                metadata.pseudonymization.sqlAction,
                at: 6,
                to: statement
            ); guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        }
    }

    func insertAttributes(for observation: Observation, using statement: OpaquePointer) throws {
        for (path, value) in flattenedValues(observation) {
            guard let metadata = sensitivityMetadata(for: observation.sensitivity, path: path)
            else { throw EvidenceJournalError.invalidSensitivity(path) }
            reset(statement: statement)
            bind(observation.id.uuidString, at: 1, to: statement)
            bind(path, at: 2, to: statement)
            bind(value.typeName, at: 3, to: statement)
            try bind(String(bytes: value.deterministicData(), encoding: .utf8) ?? "", at: 4, to: statement)
            bind(metadata.classification.rawValue, at: 5, to: statement)
            bind(metadata.pseudonymization.sqlAction, at: 6, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        }
    }

    func insertRedactionMetadata(for observation: Observation) throws {
        for field in observation.sensitivity.fields {
            guard flattenedValues(observation)
                .contains(where: {
                    $0.0 == field.path.rawValue || $0.0.hasPrefix(field.path.rawValue.replacingOccurrences(
                        of: "[*]",
                        with: "["
                    ))
                }) else { continue }
            let statement = try connection
                .prepare(
                    "INSERT INTO redaction_metadata(" +
                        "redaction_id, observation_id, field_path, sensitivity, action, " +
                        "policy_version, pseudonym_scope, created_at_wall) VALUES(?,?,?,?,?,?,?,?)"
                )
            defer { sqlite3_finalize(statement) }; bind(UUID().uuidString, at: 1, to: statement); bind(
                observation.id.uuidString,
                at: 2,
                to: statement
            ); bind(field.path.rawValue, at: 3, to: statement); bind(
                field.classification.rawValue,
                at: 4,
                to: statement
            ); bind(field.pseudonymization.sqlAction, at: 5, to: statement); bind("1.0.0", at: 6, to: statement); bind(
                field.pseudonymization.scope,
                at: 7,
                to: statement
            ); bind(Self.dateString(Date()), at: 8, to: statement); guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        }
    }
}
