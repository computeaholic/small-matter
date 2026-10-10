import Foundation
import SQLite3

struct SQLiteInsertedObservation {
    let observationID: UUID
    let subjectID: String
    let provenanceID: String
}

extension SQLiteEvidenceJournal {
    // Why: explicit fail-closed matrix.
    // Why: ordered canonical flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        let database = connection.database
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
            bind(String(bytes: canonical, encoding: .utf8) ?? "", at: 16, to: statement)
            bind(Self.dateString(Date()), at: 17, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.mapSQLiteError(sqlite3_errcode(database)) }
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
            let mapped = Self.mapSQLiteError(sqlite3_errcode(database))
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

    // Persists a bounded group of immutable observations in one SQLite
    // transaction. The caller applies the same batching policy, but this
    // durable boundary independently validates the aggregate before BEGIN.
    // The async signature is intentional: it is the concrete witness for
    // EvidenceJournal.appendBatch rather than the protocol's per-record
    // fallback implementation.
    // Why: explicit fail-closed matrix.
    // Why: ordered canonical flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func appendBatch(_ observations: [
        Observation
    ]) async throws {
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
        let database = connection.database
        var inserted: [SQLiteInsertedObservation] = []
        #if HORIZON2_MEASUREMENT
            let totalAppendStart = DispatchTime.now().uptimeNanoseconds
            let transactionBaselineBytes = stableFootprintBytes()
            var transactionPeakBytes = transactionBaselineBytes
        #endif
        try connection.exec("BEGIN IMMEDIATE")
        do {
            let subjectStatement = try connection
                .prepare(
                    "INSERT INTO subjects(subject_id, source_id, subject_type, identity_digest, identity_quality, " +
                        "first_observed_wall, last_observed_wall, created_at_wall) VALUES(?,?,?,?,?,?,?,?) " +
                        "ON CONFLICT(subject_id) DO UPDATE SET last_observed_wall=excluded.last_observed_wall"
                )
            defer { sqlite3_finalize(subjectStatement) }
            let provenanceStatement = try connection
                .prepare(
                    "INSERT OR IGNORE INTO provenance(" +
                        "provenance_id, source_id, api_name, api_version, capture_channel, " +
                        "source_timestamp_quality, host_scope, created_at_wall, details_json) " +
                        "VALUES(?,?,?,?,?,?,?,?,?)"
                )
            defer { sqlite3_finalize(provenanceStatement) }
            let observationStatement = try connection.prepare("""
                INSERT INTO observations(observation_id,domain,event_kind,source_id,subject_id,provenance_id,
                observed_wall,observed_continuous_ns,observed_monotonic_ns,boot_session_id,process_run_id,
                local_sequence,correlation_epoch_id,timestamp_quality,quality,canonical_value_json,created_at_wall)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(observationStatement) }
            let attributeStatement = try connection
                .prepare(
                    "INSERT INTO observation_attributes(" +
                        "observation_id, field_path, value_type, value_json, sensitivity, redaction_action) " +
                        "VALUES(?,?,?,?,?,?)"
                )
            defer { sqlite3_finalize(attributeStatement) }
            let redactionStatement = try connection
                .prepare(
                    "INSERT INTO redaction_metadata(" +
                        "redaction_id, observation_id, field_path, sensitivity, action, " +
                        "policy_version, pseudonym_scope, created_at_wall) VALUES(?,?,?,?,?,?,?,?)"
                )
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
                bind(String(bytes: canonical, encoding: .utf8) ?? "", at: 16, to: observationStatement)
                bind(Self.dateString(Date()), at: 17, to: observationStatement)
                guard sqlite3_step(observationStatement) == SQLITE_DONE
                else { throw Self.mapSQLiteError(sqlite3_errcode(database)) }
                try insertAttributes(for: observation, using: attributeStatement)
                try insertRedactionMetadata(for: observation, using: redactionStatement)
                inserted.append(
                    SQLiteInsertedObservation(
                        observationID: observation.id,
                        subjectID: subjectID,
                        provenanceID: provenanceID
                    )
                )
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
            throw Self.mapSQLiteError(sqlite3_errcode(database))
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
}
