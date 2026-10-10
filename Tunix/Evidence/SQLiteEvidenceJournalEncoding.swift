import Foundation
import SQLite3

extension SQLiteEvidenceJournal {
    func insertRedactionMetadata(for observation: Observation, using statement: OpaquePointer) throws {
        for field in observation.sensitivity.fields {
            guard flattenedValues(observation)
                .contains(where: {
                    $0.0 == field.path.rawValue || $0.0.hasPrefix(field.path.rawValue.replacingOccurrences(
                        of: "[*]",
                        with: "["
                    ))
                }) else { continue }
            reset(statement: statement)
            bind(UUID().uuidString, at: 1, to: statement)
            bind(observation.id.uuidString, at: 2, to: statement)
            bind(field.path.rawValue, at: 3, to: statement)
            bind(field.classification.rawValue, at: 4, to: statement)
            bind(field.pseudonymization.sqlAction, at: 5, to: statement)
            bind("1.0.0", at: 6, to: statement)
            bind(field.pseudonymization.scope, at: 7, to: statement)
            bind(Self.dateString(Date()), at: 8, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE
            else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database)) }
        }
    }

    func reset(statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func validateSensitivity(_ observation: Observation) throws {
        if observation.subject.identityDigest != nil, sensitivityMetadata(
            for: observation.sensitivity,
            path: "subject.identityDigest"
        ) == nil {
            throw EvidenceJournalError.invalidSensitivity("subject.identityDigest")
        }
        for (path, _) in flattenedValues(observation) where sensitivityMetadata(
            for: observation.sensitivity,
            path: path
        ) == nil {
            throw EvidenceJournalError.invalidSensitivity(path)
        }
        if let rawReferenceDigest = observation.provenance.rawReferenceDigest {
            guard rawReferenceDigest.count == 64,
                  rawReferenceDigest.allSatisfy({ $0.isHexDigit }),
                  sensitivityMetadata(for: observation.sensitivity, path: "provenance.rawReferenceDigest") != nil
            else {
                throw EvidenceJournalError.invalidSensitivity("provenance.rawReferenceDigest")
            }
        }
    }

    func validateHealthDetail(_ detail: String?) throws {
        guard let detail else { return }
        let lower = detail.lowercased()
        let prohibited = [
            "/users/",
            "ssid",
            "mac address",
            "hardware uuid",
            "hardware_uuid",
            "serial",
            "username",
            "ip address",
            "192.0.2.",
            "aa:bb:cc:dd:ee:ff"
        ]
        guard detail.count <= 512,
              !prohibited.contains(where: lower.contains)
        else { throw EvidenceJournalError.invalidSensitivity("health.detail") }
    }

    func deleteExpiredObservations(before cutoff: String) throws {
        while true {
            try connection.exec("BEGIN IMMEDIATE")
            do {
                let statement = try connection
                    .prepare(
                        "DELETE FROM observations WHERE observation_id IN (" +
                            "SELECT o.observation_id FROM observations o WHERE o.observed_wall < '\(cutoff)' " +
                            "AND NOT EXISTS (SELECT 1 FROM incident_observations i " +
                            "WHERE i.observation_id=o.observation_id) " +
                            "AND NOT EXISTS (SELECT 1 FROM evidence_members e " +
                            "WHERE e.observation_id=o.observation_id) " +
                            "AND NOT EXISTS (SELECT 1 FROM evidence_reasons r " +
                            "WHERE r.observation_id=o.observation_id) " +
                            "AND NOT EXISTS (SELECT 1 FROM inference_support s " +
                            "WHERE s.observation_id=o.observation_id) " +
                            "AND NOT EXISTS (SELECT 1 FROM inference_contradictions c " +
                            "WHERE c.observation_id=o.observation_id) " +
                            "ORDER BY o.observed_wall,o.observation_id LIMIT \(retentionBatchSize))"
                    )
                defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_DONE
                else { throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }; let count = sqlite3_changes(connection.database); try connection.exec("COMMIT"); if count == 0 {
                    break
                }
            } catch { try? connection.exec("ROLLBACK"); throw error }
        }
        try checkpoint(force: true)
    }

    func deleteExpiredIncidents(before cutoff: String) throws {
        while true {
            try connection.exec("BEGIN IMMEDIATE")
            do {
                let statement = try connection
                    .prepare(
                        "DELETE FROM incidents WHERE incident_id IN (" +
                            "SELECT incident_id FROM incidents WHERE completed_at_wall IS NOT NULL " +
                            "AND completed_at_wall < ? AND status='COMPLETE' AND retention_protected=0 " +
                            "ORDER BY completed_at_wall,incident_id LIMIT ?)"
                    )
                defer { sqlite3_finalize(statement) }
                bind(cutoff, at: 1, to: statement)
                bind(Int64(retentionBatchSize), at: 2, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.database))
                }
                let count = sqlite3_changes(connection.database)
                try connection.exec("COMMIT")
                if count == 0 {
                    break
                }
            } catch {
                try? connection.exec("ROLLBACK")
                throw error
            }
        }
        try checkpoint(force: true)
    }

    func oldestEvictableIncident() throws -> UUID? {
        let statement = try connection
            .prepare(
                "SELECT incident_id FROM incidents WHERE status='COMPLETE' AND retention_protected=0 " +
                    "ORDER BY completed_at_wall,incident_id LIMIT 1"
            ); defer {
            sqlite3_finalize(statement)
        }; guard sqlite3_step(statement) == SQLITE_ROW
        else { return nil }; return UUID(uuidString: String(cString: sqlite3_column_text(
            statement,
            0
        )))
    }

    func currentError() -> EvidenceJournalError {
        availabilityState == .capacityUnavailable ? .capacityUnavailable : .unavailable
    }

    func scalarRows(_ sql: String) throws -> [String] {
        let statement = try connection
            .prepare(sql); defer { sqlite3_finalize(statement)
        }; var rows: [String] = []; while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)))
        }; return rows
    }

    func decodeObservation(_ json: String) -> Observation? {
        try? JSONDecoder.horizon2.decode(Observation.self, from: Data(json.utf8))
    }

    func detailsJSON(_ detail: String?) throws -> String {
        let object: [String: EvidenceValue] = detail.map { ["category": .string($0)] } ?? [:]; return try String(
            bytes: JSONEncoder.horizon2.encode(EvidenceValue.object(object)),
            encoding: .utf8
        ) ?? ""
    }

    func detail(from json: String) -> String? {
        guard let value = try? JSONDecoder.horizon2.decode(EvidenceValue.self, from: Data(json.utf8)),
              case let .object(object) = value,
              case let .string(detail) = object["category"] else { return nil }; return detail
    }

    static func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent(); try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        ); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func protectJournalFiles() throws {
        try Self.protectJournalFiles(for: databaseURL)
    }

    static func protectJournalFiles(for databaseURL: URL) throws {
        let fileManager = FileManager.default
        // swiftformat:disable trailingCommas
        let sidecars = [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        // swiftformat:enable trailingCommas
        for url in sidecars where fileManager.fileExists(atPath: url.path) {
            try Self.applyFileProtection(to: url)
        }
    }

    var walURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    var shmURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-shm")
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        dateFormatter.date(from: string)
    }

    static func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ value: Int64?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(_ value: String?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value, at: Int32(index), to: statement)
    }

    func bind(_ value: Int64?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value, at: Int32(index), to: statement)
    }

    func bind(_ value: UInt64?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value.map(Int64.init), at: Int32(index), to: statement)
    }

    static func mapSQLiteError(_ code: Int32) -> EvidenceJournalError {
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_FULL, SQLITE_IOERR: return .capacityUnavailable
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .corruption
        default: return .unavailable
        }
    }
}
