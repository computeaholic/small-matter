import SQLite3

extension SQLiteConnection {
    // Why: ordered canonical flow.
    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    func createSchemaV1() throws {
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
            CHECK(
                (observation_id IS NOT NULL) + (incident_id IS NOT NULL) +
                (evidence_set_id IS NOT NULL) + (inference_id IS NOT NULL) = 1
            )
        );
        CREATE INDEX observations_by_time ON observations(observed_wall, local_sequence, observation_id);
        CREATE INDEX observations_by_source_time ON observations(
            source_id, observed_wall, local_sequence, observation_id
        );
        CREATE INDEX observations_by_subject_time ON observations(
            subject_id, observed_wall, local_sequence, observation_id
        );
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
