// swiftlint:disable file_length
// swiftlint:disable line_length type_body_length function_body_length cyclomatic_complexity
// swiftlint:disable identifier_name optional_data_string_conversion switch_case_alignment
import Foundation
import SQLite3

private final class SQLiteConnection {
    let url: URL
    let db: OpaquePointer
    private var closed = false

    init(url: URL, injectMigrationFailure: Bool = false) throws {
        self.url = url
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw EvidenceJournalError.unavailable
        }
        db = opened
        do {
            try configure()
            try bootstrapOrMigrate(injectMigrationFailure: injectMigrationFailure)
            try verifyIntegrity()
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        sqlite3_close_v2(db)
    }

    deinit { close() }

    func configure() throws {
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=250")
        try exec("PRAGMA synchronous=FULL")
        try exec("PRAGMA secure_delete=ON")
        let mode = try scalar("PRAGMA journal_mode=WAL")
        guard mode.lowercased() == "wal" else { throw EvidenceJournalError.unavailable }
        guard try scalar("PRAGMA foreign_keys") == "1" else { throw EvidenceJournalError.unavailable }
        guard try scalar("PRAGMA secure_delete").lowercased() == "1" else { throw EvidenceJournalError.unavailable }
    }

    func bootstrapOrMigrate(injectMigrationFailure: Bool) throws {
        let userVersion = try Int(scalar("PRAGMA user_version")) ?? -1
        guard userVersion >= 0 else { throw EvidenceJournalError.corruption }
        if userVersion > Horizon2EvidenceConfiguration.sqliteSchemaVersion {
            throw EvidenceJournalError.incompatibleSchema
        }

        if userVersion == 0 {
            try exec("BEGIN IMMEDIATE")
            do {
                if injectMigrationFailure {
                    throw EvidenceJournalError.unavailable
                }
                try createSchemaV1()
                try exec("PRAGMA user_version=1")
                try insertMetadata(key: "schema_version", value: "1")
                try insertMetadata(key: "observation_schema_version", value: "1")
                try insertMetadata(key: "redaction_policy_version", value: "1.0.0")
                try insertMetadata(key: "journal_created_at", value: SQLiteEvidenceJournal.dateString(Date()))
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }

        guard try scalar("SELECT value FROM schema_metadata WHERE key='schema_version' LIMIT 1") == "1",
              try Int(scalar("PRAGMA user_version")) == Horizon2EvidenceConfiguration.sqliteSchemaVersion
        else {
            throw EvidenceJournalError.schemaMetadataMismatch
        }
    }

    func verifyIntegrity() throws {
        guard try scalar("PRAGMA integrity_check") == "ok" else { throw EvidenceJournalError.corruption }
    }

    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else { throw SQLiteEvidenceJournal.mapSQLiteError(result) }
    }

    func scalar(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteEvidenceJournal.mapSQLiteError(sqlite3_errcode(db)) }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw SQLiteEvidenceJournal.mapSQLiteError(result) }
        return statement
    }

    private func insertMetadata(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO schema_metadata(key,value,updated_at_wall) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        SQLiteEvidenceJournal.bind(key, at: 1, to: statement)
        SQLiteEvidenceJournal.bind(value, at: 2, to: statement)
        SQLiteEvidenceJournal.bind(SQLiteEvidenceJournal.dateString(Date()), at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteEvidenceJournal.mapSQLiteError(sqlite3_errcode(db)) }
    }

    private func createSchemaV1() throws {
        try exec("""
        CREATE TABLE schema_metadata(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at_wall TEXT NOT NULL
        );
        CREATE TABLE subjects(
            subject_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            subject_type TEXT NOT NULL,
            identity_digest TEXT,
            identity_quality TEXT NOT NULL,
            first_observed_wall TEXT NOT NULL,
            last_observed_wall TEXT NOT NULL,
            created_at_wall TEXT NOT NULL,
            UNIQUE(source_id, subject_type, identity_digest)
        );
        CREATE TABLE provenance(
            provenance_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            api_name TEXT NOT NULL,
            api_version TEXT,
            capture_channel TEXT NOT NULL,
            source_timestamp_quality TEXT NOT NULL,
            host_scope TEXT NOT NULL,
            created_at_wall TEXT NOT NULL,
            details_json TEXT NOT NULL
        );
        CREATE TABLE observations(
            observation_id TEXT PRIMARY KEY,
            domain TEXT NOT NULL,
            event_kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            subject_id TEXT REFERENCES subjects(subject_id) ON DELETE SET NULL,
            provenance_id TEXT NOT NULL REFERENCES provenance(provenance_id),
            observed_wall TEXT NOT NULL,
            observed_continuous_ns INTEGER,
            observed_monotonic_ns INTEGER,
            boot_session_id TEXT,
            process_run_id TEXT NOT NULL,
            local_sequence INTEGER NOT NULL,
            correlation_epoch_id TEXT NOT NULL,
            timestamp_quality TEXT NOT NULL,
            quality TEXT NOT NULL,
            canonical_value_json TEXT NOT NULL,
            created_at_wall TEXT NOT NULL
        );
        CREATE TABLE observation_attributes(
            observation_id TEXT NOT NULL REFERENCES observations(observation_id) ON DELETE CASCADE,
            field_path TEXT NOT NULL,
            value_type TEXT NOT NULL,
            value_json TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            redaction_action TEXT NOT NULL,
            PRIMARY KEY(observation_id, field_path)
        );
        CREATE TABLE source_health_or_suppression(
            record_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            observation_id TEXT REFERENCES observations(observation_id) ON DELETE SET NULL,
            record_kind TEXT NOT NULL,
            reason_code TEXT NOT NULL,
            suppressed_count INTEGER NOT NULL,
            first_observed_wall TEXT NOT NULL,
            last_observed_wall TEXT NOT NULL,
            details_json TEXT NOT NULL
        );
        CREATE TABLE incidents(
            incident_id TEXT PRIMARY KEY,
            marker_observation_id TEXT REFERENCES observations(observation_id) ON DELETE SET NULL,
            marker_wall TEXT NOT NULL,
            pre_window_seconds INTEGER NOT NULL,
            post_window_seconds INTEGER NOT NULL,
            status TEXT NOT NULL,
            schema_version INTEGER NOT NULL,
            created_at_wall TEXT NOT NULL,
            completed_at_wall TEXT,
            failure_reason TEXT,
            retention_protected INTEGER NOT NULL DEFAULT 0 CHECK(retention_protected IN (0,1)),
            package_json TEXT
        );
        CREATE TABLE incident_observations(
            incident_id TEXT NOT NULL REFERENCES incidents(incident_id) ON DELETE CASCADE,
            observation_id TEXT NOT NULL REFERENCES observations(observation_id) ON DELETE RESTRICT,
            membership_role TEXT NOT NULL,
            PRIMARY KEY(incident_id, observation_id)
        );
        CREATE TABLE incident_context(
            context_id TEXT PRIMARY KEY,
            incident_id TEXT NOT NULL REFERENCES incidents(incident_id) ON DELETE CASCADE,
            context_kind TEXT NOT NULL,
            observed_wall TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            sensitivity_policy TEXT NOT NULL,
            immutable INTEGER NOT NULL CHECK(immutable=1)
        );
        CREATE TABLE evidence_sets(
            evidence_set_id TEXT PRIMARY KEY,
            incident_id TEXT NOT NULL REFERENCES incidents(incident_id) ON DELETE CASCADE,
            rule_id TEXT,
            rule_version TEXT,
            window_start_wall TEXT NOT NULL,
            window_end_wall TEXT NOT NULL,
            order_quality TEXT NOT NULL,
            created_at_wall TEXT NOT NULL,
            schema_version INTEGER NOT NULL
        );
        CREATE TABLE evidence_members(
            evidence_set_id TEXT NOT NULL REFERENCES evidence_sets(evidence_set_id) ON DELETE CASCADE,
            observation_id TEXT NOT NULL REFERENCES observations(observation_id) ON DELETE RESTRICT,
            membership_role TEXT NOT NULL,
            PRIMARY KEY(evidence_set_id, observation_id)
        );
        CREATE TABLE evidence_reasons(
            reason_id TEXT PRIMARY KEY,
            evidence_set_id TEXT NOT NULL REFERENCES evidence_sets(evidence_set_id) ON DELETE CASCADE,
            observation_id TEXT REFERENCES observations(observation_id) ON DELETE RESTRICT,
            reason_code TEXT NOT NULL,
            reason_json TEXT NOT NULL,
            rule_id TEXT,
            rule_version TEXT NOT NULL
        );
        CREATE TABLE inferences(
            inference_id TEXT PRIMARY KEY,
            evidence_set_id TEXT NOT NULL REFERENCES evidence_sets(evidence_set_id) ON DELETE CASCADE,
            rule_id TEXT NOT NULL,
            rule_version TEXT NOT NULL,
            evidence_class TEXT NOT NULL,
            output_json TEXT NOT NULL,
            created_at_wall TEXT NOT NULL
        );
        CREATE TABLE inference_support(
            inference_id TEXT NOT NULL REFERENCES inferences(inference_id) ON DELETE CASCADE,
            observation_id TEXT NOT NULL REFERENCES observations(observation_id) ON DELETE RESTRICT,
            support_kind TEXT NOT NULL,
            PRIMARY KEY(inference_id, observation_id, support_kind)
        );
        CREATE TABLE inference_contradictions(
            inference_id TEXT NOT NULL REFERENCES inferences(inference_id) ON DELETE CASCADE,
            observation_id TEXT NOT NULL REFERENCES observations(observation_id) ON DELETE RESTRICT,
            contradiction_kind TEXT NOT NULL,
            details_json TEXT NOT NULL,
            PRIMARY KEY(inference_id, observation_id, contradiction_kind)
        );
        CREATE TABLE next_test_references(
            inference_id TEXT NOT NULL REFERENCES inferences(inference_id) ON DELETE CASCADE,
            catalog_id TEXT NOT NULL,
            catalog_version TEXT NOT NULL,
            purpose TEXT NOT NULL,
            evidence_expected TEXT NOT NULL,
            prerequisites_json TEXT NOT NULL,
            risk_class TEXT NOT NULL,
            user_action TEXT NOT NULL,
            stopping_condition TEXT NOT NULL,
            expected_observations TEXT NOT NULL,
            safety_warning TEXT NOT NULL,
            catalog_provenance TEXT NOT NULL,
            PRIMARY KEY(inference_id, catalog_id, catalog_version)
        );
        CREATE TABLE redaction_metadata(
            redaction_id TEXT PRIMARY KEY,
            observation_id TEXT REFERENCES observations(observation_id) ON DELETE CASCADE,
            incident_id TEXT REFERENCES incidents(incident_id) ON DELETE CASCADE,
            evidence_set_id TEXT REFERENCES evidence_sets(evidence_set_id) ON DELETE CASCADE,
            inference_id TEXT REFERENCES inferences(inference_id) ON DELETE CASCADE,
            field_path TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            action TEXT NOT NULL,
            policy_version TEXT NOT NULL,
            pseudonym_scope TEXT,
            created_at_wall TEXT NOT NULL,
            CHECK((observation_id IS NOT NULL)+(incident_id IS NOT NULL)+(evidence_set_id IS NOT NULL)+(inference_id IS NOT NULL)=1)
        );
        CREATE INDEX observations_by_time ON observations(observed_wall, local_sequence, observation_id);
        CREATE INDEX observations_by_source_time ON observations(source_id, observed_wall, local_sequence, observation_id);
        CREATE INDEX observations_by_subject_time ON observations(subject_id, observed_wall, local_sequence, observation_id);
        CREATE INDEX subjects_by_identity ON subjects(identity_digest, subject_id);
        CREATE INDEX observations_by_process_sequence ON observations(process_run_id, local_sequence);
        CREATE INDEX observations_by_provenance ON observations(provenance_id);
        CREATE INDEX attributes_by_path_sensitivity ON observation_attributes(field_path, sensitivity);
        CREATE INDEX health_by_source_time ON source_health_or_suppression(source_id, last_observed_wall, record_id);
        CREATE INDEX incident_membership_by_observation ON incident_observations(observation_id);
        CREATE INDEX evidence_members_by_observation ON evidence_members(observation_id);
        CREATE INDEX inference_support_by_observation ON inference_support(observation_id);
        CREATE INDEX evidence_reasons_by_set_reason ON evidence_reasons(evidence_set_id, reason_code);
        CREATE INDEX inferences_by_set_rule ON inferences(evidence_set_id, rule_id, rule_version);
        CREATE INDEX redaction_by_path_policy ON redaction_metadata(field_path, policy_version);
        """)
    }
}

