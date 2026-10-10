import Foundation
import SQLite3

final class SQLiteConnection {
    let url: URL
    let database: OpaquePointer
    var closed = false

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
        database = opened
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
        sqlite3_close_v2(database)
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
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else { throw SQLiteEvidenceJournal.mapSQLiteError(result) }
    }

    func scalar(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW
        else { throw SQLiteEvidenceJournal.mapSQLiteError(sqlite3_errcode(database)) }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw SQLiteEvidenceJournal.mapSQLiteError(result) }
        return statement
    }

    func insertMetadata(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO schema_metadata(key,value,updated_at_wall) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        SQLiteEvidenceJournal.bind(key, at: 1, to: statement)
        SQLiteEvidenceJournal.bind(value, at: 2, to: statement)
        SQLiteEvidenceJournal.bind(SQLiteEvidenceJournal.dateString(Date()), at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE
        else { throw SQLiteEvidenceJournal.mapSQLiteError(sqlite3_errcode(database)) }
    }
}

actor SQLiteEvidenceJournal: EvidenceJournal {
    let databaseURL: URL
    let connection: SQLiteConnection
    var maximumJournalBytes: Int
    let transactionalHeadroomBytes: Int
    let retentionBatchSize: Int
    let retentionDays: Int
    var availabilityState: EvidenceJournalAvailability = .available
    // Once retention has proved that the journal cannot currently make room,
    // queued writers fail promptly until an explicit recovery operation.
    var capacityRecoveryBlocked = false
    var appendsSinceCheckpoint = 0
    #if HORIZON2_MEASUREMENT
        var measurementAppendTimings: [Horizon2MeasurementAppendTiming] = []
        var measurementTransactionCount = 0
        var measurementMinBaselineBytes = Int.max
        var measurementMaxBaselineBytes = 0
        var measurementMaxPeakBytes = 0
        var measurementMaxDeltaBytes = 0
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
}

enum Horizon2JournalFactory {
    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunix", isDirectory: true)
            .appendingPathComponent("horizon2.sqlite")
    }

    static func makeProduction() -> any EvidenceJournal {
        do { return try SQLiteEvidenceJournal() } catch let error as EvidenceJournalError {
            return UnavailableEvidenceJournal(failure: error)
        } catch {
            return UnavailableEvidenceJournal(failure: .unavailable)
        }
    }

    static func makeProductionOffMainActor() async -> any EvidenceJournal {
        await Task.detached(priority: .utility) {
            makeProduction()
        }.value
    }
}

extension JSONEncoder {
    static let horizon2: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder
            .dateEncodingStrategy = .iso8601; return encoder
    }()
}

extension JSONDecoder {
    static let horizon2: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
}

extension EvidenceDomain { var sqlValue: String {
    switch self {
    case .display: return "DISPLAY"
    case .storage: return "STORAGE"
    case .network: return "NETWORK"
    case .power: return "POWER"
    case .sleepWake: return "SLEEP_WAKE"
    case .thermal: return "THERMAL"
    case .usb: return "USB"
    case .systemContext: return "SYSTEM_CONTEXT"
    case let .unknown(value): return value
    }
} }
extension EvidenceEventKind { var sqlValue: String {
    switch self {
    case .storageDiskLifecycle: return "STORAGE_DISK_LIFECYCLE"
    case .storageMountLifecycle: return "STORAGE_MOUNT_LIFECYCLE"
    case .networkPathTransition: return "NETWORK_PATH_TRANSITION"
    case .powerSourceTransition: return "POWER_SOURCE_TRANSITION"
    case .sleepWakeBoundary: return "SLEEP_WAKE_BOUNDARY"
    case .sourceUnavailable: return "SOURCE_UNAVAILABLE"
    case .sourceSuppressed: return "SOURCE_SUPPRESSED"
    case let .unknown(value): return value
    }
} }
extension EvidenceAvailability { var sqlValue: String {
    switch self {
    case .available: return "AVAILABLE"
    case let .unavailable(reason): return "UNAVAILABLE:\(reason.rawValue)"
    case let .unknown(reason): return "UNKNOWN:\(reason.rawValue)"
    }
} }
extension EvidencePseudonymizationPolicy { var sqlAction: String {
    switch self {
    case .notApplicable: return "NONE"
    case .allowed: return "ALLOW"
    case .required: return "PSEUDONYMIZE"
    case .unknown: return "REVIEW"
    }
}; var scope: String? {
    switch self {
    case let .allowed(value), let .required(value): return value
    default: return nil
    }
} }
extension EvidenceValue { var typeName: String {
    switch self {
    case .string: return "STRING"
    case .integer: return "INTEGER"
    case .unsigned: return "UNSIGNED"
    case .decimal: return "DECIMAL"
    case .boolean: return "BOOLEAN"
    case .date: return "DATE"
    case .bytes: return "BYTES"
    case .array: return "ARRAY"
    case .object: return "OBJECT"
    case .null: return "NULL"
    }
} }

func flattenedValues(_ observation: Observation) -> [(String, EvidenceValue)] {
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

func sensitivityMetadata(for registry: EvidenceSensitivityRegistry, path: String) -> EvidenceFieldSensitivity? {
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