actor SQLiteEvidenceJournal: EvidenceJournal {
    let databaseURL: URL
    private let connection: SQLiteConnection
    private var maximumJournalBytes: Int
    private let transactionalHeadroomBytes: Int
    private let retentionBatchSize: Int
    private let retentionDays: Int
    private var availabilityState: EvidenceJournalAvailability = .available
    // Once retention has proved that the journal cannot currently make room,
    // queued writers fail promptly until an explicit recovery operation.
    private var capacityRecoveryBlocked = false
    private var appendsSinceCheckpoint = 0
    #if HORIZON2_MEASUREMENT
        private var measurementAppendTimings: [Horizon2MeasurementAppendTiming] = []
        private var measurementTransactionCount = 0
        private var measurementMinimumTransactionBaselineBytes = Int.max
        private var measurementMaximumTransactionBaselineBytes = 0
        private var measurementMaximumTransactionPeakBytes = 0
        private var measurementMaximumTransactionDeltaBytes = 0
    #endif

    init(
        databaseURL: URL = Horizon2JournalFactory.defaultDatabaseURL,
        retentionDays: Int = Horizon2EvidenceConfiguration.defaultRetentionDays,
        maximumJournalBytes: Int = Horizon2EvidenceConfiguration.maximumJournalBytes,
        transactionalHeadroomBytes: Int = Horizon2EvidenceConfiguration.transactionalHeadroomBytes,
        retentionBatchSize: Int = 100,
        injectMigrationFailure: Bool = false
    ) throws {
        guard (1 ... Horizon2EvidenceConfiguration.maximumRetentionDays).contains(retentionDays),
              maximumJournalBytes > 0,
              transactionalHeadroomBytes > 0
        else { throw EvidenceJournalError.unavailable }
        self.databaseURL = databaseURL.standardizedFileURL
        self.maximumJournalBytes = maximumJournalBytes
        self.transactionalHeadroomBytes = transactionalHeadroomBytes
        self.retentionBatchSize = max(1, retentionBatchSize)
        self.retentionDays = retentionDays
        try Self.prepareDirectory(for: self.databaseURL)
        connection = try SQLiteConnection(url: self.databaseURL, injectMigrationFailure: injectMigrationFailure)
        try Self.applyFileProtection(to: self.databaseURL)
        try Self.protectJournalFiles(for: self.databaseURL)
    }

    func append(_ observation: Observation) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        if availabilityState == .capacityUnavailable {
            guard !capacityRecoveryBlocked else { throw currentError() }
            _ = try performRetention()
            guard availabilityState == .available else { throw currentError() }
        }
        #if HORIZON2_MEASUREMENT
            let totalAppendStart = DispatchTime.now().uptimeNanoseconds
            var validationEncodingMilliseconds = 0.0
            var capacityCheckMilliseconds = 0.0
            var transactionBeginMilliseconds = 0.0
            var subjectProvenanceMilliseconds = 0.0
            var rowAttributeRedactionInsertMilliseconds = 0.0
            var commitMilliseconds = 0.0
            var checkpointMilliseconds = 0.0
            var fileProtectionMilliseconds = 0.0
        #endif
        #if HORIZON2_MEASUREMENT
            let validationEncodingStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let canonical = try observation.deterministicData()
        try validateSensitivity(observation)
        #if HORIZON2_MEASUREMENT
            validationEncodingMilliseconds = measurementMilliseconds(since: validationEncodingStart)
        #endif
        guard canonical.count <= transactionalHeadroomBytes else { throw EvidenceJournalError.oversizedRecord }
        #if HORIZON2_MEASUREMENT
            let capacityCheckStart = DispatchTime.now().uptimeNanoseconds
        #endif
        try ensureCapacity(for: canonical.count + 8192)
        #if HORIZON2_MEASUREMENT
            capacityCheckMilliseconds = measurementMilliseconds(since: capacityCheckStart)
            let transactionBaselineBytes = stableFootprintBytes()
            var transactionPeakBytes = transactionBaselineBytes
            let transactionBeginStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let db = connection.db
        var insertedSubjectID: String?
        var insertedProvenanceID: String?
        try connection.exec("BEGIN IMMEDIATE")
        #if HORIZON2_MEASUREMENT
            transactionBeginMilliseconds = measurementMilliseconds(since: transactionBeginStart)
            let subjectProvenanceStart = DispatchTime.now().uptimeNanoseconds
        #endif
        do {
            if let existing = try existingCanonical(id: observation.id) {
                guard existing == canonical else { throw EvidenceJournalError.observationPayloadMismatch }
                try connection.exec("COMMIT")
                #if HORIZON2_MEASUREMENT
                    measurementAppendTimings.append(Horizon2MeasurementAppendTiming(
                        validationEncodingMilliseconds: validationEncodingMilliseconds,
                        capacityCheckMilliseconds: capacityCheckMilliseconds,
                        transactionBeginMilliseconds: transactionBeginMilliseconds,
                        subjectProvenanceMilliseconds: 0,
                        rowAttributeRedactionInsertMilliseconds: 0,
                        commitMilliseconds: 0,
                        checkpointMilliseconds: 0,
                        fileProtectionMilliseconds: 0,
                        totalAppendMilliseconds: measurementMilliseconds(since: totalAppendStart)
                    ))
                #endif
                return
            }
            let subjectID = try upsertSubject(observation)
            let provenanceID = try upsertProvenance(observation.provenance)
            insertedSubjectID = subjectID
            insertedProvenanceID = provenanceID
            #if HORIZON2_MEASUREMENT
                subjectProvenanceMilliseconds = measurementMilliseconds(since: subjectProvenanceStart)
                let insertStart = DispatchTime.now().uptimeNanoseconds
            #endif
            let statement = try connection.prepare("""
                INSERT INTO observations(observation_id,domain,event_kind,source_id,subject_id,provenance_id,
                observed_wall,observed_continuous_ns,observed_monotonic_ns,boot_session_id,process_run_id,
                local_sequence,correlation_epoch_id,timestamp_quality,quality,canonical_value_json,created_at_wall)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(observation.id.uuidString, at: 1, to: statement)
            bind(observation.domain.sqlValue, at: 2, to: statement)
            bind(observation.eventKind.sqlValue, at: 3, to: statement)
            bind(observation.sourceID.rawValue, at: 4, to: statement)
            bind(subjectID, at: 5, to: statement)
            bind(provenanceID, at: 6, to: statement)
            bind(Self.dateString(observation.time.observedWallTime), at: 7, to: statement)
            bind(observation.time.continuousNanoseconds, at: 8, to: statement)
            bind(observation.time.processUptimeNanoseconds, at: 9, to: statement)
            bind(observation.time.bootSessionID, at: 10, to: statement)
            bind(observation.time.processRunID.uuidString, at: 11, to: statement)
            bind(observation.time.localSequence, at: 12, to: statement)
            bind(observation.time.correlationEpochID.uuidString, at: 13, to: statement)
            bind(observation.time.sourceTimestampQuality.rawValue, at: 14, to: statement)
            bind(observation.availability.sqlValue, at: 15, to: statement)
            bind(String(decoding: canonical, as: UTF8.self), at: 16, to: statement)
            bind(Self.dateString(Date()), at: 17, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(db)) }
            try insertAttributes(for: observation)
            try insertRedactionMetadata(for: observation)
            #if HORIZON2_MEASUREMENT
                transactionPeakBytes = max(transactionPeakBytes, stableFootprintBytes())
                rowAttributeRedactionInsertMilliseconds = measurementMilliseconds(since: insertStart)
                let commitStart = DispatchTime.now().uptimeNanoseconds
            #endif
            try connection.exec("COMMIT")
            #if HORIZON2_MEASUREMENT
                transactionPeakBytes = max(transactionPeakBytes, stableFootprintBytes())
                measurementRecordTransaction(
                    baselineBytes: transactionBaselineBytes,
                    peakBytes: transactionPeakBytes
                )
                commitMilliseconds = measurementMilliseconds(since: commitStart)
            #endif
        } catch {
            try? connection.exec("ROLLBACK")
            if let journalError = error as? EvidenceJournalError {
                throw journalError
            }
            let mapped = Self.mapSQLiteError(sqlite3_errcode(db))
            if mapped == .capacityUnavailable {
                markCapacityUnavailable()
            }
            throw mapped
        }
        do {
            appendsSinceCheckpoint += 1
            #if HORIZON2_MEASUREMENT
                let checkpointStart = DispatchTime.now().uptimeNanoseconds
            #endif
            _ = try maybeCheckpoint(protect: false)
            #if HORIZON2_MEASUREMENT
                checkpointMilliseconds = measurementMilliseconds(since: checkpointStart)
            #endif
            #if HORIZON2_MEASUREMENT
                let fileProtectionStart = DispatchTime.now().uptimeNanoseconds
            #endif
            try protectJournalFiles()
            #if HORIZON2_MEASUREMENT
                fileProtectionMilliseconds = measurementMilliseconds(since: fileProtectionStart)
            #endif
            guard stableFootprintBytes() <= maximumJournalBytes else {
                throw EvidenceJournalError.capacityUnavailable
            }
            #if HORIZON2_MEASUREMENT
                measurementAppendTimings.append(Horizon2MeasurementAppendTiming(
                    validationEncodingMilliseconds: validationEncodingMilliseconds,
                    capacityCheckMilliseconds: capacityCheckMilliseconds,
                    transactionBeginMilliseconds: transactionBeginMilliseconds,
                    subjectProvenanceMilliseconds: subjectProvenanceMilliseconds,
                    rowAttributeRedactionInsertMilliseconds: rowAttributeRedactionInsertMilliseconds,
                    commitMilliseconds: commitMilliseconds,
                    checkpointMilliseconds: checkpointMilliseconds,
                    fileProtectionMilliseconds: fileProtectionMilliseconds,
                    totalAppendMilliseconds: measurementMilliseconds(since: totalAppendStart)
                ))
            #endif
        } catch {
            do {
                try removeRejectedObservation(
                    observationID: observation.id,
                    subjectID: insertedSubjectID,
                    provenanceID: insertedProvenanceID
                )
            } catch {
                availabilityState = .unavailable
                throw EvidenceJournalError.unavailable
            }
            if (error as? EvidenceJournalError) == .capacityUnavailable {
                markCapacityUnavailable()
            }
            try reclaimPhysicalSpaceAfterRejectedMutation()
            throw error
        }
    }

    /// Persists a bounded group of immutable observations in one SQLite
    /// transaction. The caller applies the same batching policy, but this
    /// durable boundary independently validates the aggregate before BEGIN.
    /// The async signature is intentional: it is the concrete witness for
    /// EvidenceJournal.appendBatch rather than the protocol's per-record
    /// fallback implementation.
    func appendBatch(_ observations: [Observation]) async throws {
        guard !observations.isEmpty else { return }
        guard availabilityState != .unavailable else { throw currentError() }
        if availabilityState == .capacityUnavailable {
            guard !capacityRecoveryBlocked else { throw currentError() }
            _ = try performRetention()
            guard availabilityState == .available else { throw currentError() }
        }

        let entries = try observations.map { observation in
            let canonical = try observation.deterministicData()
            try validateSensitivity(observation)
            guard canonical.count <= transactionalHeadroomBytes else { throw EvidenceJournalError.oversizedRecord }
            return (observation, canonical)
        }
        let aggregateCanonicalBytes = entries.reduce(0) { $0 + $1.1.count }
        guard Horizon2EvidenceConfiguration.batchFits(
            count: entries.count,
            canonicalPayloadBytes: aggregateCanonicalBytes,
            headroomBytes: transactionalHeadroomBytes
        )
        else {
            throw EvidenceJournalError.oversizedRecord
        }
        if observations.count == 1 {
            try append(observations[0])
            return
        }
        // Resolve all existing IDs before opening the write transaction. This
        // keeps an idempotency mismatch from ever occurring after a new member
        // of the same batch has been inserted.
        for (observation, canonical) in entries {
            if let existing = try existingCanonical(id: observation.id) {
                guard existing == canonical else { throw EvidenceJournalError.observationPayloadMismatch }
            }
        }
        try ensureCapacity(
            for: aggregateCanonicalBytes
                + entries.count * Horizon2EvidenceConfiguration.batchFixedOverheadBytes
        )
        let db = connection.db
        // swiftlint:disable:next large_tuple
        var inserted: [(observationID: UUID, subjectID: String, provenanceID: String)] = []
        #if HORIZON2_MEASUREMENT
            let totalAppendStart = DispatchTime.now().uptimeNanoseconds
            let transactionBaselineBytes = stableFootprintBytes()
            var transactionPeakBytes = transactionBaselineBytes
        #endif
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let subjectStatement = try connection.prepare("INSERT INTO subjects(subject_id,source_id,subject_type,identity_digest,identity_quality,first_observed_wall,last_observed_wall,created_at_wall) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(subject_id) DO UPDATE SET last_observed_wall=excluded.last_observed_wall")
            defer { sqlite3_finalize(subjectStatement) }
            let provenanceStatement = try connection.prepare("INSERT OR IGNORE INTO provenance(provenance_id,source_id,api_name,api_version,capture_channel,source_timestamp_quality,host_scope,created_at_wall,details_json) VALUES(?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(provenanceStatement) }
            let observationStatement = try connection.prepare("""
                INSERT INTO observations(observation_id,domain,event_kind,source_id,subject_id,provenance_id,
                observed_wall,observed_continuous_ns,observed_monotonic_ns,boot_session_id,process_run_id,
                local_sequence,correlation_epoch_id,timestamp_quality,quality,canonical_value_json,created_at_wall)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(observationStatement) }
            let attributeStatement = try connection.prepare("INSERT INTO observation_attributes(observation_id,field_path,value_type,value_json,sensitivity,redaction_action) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(attributeStatement) }
            let redactionStatement = try connection.prepare("INSERT INTO redaction_metadata(redaction_id,observation_id,field_path,sensitivity,action,policy_version,pseudonym_scope,created_at_wall) VALUES(?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(redactionStatement) }
            for (observation, canonical) in entries {
                if let existing = try existingCanonical(id: observation.id) {
                    guard existing == canonical else { throw EvidenceJournalError.observationPayloadMismatch }
                    continue
                }
                let subjectID = try upsertSubject(observation, using: subjectStatement)
                let provenanceID = try upsertProvenance(observation.provenance, using: provenanceStatement)
                reset(statement: observationStatement)
                bind(observation.id.uuidString, at: 1, to: observationStatement)
                bind(observation.domain.sqlValue, at: 2, to: observationStatement)
                bind(observation.eventKind.sqlValue, at: 3, to: observationStatement)
                bind(observation.sourceID.rawValue, at: 4, to: observationStatement)
                bind(subjectID, at: 5, to: observationStatement)
                bind(provenanceID, at: 6, to: observationStatement)
                bind(Self.dateString(observation.time.observedWallTime), at: 7, to: observationStatement)
                bind(observation.time.continuousNanoseconds, at: 8, to: observationStatement)
                bind(observation.time.processUptimeNanoseconds, at: 9, to: observationStatement)
                bind(observation.time.bootSessionID, at: 10, to: observationStatement)
                bind(observation.time.processRunID.uuidString, at: 11, to: observationStatement)
                bind(observation.time.localSequence, at: 12, to: observationStatement)
                bind(observation.time.correlationEpochID.uuidString, at: 13, to: observationStatement)
                bind(observation.time.sourceTimestampQuality.rawValue, at: 14, to: observationStatement)
                bind(observation.availability.sqlValue, at: 15, to: observationStatement)
                bind(String(decoding: canonical, as: UTF8.self), at: 16, to: observationStatement)
                bind(Self.dateString(Date()), at: 17, to: observationStatement)
                guard sqlite3_step(observationStatement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(db)) }
                try insertAttributes(for: observation, using: attributeStatement)
                try insertRedactionMetadata(for: observation, using: redactionStatement)
                inserted.append((observation.id, subjectID, provenanceID))
                #if HORIZON2_MEASUREMENT
                    transactionPeakBytes = max(transactionPeakBytes, stableFootprintBytes())
                #endif
            }
            try connection.exec("COMMIT")
            #if HORIZON2_MEASUREMENT
                transactionPeakBytes = max(transactionPeakBytes, stableFootprintBytes())
                measurementRecordTransaction(
                    baselineBytes: transactionBaselineBytes,
                    peakBytes: transactionPeakBytes
                )
            #endif
        } catch {
            try? connection.exec("ROLLBACK")
            if let journalError = error as? EvidenceJournalError {
                throw journalError
            }
            throw Self.mapSQLiteError(sqlite3_errcode(db))
        }

        do {
            appendsSinceCheckpoint += inserted.count
            _ = try maybeCheckpoint(protect: false)
            try protectJournalFiles()
            guard stableFootprintBytes() <= maximumJournalBytes else {
                throw EvidenceJournalError.capacityUnavailable
            }
            #if HORIZON2_MEASUREMENT
                measurementAppendTimings.append(Horizon2MeasurementAppendTiming(
                    validationEncodingMilliseconds: 0,
                    capacityCheckMilliseconds: 0,
                    transactionBeginMilliseconds: 0,
                    subjectProvenanceMilliseconds: 0,
                    rowAttributeRedactionInsertMilliseconds: 0,
                    commitMilliseconds: 0,
                    checkpointMilliseconds: 0,
                    fileProtectionMilliseconds: 0,
                    totalAppendMilliseconds: measurementMilliseconds(since: totalAppendStart)
                ))
            #endif
        } catch {
            do {
                try removeRejectedObservations(inserted)
            } catch {
                availabilityState = .unavailable
                throw EvidenceJournalError.unavailable
            }
            if (error as? EvidenceJournalError) == .capacityUnavailable {
                markCapacityUnavailable()
            }
            try reclaimPhysicalSpaceAfterRejectedMutation()
            throw error
        }
    }

    func observation(id: UUID) -> Observation? {
        guard availabilityState != .unavailable else { return nil }
        do {
            let statement = try connection.prepare("SELECT canonical_value_json FROM observations WHERE observation_id=?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeObservation(String(cString: sqlite3_column_text(statement, 0)))
        } catch { return nil }
    }

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
        let sql = "SELECT o.canonical_value_json FROM observations o LEFT JOIN subjects s ON s.subject_id=o.subject_id \(whereClause) ORDER BY o.observed_wall \(direction),o.local_sequence \(direction),o.observation_id \(direction)\(limitClause)"
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
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
            while try Int(connection.scalar("SELECT COUNT(*) FROM source_health_or_suppression")) ?? 0 > 4096 {
                let cleanup = try connection.prepare("DELETE FROM source_health_or_suppression WHERE record_id IN (SELECT record_id FROM source_health_or_suppression ORDER BY last_observed_wall ASC, record_id ASC LIMIT ?)")
                defer { sqlite3_finalize(cleanup) }
                bind(Int64(retentionBatchSize), at: 1, to: cleanup)
                guard sqlite3_step(cleanup) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
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
            let statement = try connection.prepare("SELECT record_id,source_id,observation_id,record_kind,reason_code,suppressed_count,last_observed_wall,details_json FROM source_health_or_suppression ORDER BY record_id")
            defer { sqlite3_finalize(statement) }
            var records: [EvidenceSourceHealthRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))),
                      let source = Horizon2SourceID(rawValue: String(cString: sqlite3_column_text(statement, 1))),
                      let event = EvidenceSourceHealthEvent(rawValue: String(cString: sqlite3_column_text(statement, 3))),
                      let reason = EvidenceUnknownReason(rawValue: String(cString: sqlite3_column_text(statement, 4))),
                      let date = Self.date(from: String(cString: sqlite3_column_text(statement, 6))) else { continue }
                let observationID = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : UUID(uuidString: String(cString: sqlite3_column_text(statement, 2)))
                records.append(EvidenceSourceHealthRecord(id: id, sourceID: source, observationID: observationID, event: event, reason: reason, suppressedCount: Int(sqlite3_column_int64(statement, 5)), observedAt: date, detail: detail(from: String(cString: sqlite3_column_text(statement, 7)))))
            }
            return records
        } catch { return [] }
    }

    func beginIncidentCapture(_ session: IncidentCaptureSession) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        let sessionJSON = try String(decoding: JSONEncoder.horizon2.encode(session), as: UTF8.self)
        try ensureCapacity(for: sessionJSON.utf8.count + session.observationIDs.count * 256 + 8192)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO incidents(incident_id,marker_observation_id,marker_wall,pre_window_seconds,post_window_seconds,status,schema_version,created_at_wall,completed_at_wall,failure_reason,retention_protected,package_json)
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
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
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
                if let session = try? JSONDecoder.horizon2.decode(IncidentCaptureSession.self, from: Data(payload.utf8)) {
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

    private func insertIncidentMembership(incidentID: UUID, observationIDs: [UUID]) throws {
        for observationID in observationIDs {
            let statement = try connection.prepare("INSERT OR IGNORE INTO incident_observations(incident_id,observation_id,membership_role) VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            bind(observationID.uuidString, at: 2, to: statement)
            bind("MEMBER", at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        }
    }

    private func insertIncidentContext(incidentID: UUID, observedAt: Date, kind: String, payload: String) throws {
        let context = try connection.prepare("INSERT OR REPLACE INTO incident_context(context_id,incident_id,context_kind,observed_wall,payload_json,sensitivity_policy,immutable) VALUES(?,?,?,?,?,?,1)")
        defer { sqlite3_finalize(context) }
        bind(incidentID.uuidString, at: 1, to: context)
        bind(incidentID.uuidString, at: 2, to: context)
        bind(kind, at: 3, to: context)
        bind(Self.dateString(observedAt), at: 4, to: context)
        bind(payload, at: 5, to: context)
        bind("LOCAL_ONLY", at: 6, to: context)
        guard sqlite3_step(context) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
    }

    func recordIncidentMembership(incidentID: UUID, observationIDs: [UUID]) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        try ensureCapacity(for: observationIDs.count * 256 + 8192)
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let incident = try connection.prepare("INSERT OR IGNORE INTO incidents(incident_id,marker_wall,pre_window_seconds,post_window_seconds,status,schema_version,created_at_wall) VALUES(?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(incident) }
            bind(incidentID.uuidString, at: 1, to: incident)
            bind(Self.dateString(Date()), at: 2, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPreWindowSeconds), at: 3, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPostWindowSeconds), at: 4, to: incident)
            bind(IncidentCaptureStatus.incomplete.rawValue, at: 5, to: incident)
            bind(Int64(Horizon2EvidenceConfiguration.incidentPackageSchemaVersion), at: 6, to: incident)
            bind(Self.dateString(Date()), at: 7, to: incident)
            guard sqlite3_step(incident) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
            try insertIncidentMembership(incidentID: incidentID, observationIDs: observationIDs)
            try connection.exec("COMMIT")
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    func incidentObservationIDs(incidentID: UUID) -> [UUID] {
        do {
            let statement = try connection.prepare("SELECT observation_id FROM incident_observations WHERE incident_id=? ORDER BY observation_id")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            var IDs: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) {
                IDs.append(id)
            }
            return IDs
        } catch { return [] }
    }

    func persistEvidenceSets(incidentID: UUID, sets: [EvidenceSet]) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        guard let incident = incident(id: incidentID), incident.status == .complete || incident.status == .incomplete else {
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
                    throw EvidenceJournalError.invalidCorrelationInput("Evidence set references an observation outside its incident package.")
                }
                if let existing = try loadEvidenceSet(id: set.id) {
                    guard try evidenceSetIncidentID(id: set.id) == incidentID else {
                        throw EvidenceJournalError.evidenceSetConflict(set.id)
                    }
                    guard existing == set else { throw EvidenceJournalError.evidenceSetConflict(set.id) }
                    continue
                }
                let insert = try connection.prepare("""
                    INSERT INTO evidence_sets(evidence_set_id,incident_id,rule_id,rule_version,window_start_wall,window_end_wall,order_quality,created_at_wall,schema_version)
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
                guard sqlite3_step(insert) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }

                for member in set.members {
                    let memberInsert = try connection.prepare("INSERT INTO evidence_members(evidence_set_id,observation_id,membership_role) VALUES(?,?,?)")
                    defer { sqlite3_finalize(memberInsert) }
                    bind(set.id.uuidString, at: 1, to: memberInsert)
                    bind(member.observationID.uuidString, at: 2, to: memberInsert)
                    bind("MEMBER", at: 3, to: memberInsert)
                    guard sqlite3_step(memberInsert) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
                    for reason in member.reasons {
                        let reasonInsert = try connection.prepare("INSERT INTO evidence_reasons(reason_id,evidence_set_id,observation_id,reason_code,reason_json,rule_id,rule_version) VALUES(?,?,?,?,?,?,?)")
                        defer { sqlite3_finalize(reasonInsert) }
                        bind(Self.evidenceReasonID(setID: set.id, observationID: member.observationID, reason: reason).uuidString, at: 1, to: reasonInsert)
                        bind(set.id.uuidString, at: 2, to: reasonInsert)
                        bind(member.observationID.uuidString, at: 3, to: reasonInsert)
                        bind(reason.stableCode, at: 4, to: reasonInsert)
                        try bind(String(decoding: JSONEncoder.horizon2.encode(reason), as: UTF8.self), at: 5, to: reasonInsert)
                        bind(set.ruleID, at: 6, to: reasonInsert)
                        bind(set.ruleVersion ?? "", at: 7, to: reasonInsert)
                        guard sqlite3_step(reasonInsert) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
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
            let statement = try connection.prepare("SELECT evidence_set_id FROM evidence_sets WHERE incident_id=? ORDER BY evidence_set_id")
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

    private func loadEvidenceSet(id: UUID) throws -> EvidenceSet? {
        let setStatement = try connection.prepare("SELECT rule_id,rule_version,window_start_wall,window_end_wall,order_quality,schema_version FROM evidence_sets WHERE evidence_set_id=?")
        defer { sqlite3_finalize(setStatement) }
        bind(id.uuidString, at: 1, to: setStatement)
        guard sqlite3_step(setStatement) == SQLITE_ROW else { return nil }
        let ruleID = sqlite3_column_type(setStatement, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(setStatement, 0))
        let ruleVersion = sqlite3_column_type(setStatement, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(setStatement, 1))
        guard let start = Self.date(from: String(cString: sqlite3_column_text(setStatement, 2))),
              let end = Self.date(from: String(cString: sqlite3_column_text(setStatement, 3))),
              let orderQuality = EvidenceOrderingQuality(rawValue: String(cString: sqlite3_column_text(setStatement, 4)))
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
        while sqlite3_step(memberStatement) == SQLITE_ROW, let memberID = UUID(uuidString: String(cString: sqlite3_column_text(memberStatement, 0))) {
            memberIDs.append(memberID)
        }
        var members: [EvidenceMembership] = []
        for memberID in memberIDs {
            let reasonStatement = try connection.prepare("SELECT reason_json FROM evidence_reasons WHERE evidence_set_id=? AND observation_id=? ORDER BY reason_code,reason_json")
            defer { sqlite3_finalize(reasonStatement) }
            bind(id.uuidString, at: 1, to: reasonStatement)
            bind(memberID.uuidString, at: 2, to: reasonStatement)
            var reasons: [EvidenceMembershipReason] = []
            while sqlite3_step(reasonStatement) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(reasonStatement, 0))
                guard let reason = try? JSONDecoder.horizon2.decode(EvidenceMembershipReason.self, from: Data(json.utf8)) else { throw EvidenceJournalError.corruption }
                reasons.append(reason)
            }
            members.append(EvidenceMembership(observationID: memberID, reasons: reasons.sorted { $0.canonicalValue < $1.canonicalValue }))
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

    private func evidenceSetIncidentID(id: UUID) throws -> UUID? {
        let statement = try connection.prepare("SELECT incident_id FROM evidence_sets WHERE evidence_set_id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))
    }

    func persist(incident: IncidentPackage, retentionProtected: Bool = false) throws {
        let packageJSON = try String(decoding: JSONEncoder.horizon2.encode(incident), as: UTF8.self)
        let contextJSON = try String(decoding: JSONEncoder.horizon2.encode(incident.materializedContext), as: UTF8.self)
        try ensureCapacity(for: packageJSON.utf8.count + contextJSON.utf8.count + 8192)
        var committed = false
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO incidents(incident_id,marker_observation_id,marker_wall,pre_window_seconds,post_window_seconds,status,schema_version,created_at_wall,completed_at_wall,failure_reason,retention_protected,package_json)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(incident.id.uuidString, at: 1, to: statement); bind(incident.marker.observationID?.uuidString, at: 2, to: statement); bind(Self.dateString(incident.marker.wallTime), at: 3, to: statement)
            bind(Int64(incident.preWindowSeconds), at: 4, to: statement); bind(Int64(incident.postWindowSeconds), at: 5, to: statement); bind(incident.status.rawValue, at: 6, to: statement); bind(Int64(incident.schemaVersion), at: 7, to: statement); bind(Self.dateString(Date()), at: 8, to: statement); bind(incident.completedAt.map(Self.dateString), at: 9, to: statement); bind(incident.failureReason?.rawValue, at: 10, to: statement); bind(Int64(retentionProtected ? 1 : 0), at: 11, to: statement); bind(packageJSON, at: 12, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
            try connection.exec("DELETE FROM incident_observations WHERE incident_id='\(incident.id.uuidString)'")
            try insertIncidentMembership(incidentID: incident.id, observationIDs: incident.observationIDs)
            try connection.exec("DELETE FROM incident_context WHERE incident_id='\(incident.id.uuidString)'")
            try insertIncidentContext(incidentID: incident.id, observedAt: incident.marker.wallTime, kind: "MATERIALIZED_CONTEXT", payload: contextJSON)
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
            let statement = try connection.prepare("DELETE FROM incidents WHERE incident_id=?"); defer { sqlite3_finalize(statement) }; bind(id.uuidString, at: 1, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }; try connection.exec("COMMIT"); try checkpoint(force: true)
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    private func removePersistedIncident(incidentID: UUID) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("DELETE FROM incidents WHERE incident_id=?")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
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
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
    }

    private static func evidenceReasonID(setID: UUID, observationID: UUID, reason: EvidenceMembershipReason) -> UUID {
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
                let statement = try connection.prepare("DELETE FROM observations WHERE observation_id IN (SELECT o.observation_id FROM observations o WHERE \(whereClause) AND NOT EXISTS (SELECT 1 FROM incident_observations i WHERE i.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM evidence_members e WHERE e.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM evidence_reasons r WHERE r.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM inference_support s WHERE s.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM inference_contradictions c WHERE c.observation_id=o.observation_id) ORDER BY o.observed_wall,o.observation_id LIMIT \(retentionBatchSize))")
                defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }; let count = Int(sqlite3_changes(connection.db)); deleted += count; if count == 0 {
                    break
                }
            }
            try connection.exec("COMMIT"); try checkpoint(force: true)
            return EvidenceDeletionResult(observationsDeleted: deleted, incidentsDeleted: 0, healthRecordsDeleted: 0, finalStatus: retentionStatus())
        } catch { try? connection.exec("ROLLBACK"); throw error }
    }

    func performRetention(now: Date = Date()) throws -> EvidenceRetentionStatus {
        guard availabilityState != .unavailable else { throw EvidenceJournalError.unavailable }
        let ordinaryCutoff = Self.dateString(now.addingTimeInterval(-Double(retentionDays) * 86400))
        let incidentCutoff = Self.dateString(now.addingTimeInterval(-Double(Horizon2EvidenceConfiguration.maximumRetentionDays) * 86400))
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
            return EvidenceRetentionStatus(availability: .capacityUnavailable, bytes: status.bytes, protectedIncidentCount: status.protectedIncidentCount)
        }
        availabilityState = .available
        capacityRecoveryBlocked = false
        return EvidenceRetentionStatus(availability: .available, bytes: status.bytes, protectedIncidentCount: status.protectedIncidentCount)
    }

    func reset() throws {
        availabilityState = .unavailable
        try connection.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.close()
        let fm = FileManager.default
        try? fm.removeItem(at: walURL)
        try? fm.removeItem(at: shmURL)
        try fm.removeItem(at: databaseURL)
    }

    func retentionStatus() -> EvidenceRetentionStatus {
        guard availabilityState != .unavailable else {
            return EvidenceRetentionStatus(availability: .unavailable, bytes: stableFootprintBytes(), protectedIncidentCount: 0)
        }
        let protected = (try? connection.scalar("SELECT COUNT(*) FROM incidents WHERE retention_protected=1")) ?? "0"
        let availability: EvidenceJournalAvailability = availabilityState
        return EvidenceRetentionStatus(availability: availability, bytes: stableFootprintBytes(), protectedIncidentCount: Int(protected) ?? 0)
    }

    func schemaTableNames() -> [String] {
        (try? scalarRows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")) ?? []
    }

    func schemaIndexNames() -> [String] {
        (try? scalarRows("SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY name")) ?? []
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
                    minimumBaselineBytes: measurementTransactionCount == 0 ? 0 : measurementMinimumTransactionBaselineBytes,
                    maximumBaselineBytes: measurementMaximumTransactionBaselineBytes,
                    maximumPeakBytes: measurementMaximumTransactionPeakBytes,
                    maximumDeltaBytes: measurementMaximumTransactionDeltaBytes
                ),
                finalMainBytes: mainBytes,
                finalWALBytes: walBytes,
                finalSHMBytes: shmBytes,
                finalStableBytes: mainBytes + walBytes + shmBytes
            )
        }

        private func measurementRecordTransaction(baselineBytes: Int, peakBytes: Int) {
            let delta = max(0, peakBytes - baselineBytes)
            measurementTransactionCount += 1
            measurementMinimumTransactionBaselineBytes = min(measurementMinimumTransactionBaselineBytes, baselineBytes)
            measurementMaximumTransactionBaselineBytes = max(measurementMaximumTransactionBaselineBytes, baselineBytes)
            measurementMaximumTransactionPeakBytes = max(measurementMaximumTransactionPeakBytes, peakBytes)
            measurementMaximumTransactionDeltaBytes = max(measurementMaximumTransactionDeltaBytes, delta)
        }

        private func measurementMilliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        }

        private func fileSize(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        }
    #endif

    func explainQueryPlan(_ query: EvidenceJournalQuery) -> [String] {
        let hasSource = query.sourceID != nil
        let hasSubject = query.subjectIdentityDigest != nil
        let sql: String
        if hasSubject {
            sql = "EXPLAIN QUERY PLAN SELECT o.* FROM observations o JOIN subjects s ON s.subject_id=o.subject_id WHERE s.identity_digest=? AND o.observed_wall >= ? ORDER BY o.observed_wall,o.local_sequence"
        } else if hasSource {
            sql = "EXPLAIN QUERY PLAN SELECT * FROM observations WHERE source_id=? AND observed_wall >= ? ORDER BY observed_wall,local_sequence"
        } else {
            sql = "EXPLAIN QUERY PLAN SELECT * FROM observations WHERE observed_wall >= ? ORDER BY observed_wall,local_sequence"
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

    private func ensureCapacity(for estimatedBytes: Int) throws {
        let currentBytes = stableFootprintBytes()
        if currentBytes < maximumJournalBytes,
           currentBytes + estimatedBytes <= maximumJournalBytes
        // swiftlint:disable:next opening_brace
        {
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

    private func markCapacityUnavailable() {
        availabilityState = .capacityUnavailable
        capacityRecoveryBlocked = true
    }

    func persistInferences(
        incidentID: UUID,
        inferences: [Inference],
        catalogEntries: [NextTestCatalogEntry]
    ) throws {
        guard availabilityState != .unavailable else { throw currentError() }
        guard let incident = incident(id: incidentID), incident.status == .complete || incident.status == .incomplete else {
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
                throw EvidenceJournalError.invalidInferenceInput("Inference references an invalid EvidenceSet or Observation.")
            }
            for reference in inference.nextTests {
                guard let entry = catalog["\(reference.testID)|\(reference.catalogVersion)"],
                      (try? entry.validatedReference()) == reference
                else {
                    throw EvidenceJournalError.invalidInferenceInput("Inference references an invalid NextTest catalog entry.")
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
                let insert = try connection.prepare("INSERT INTO inferences(inference_id,evidence_set_id,rule_id,rule_version,evidence_class,output_json,created_at_wall) VALUES(?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(insert) }
                bind(inference.id.uuidString, at: 1, to: insert)
                bind(inference.evidenceSetID.uuidString, at: 2, to: insert)
                bind(inference.ruleID, at: 3, to: insert)
                bind(inference.ruleVersion, at: 4, to: insert)
                bind(inference.evidenceClass.rawValue, at: 5, to: insert)
                let output = try String(decoding: JSONEncoder.horizon2.encode(inference), as: UTF8.self)
                bind(output, at: 6, to: insert)
                bind(Self.dateString(inference.generatedAt), at: 7, to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }

                for observationID in inference.supportingObservationIDs {
                    let support = try connection.prepare("INSERT INTO inference_support(inference_id,observation_id,support_kind) VALUES(?,?,?)")
                    defer { sqlite3_finalize(support) }
                    bind(inference.id.uuidString, at: 1, to: support)
                    bind(observationID.uuidString, at: 2, to: support)
                    bind("SUPPORT", at: 3, to: support)
                    guard sqlite3_step(support) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
                }
                for observationID in inference.contradictingObservationIDs {
                    let contradiction = try connection.prepare("INSERT INTO inference_contradictions(inference_id,observation_id,contradiction_kind,details_json) VALUES(?,?,?,?)")
                    defer { sqlite3_finalize(contradiction) }
                    bind(inference.id.uuidString, at: 1, to: contradiction)
                    bind(observationID.uuidString, at: 2, to: contradiction)
                    bind("RULE_CONTRADICTION", at: 3, to: contradiction)
                    bind("{}", at: 4, to: contradiction)
                    guard sqlite3_step(contradiction) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
                }
                for reference in inference.nextTests {
                    guard let entry = catalog["\(reference.testID)|\(reference.catalogVersion)"] else {
                        throw EvidenceJournalError.invalidInferenceInput("Missing NextTest snapshot.")
                    }
                    let nextTest = try connection.prepare("INSERT INTO next_test_references(inference_id,catalog_id,catalog_version,purpose,evidence_expected,prerequisites_json,risk_class,user_action,stopping_condition,expected_observations,safety_warning,catalog_provenance) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)")
                    defer { sqlite3_finalize(nextTest) }
                    bind(inference.id.uuidString, at: 1, to: nextTest)
                    bind(entry.reference.testID, at: 2, to: nextTest)
                    bind(entry.reference.catalogVersion, at: 3, to: nextTest)
                    bind(entry.reference.purpose, at: 4, to: nextTest)
                    bind(entry.reference.evidenceExpected, at: 5, to: nextTest)
                    try bind(String(decoding: JSONEncoder.horizon2.encode(entry.prerequisites), as: UTF8.self), at: 6, to: nextTest)
                    bind(entry.riskClass.rawValue, at: 7, to: nextTest)
                    bind(entry.userAction, at: 8, to: nextTest)
                    bind(entry.stoppingCondition, at: 9, to: nextTest)
                    bind(entry.expectedObservations, at: 10, to: nextTest)
                    bind(entry.safetyWarning, at: 11, to: nextTest)
                    // The v1 table has one opaque provenance column. Store the
                    // complete immutable catalog entry there so reload never
                    // resolves a historical reference against a newer catalog.
                    try bind(String(decoding: JSONEncoder.horizon2.encode(entry), as: UTF8.self), at: 12, to: nextTest)
                    guard sqlite3_step(nextTest) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
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
            let statement = try connection.prepare("SELECT i.inference_id FROM inferences i JOIN evidence_sets e ON e.evidence_set_id=i.evidence_set_id WHERE e.incident_id=? ORDER BY i.inference_id")
            defer { sqlite3_finalize(statement) }
            bind(incidentID.uuidString, at: 1, to: statement)
            var result: [Inference] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))),
                      let inference = try loadInference(id: id)
                else { continue }
                if currentOnly,
                   try !InferenceVersionPolicy.isCurrent(inference: inference, evidenceSet: loadEvidenceSet(id: inference.evidenceSetID))
                // swiftlint:disable:next opening_brace
                {
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

    private func loadInference(id: UUID) throws -> Inference? {
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

    private func loadNextTestSnapshots(inferenceID: UUID) throws -> [NextTestCatalogEntry] {
        let statement = try connection.prepare("SELECT catalog_id,catalog_version,purpose,evidence_expected,prerequisites_json,risk_class,user_action,stopping_condition,expected_observations,safety_warning,catalog_provenance FROM next_test_references WHERE inference_id=? ORDER BY catalog_id,catalog_version")
        defer { sqlite3_finalize(statement) }
        bind(inferenceID.uuidString, at: 1, to: statement)
        var entries: [NextTestCatalogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let risk = NextTestRiskClass(rawValue: String(cString: sqlite3_column_text(statement, 5))),
                  let prerequisites = try? JSONDecoder.horizon2.decode([NextTestPrerequisite].self, from: Data(String(cString: sqlite3_column_text(statement, 4)).utf8))
            else { throw EvidenceJournalError.corruption }
            let storedProvenance = String(cString: sqlite3_column_text(statement, 10))
            if let completeEntry = try? JSONDecoder.horizon2.decode(NextTestCatalogEntry.self, from: Data(storedProvenance.utf8)) {
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

    private func maybeCheckpoint(protect: Bool = true) throws -> Bool {
        let walSize = (try? walURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if appendsSinceCheckpoint >= 64 || walSize > 1_048_576 {
            try checkpoint(force: true, protect: protect)
            return true
        }
        return false
    }

    private func checkpoint(force: Bool, protect: Bool = true) throws {
        if force {
            try connection.exec("PRAGMA wal_checkpoint(TRUNCATE)"); appendsSinceCheckpoint = 0
            if protect {
                try protectJournalFiles()
            }
        }
    }

    private func stableFootprintBytes() -> Int {
        let paths = [databaseURL, walURL, shmURL]
        return paths.reduce(0) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    private func existingCanonical(id: UUID) throws -> Data? {
        let statement = try connection.prepare("SELECT canonical_value_json FROM observations WHERE observation_id=?"); defer { sqlite3_finalize(statement) }; bind(id.uuidString, at: 1, to: statement); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return Data(String(cString: sqlite3_column_text(statement, 0)).utf8)
    }

    private func removeRejectedObservation(observationID: UUID, subjectID: String?, provenanceID: String?) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let observation = try connection.prepare("DELETE FROM observations WHERE observation_id=?")
            defer { sqlite3_finalize(observation) }
            bind(observationID.uuidString, at: 1, to: observation)
            guard sqlite3_step(observation) == SQLITE_DONE else {
                throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
            }
            if let subjectID {
                let subject = try connection.prepare("DELETE FROM subjects WHERE subject_id=? AND NOT EXISTS (SELECT 1 FROM observations WHERE subject_id=?)")
                defer { sqlite3_finalize(subject) }
                bind(subjectID, at: 1, to: subject)
                bind(subjectID, at: 2, to: subject)
                guard sqlite3_step(subject) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
                }
            }
            if let provenanceID {
                let provenance = try connection.prepare("DELETE FROM provenance WHERE provenance_id=? AND NOT EXISTS (SELECT 1 FROM observations WHERE provenance_id=?)")
                defer { sqlite3_finalize(provenance) }
                bind(provenanceID, at: 1, to: provenance)
                bind(provenanceID, at: 2, to: provenance)
                guard sqlite3_step(provenance) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
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

    // swiftlint:disable:next large_tuple
    private func removeRejectedObservations(_ inserted: [(observationID: UUID, subjectID: String, provenanceID: String)]) throws {
        guard !inserted.isEmpty else { return }
        try connection.exec("BEGIN IMMEDIATE")
        do {
            for item in inserted {
                let observation = try connection.prepare("DELETE FROM observations WHERE observation_id=?")
                defer { sqlite3_finalize(observation) }
                bind(item.observationID.uuidString, at: 1, to: observation)
                guard sqlite3_step(observation) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
                }
                let subject = try connection.prepare("DELETE FROM subjects WHERE subject_id=? AND NOT EXISTS (SELECT 1 FROM observations WHERE subject_id=?)")
                defer { sqlite3_finalize(subject) }
                bind(item.subjectID, at: 1, to: subject)
                bind(item.subjectID, at: 2, to: subject)
                guard sqlite3_step(subject) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
                }
                let provenance = try connection.prepare("DELETE FROM provenance WHERE provenance_id=? AND NOT EXISTS (SELECT 1 FROM observations WHERE provenance_id=?)")
                defer { sqlite3_finalize(provenance) }
                bind(item.provenanceID, at: 1, to: provenance)
                bind(item.provenanceID, at: 2, to: provenance)
                guard sqlite3_step(provenance) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
                }
            }
            try connection.exec("COMMIT")
            try checkpoint(force: true)
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    private func removeHealthRecord(_ recordID: UUID) throws {
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let statement = try connection.prepare("DELETE FROM source_health_or_suppression WHERE record_id=?")
            defer { sqlite3_finalize(statement) }
            bind(recordID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
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
    private func reclaimPhysicalSpaceAfterRejectedMutation() throws {
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

    private func upsertSubject(_ observation: Observation) throws -> String {
        let identity = observation.subject.identityDigest ?? observation.id.uuidString
        let material = "\(observation.sourceID.rawValue)|\(observation.subject.type.rawValue)|\(identity)"
        let subjectID = EvidenceIdentityDigest.make(scope: "sqlite-subject", material: [material])!
        let statement = try connection.prepare("INSERT INTO subjects(subject_id,source_id,subject_type,identity_digest,identity_quality,first_observed_wall,last_observed_wall,created_at_wall) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(subject_id) DO UPDATE SET last_observed_wall=excluded.last_observed_wall")
        defer { sqlite3_finalize(statement) }; bind(subjectID, at: 1, to: statement); bind(observation.sourceID.rawValue, at: 2, to: statement); bind(observation.subject.type.rawValue, at: 3, to: statement); bind(observation.subject.identityDigest, at: 4, to: statement); bind(observation.subject.quality.rawValue, at: 5, to: statement); bind(Self.dateString(observation.time.observedWallTime), at: 6, to: statement); bind(Self.dateString(observation.time.observedWallTime), at: 7, to: statement); bind(Self.dateString(Date()), at: 8, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }; return subjectID
    }

    private func upsertSubject(_ observation: Observation, using statement: OpaquePointer) throws -> String {
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
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        return subjectID
    }

    private func upsertProvenance(_ provenance: EvidenceProvenance) throws -> String {
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
        let id = EvidenceIdentityDigest.make(scope: "sqlite-provenance", material: [String(decoding: details, as: UTF8.self)])!
        let statement = try connection.prepare("INSERT OR IGNORE INTO provenance(provenance_id,source_id,api_name,api_version,capture_channel,source_timestamp_quality,host_scope,created_at_wall,details_json) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement); bind(provenance.sourceID.rawValue, at: 2, to: statement); bind(provenance.apiName, at: 3, to: statement); bind(provenance.apiVersion, at: 4, to: statement); bind(provenance.captureChannel, at: 5, to: statement); bind(provenance.sourceTimestampQuality.rawValue, at: 6, to: statement); bind(provenance.hostScope.rawValue, at: 7, to: statement); bind(Self.dateString(Date()), at: 8, to: statement); bind(String(decoding: details, as: UTF8.self), at: 9, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }; return id
    }

    private func upsertProvenance(_ provenance: EvidenceProvenance, using statement: OpaquePointer) throws -> String {
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
        let id = EvidenceIdentityDigest.make(scope: "sqlite-provenance", material: [String(decoding: details, as: UTF8.self)])!
        reset(statement: statement)
        bind(id, at: 1, to: statement)
        bind(provenance.sourceID.rawValue, at: 2, to: statement)
        bind(provenance.apiName, at: 3, to: statement)
        bind(provenance.apiVersion, at: 4, to: statement)
        bind(provenance.captureChannel, at: 5, to: statement)
        bind(provenance.sourceTimestampQuality.rawValue, at: 6, to: statement)
        bind(provenance.hostScope.rawValue, at: 7, to: statement)
        bind(Self.dateString(Date()), at: 8, to: statement)
        bind(String(decoding: details, as: UTF8.self), at: 9, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        return id
    }

    private func insertAttributes(for observation: Observation) throws {
        let values = flattenedValues(observation)
        for (path, value) in values {
            guard let metadata = sensitivityMetadata(for: observation.sensitivity, path: path) else { throw EvidenceJournalError.invalidSensitivity(path) }
            let statement = try connection.prepare("INSERT INTO observation_attributes(observation_id,field_path,value_type,value_json,sensitivity,redaction_action) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }; bind(observation.id.uuidString, at: 1, to: statement); bind(path, at: 2, to: statement); bind(value.typeName, at: 3, to: statement); try bind(String(decoding: value.deterministicData(), as: UTF8.self), at: 4, to: statement); bind(metadata.classification.rawValue, at: 5, to: statement); bind(metadata.pseudonymization.sqlAction, at: 6, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        }
    }

    private func insertAttributes(for observation: Observation, using statement: OpaquePointer) throws {
        for (path, value) in flattenedValues(observation) {
            guard let metadata = sensitivityMetadata(for: observation.sensitivity, path: path) else { throw EvidenceJournalError.invalidSensitivity(path) }
            reset(statement: statement)
            bind(observation.id.uuidString, at: 1, to: statement)
            bind(path, at: 2, to: statement)
            bind(value.typeName, at: 3, to: statement)
            try bind(String(decoding: value.deterministicData(), as: UTF8.self), at: 4, to: statement)
            bind(metadata.classification.rawValue, at: 5, to: statement)
            bind(metadata.pseudonymization.sqlAction, at: 6, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        }
    }

    private func insertRedactionMetadata(for observation: Observation) throws {
        for field in observation.sensitivity.fields {
            guard flattenedValues(observation).contains(where: { $0.0 == field.path.rawValue || $0.0.hasPrefix(field.path.rawValue.replacingOccurrences(of: "[*]", with: "[")) }) else { continue }
            let statement = try connection.prepare("INSERT INTO redaction_metadata(redaction_id,observation_id,field_path,sensitivity,action,policy_version,pseudonym_scope,created_at_wall) VALUES(?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }; bind(UUID().uuidString, at: 1, to: statement); bind(observation.id.uuidString, at: 2, to: statement); bind(field.path.rawValue, at: 3, to: statement); bind(field.classification.rawValue, at: 4, to: statement); bind(field.pseudonymization.sqlAction, at: 5, to: statement); bind("1.0.0", at: 6, to: statement); bind(field.pseudonymization.scope, at: 7, to: statement); bind(Self.dateString(Date()), at: 8, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        }
    }

    private func insertRedactionMetadata(for observation: Observation, using statement: OpaquePointer) throws {
        for field in observation.sensitivity.fields {
            guard flattenedValues(observation).contains(where: { $0.0 == field.path.rawValue || $0.0.hasPrefix(field.path.rawValue.replacingOccurrences(of: "[*]", with: "[")) }) else { continue }
            reset(statement: statement)
            bind(UUID().uuidString, at: 1, to: statement)
            bind(observation.id.uuidString, at: 2, to: statement)
            bind(field.path.rawValue, at: 3, to: statement)
            bind(field.classification.rawValue, at: 4, to: statement)
            bind(field.pseudonymization.sqlAction, at: 5, to: statement)
            bind("1.0.0", at: 6, to: statement)
            bind(field.pseudonymization.scope, at: 7, to: statement)
            bind(Self.dateString(Date()), at: 8, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }
        }
    }

    private func reset(statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func validateSensitivity(_ observation: Observation) throws {
        if observation.subject.identityDigest != nil, sensitivityMetadata(for: observation.sensitivity, path: "subject.identityDigest") == nil {
            throw EvidenceJournalError.invalidSensitivity("subject.identityDigest")
        }
        for (path, _) in flattenedValues(observation) where sensitivityMetadata(for: observation.sensitivity, path: path) == nil {
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

    private func validateHealthDetail(_ detail: String?) throws {
        guard let detail else { return }
        let lower = detail.lowercased()
        let prohibited = ["/users/", "ssid", "mac address", "hardware uuid", "hardware_uuid", "serial", "username", "ip address", "192.0.2.", "aa:bb:cc:dd:ee:ff"]
        guard detail.count <= 512, !prohibited.contains(where: lower.contains) else { throw EvidenceJournalError.invalidSensitivity("health.detail") }
    }

    private func deleteExpiredObservations(before cutoff: String) throws {
        while true {
            try connection.exec("BEGIN IMMEDIATE")
            do {
                let statement = try connection.prepare("DELETE FROM observations WHERE observation_id IN (SELECT o.observation_id FROM observations o WHERE o.observed_wall < '\(cutoff)' AND NOT EXISTS (SELECT 1 FROM incident_observations i WHERE i.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM evidence_members e WHERE e.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM evidence_reasons r WHERE r.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM inference_support s WHERE s.observation_id=o.observation_id) AND NOT EXISTS (SELECT 1 FROM inference_contradictions c WHERE c.observation_id=o.observation_id) ORDER BY o.observed_wall,o.observation_id LIMIT \(retentionBatchSize))")
                defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(connection.db)) }; let count = sqlite3_changes(connection.db); try connection.exec("COMMIT"); if count == 0 {
                    break
                }
            } catch { try? connection.exec("ROLLBACK"); throw error }
        }
        try checkpoint(force: true)
    }

    private func deleteExpiredIncidents(before cutoff: String) throws {
        while true {
            try connection.exec("BEGIN IMMEDIATE")
            do {
                let statement = try connection.prepare("DELETE FROM incidents WHERE incident_id IN (SELECT incident_id FROM incidents WHERE completed_at_wall IS NOT NULL AND completed_at_wall < ? AND status='COMPLETE' AND retention_protected=0 ORDER BY completed_at_wall,incident_id LIMIT ?)")
                defer { sqlite3_finalize(statement) }
                bind(cutoff, at: 1, to: statement)
                bind(Int64(retentionBatchSize), at: 2, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw Self.mapSQLiteError(sqlite3_errcode(connection.db))
                }
                let count = sqlite3_changes(connection.db)
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

    private func oldestEvictableIncident() throws -> UUID? {
        let statement = try connection.prepare("SELECT incident_id FROM incidents WHERE status='COMPLETE' AND retention_protected=0 ORDER BY completed_at_wall,incident_id LIMIT 1"); defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))
    }

    private func currentError() -> EvidenceJournalError {
        availabilityState == .capacityUnavailable ? .capacityUnavailable : .unavailable
    }

    private func scalarRows(_ sql: String) throws -> [String] {
        let statement = try connection.prepare(sql); defer { sqlite3_finalize(statement) }; var rows: [String] = []; while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)))
        }; return rows
    }

    private func decodeObservation(_ json: String) -> Observation? {
        try? JSONDecoder.horizon2.decode(Observation.self, from: Data(json.utf8))
    }

    private func detailsJSON(_ detail: String?) throws -> String {
        let object: [String: EvidenceValue] = detail.map { ["category": .string($0)] } ?? [:]; return try String(decoding: JSONEncoder.horizon2.encode(EvidenceValue.object(object)), as: UTF8.self)
    }

    private func detail(from json: String) -> String? {
        guard let value = try? JSONDecoder.horizon2.decode(EvidenceValue.self, from: Data(json.utf8)), case let .object(object) = value, case let .string(detail) = object["category"] else { return nil }; return detail
    }

    private static func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func protectJournalFiles() throws {
        try Self.protectJournalFiles(for: databaseURL)
    }

    private static func protectJournalFiles(for databaseURL: URL) throws {
        let fm = FileManager.default
        // swiftformat:disable trailingCommas
        let sidecars = [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        // swiftformat:enable trailingCommas
        for url in sidecars where fm.fileExists(atPath: url.path) {
            try Self.applyFileProtection(to: url)
        }
    }

    private var walURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    private var shmURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-shm")
    }

    private static let dateFormatter: ISO8601DateFormatter = {
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

    private func bind(_ value: String?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value, at: Int32(index), to: statement)
    }

    private func bind(_ value: Int64?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value, at: Int32(index), to: statement)
    }

    private func bind(_ value: UInt64?, at index: Int, to statement: OpaquePointer) {
        Self.bind(value.map(Int64.init), at: Int32(index), to: statement)
    }

    fileprivate static func mapSQLiteError(_ code: Int32) -> EvidenceJournalError {
        switch code { case SQLITE_BUSY, SQLITE_LOCKED: return .busy; case SQLITE_FULL, SQLITE_IOERR: return .capacityUnavailable; case SQLITE_CORRUPT, SQLITE_NOTADB: return .corruption; default: return .unavailable }
    }
}

enum Horizon2JournalFactory {
    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunix", isDirectory: true)
            .appendingPathComponent("horizon2.sqlite")
    }

    static func makeProduction() -> any EvidenceJournal {
        do { return try SQLiteEvidenceJournal() } catch let error as EvidenceJournalError { return UnavailableEvidenceJournal(failure: error) } catch { return UnavailableEvidenceJournal(failure: .unavailable) }
    }

    static func makeProductionOffMainActor() async -> any EvidenceJournal {
        await Task.detached(priority: .utility) {
            makeProduction()
        }.value
    }
}

private extension JSONEncoder {
    static let horizon2: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder }()
}

private extension JSONDecoder {
    static let horizon2: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()
}

private extension EvidenceDomain { var sqlValue: String {
    switch self { case .display: return "DISPLAY"; case .storage: return "STORAGE"; case .network: return "NETWORK"; case .power: return "POWER"; case .sleepWake: return "SLEEP_WAKE"; case .thermal: return "THERMAL"; case .usb: return "USB"; case .systemContext: return "SYSTEM_CONTEXT"; case let .unknown(value): return value }
} }
private extension EvidenceEventKind { var sqlValue: String {
    switch self { case .storageDiskLifecycle: return "STORAGE_DISK_LIFECYCLE"; case .storageMountLifecycle: return "STORAGE_MOUNT_LIFECYCLE"; case .networkPathTransition: return "NETWORK_PATH_TRANSITION"; case .powerSourceTransition: return "POWER_SOURCE_TRANSITION"; case .sleepWakeBoundary: return "SLEEP_WAKE_BOUNDARY"; case .sourceUnavailable: return "SOURCE_UNAVAILABLE"; case .sourceSuppressed: return "SOURCE_SUPPRESSED"; case let .unknown(value): return value }
} }
private extension EvidenceAvailability { var sqlValue: String {
    switch self { case .available: return "AVAILABLE"; case let .unavailable(reason): return "UNAVAILABLE:\(reason.rawValue)"; case let .unknown(reason): return "UNKNOWN:\(reason.rawValue)" }
} }
private extension EvidencePseudonymizationPolicy { var sqlAction: String {
    switch self { case .notApplicable: return "NONE"; case .allowed: return "ALLOW"; case .required: return "PSEUDONYMIZE"; case .unknown: return "REVIEW" }
}; var scope: String? {
    switch self { case let .allowed(value), let .required(value): return value; default: return nil }
} }
private extension EvidenceValue { var typeName: String {
    switch self { case .string: return "STRING"; case .integer: return "INTEGER"; case .unsigned: return "UNSIGNED"; case .decimal: return "DECIMAL"; case .boolean: return "BOOLEAN"; case .date: return "DATE"; case .bytes: return "BYTES"; case .array: return "ARRAY"; case .object: return "OBJECT"; case .null: return "NULL" }
} }

private func flattenedValues(_ observation: Observation) -> [(String, EvidenceValue)] {
    var result: [(String, EvidenceValue)] = []
    func visit(_ value: EvidenceValue, path: String) {
        switch value {
        case let .object(object) where !object.isEmpty:
            for key in object.keys.sorted() {
                visit(object[key]!, path: "\(path).\(key)")
            }
        case let .array(array) where !array.isEmpty:
            for (index, child) in array.enumerated() {
                visit(child, path: "\(path)[\(index)]")
            }
        default: result.append((path, value))
        }
    }
    if let previous = observation.previousState {
        visit(previous, path: "previousState")
    }
    if let current = observation.currentState {
        visit(current, path: "currentState")
    }
    for key in observation.attributes.keys.sorted() {
        visit(observation.attributes[key]!, path: "attributes.\(key)")
    }
    return result
}

private func sensitivityMetadata(for registry: EvidenceSensitivityRegistry, path: String) -> EvidenceFieldSensitivity? {
    for field in registry.fields {
        let pattern = field.path.rawValue
        if path == pattern || path.hasPrefix(pattern + ".") || path.hasPrefix(pattern + "[") {
            return field
        }
        if pattern.contains("[*]") {
            let prefix = pattern.components(separatedBy: "[*]").first ?? pattern
            if path.hasPrefix(prefix) {
                return field
            }
        }
    }
    return nil
}

// swiftlint:enable line_length type_body_length function_body_length cyclomatic_complexity
// swiftlint:enable identifier_name optional_data_string_conversion switch_case_alignment
