import CryptoKit
import Foundation

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
enum EvidenceRedactionPolicy {
    static let currentVersion = "1.0.0"
    static let pseudonymMethod = "PACKAGE_SCOPED_SHA256"

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    static func redact(
        observation: Observation,
        packageScope: String
    ) throws -> (observation: Observation, manifest: [EvidenceRedactionManifestEntry]) {
        var manifest: [EvidenceRedactionManifestEntry] = []
        let previousState = try redactOptionalValue(
            observation.previousState,
            path: "previousState",
            registry: observation.sensitivity,
            packageScope: packageScope,
            manifest: &manifest
        )
        let currentState = try redactOptionalValue(
            observation.currentState,
            path: "currentState",
            registry: observation.sensitivity,
            packageScope: packageScope,
            manifest: &manifest
        )
        let attributesValue = try redactValue(
            .object(observation.attributes),
            path: "attributes",
            registry: observation.sensitivity,
            packageScope: packageScope,
            manifest: &manifest
        )

        guard case let .object(attributes) = attributesValue else {
            throw EvidencePackageError.rendererFailure("Observation attributes did not remain an object.")
        }

        var subjectDigest: String?
        if let rawDigest = observation.subject.identityDigest {
            subjectDigest = pseudonym(
                rawDigest,
                path: "subject.identityDigest",
                packageScope: packageScope
            )
            manifest.append(EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("subject.identityDigest"),
                classification: .deviceMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            ))
        }
        if observation.subject.safeDisplayLabel != nil {
            manifest.append(EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("subject.safeDisplayLabel"),
                classification: .applicationMetadata,
                action: .omit
            ))
        }
        let subject = EvidenceSubject(
            type: observation.subject.type,
            identityDigest: subjectDigest,
            quality: observation.subject.quality,
            safeDisplayLabel: genericLabel(for: observation.subject.type)
        )

        let rawReferenceDigest: String? = nil
        if observation.provenance.rawReferenceDigest != nil {
            manifest.append(EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("provenance.rawReferenceDigest"),
                classification: .deviceMetadata,
                action: .omit
            ))
        }
        let provenance = EvidenceProvenance(
            sourceID: observation.provenance.sourceID,
            apiName: observation.provenance.apiName,
            apiVersion: observation.provenance.apiVersion,
            captureChannel: observation.provenance.captureChannel,
            sourceTimestampQuality: observation.provenance.sourceTimestampQuality,
            normalizationRuleID: observation.provenance.normalizationRuleID,
            normalizationRuleVersion: observation.provenance.normalizationRuleVersion,
            hostScope: observation.provenance.hostScope,
            rawReferenceDigest: rawReferenceDigest
        )

        let time = redactedTime(observation.time, packageScope: packageScope, manifest: &manifest)
        let transformed = Observation(
            id: observation.id,
            domain: observation.domain,
            eventKind: observation.eventKind,
            sourceID: observation.sourceID,
            subject: subject,
            provenance: provenance,
            time: time,
            availability: observation.availability,
            previousState: previousState,
            currentState: currentState,
            attributes: attributes,
            sensitivity: observation.sensitivity,
            schemaVersion: observation.schemaVersion
        )
        return (transformed, manifest)
    }

    static func redactContext(_ context: EvidenceValue) throws -> EvidenceValue {
        guard case let .object(topLevel) = context else {
            throw EvidencePackageError.unsupportedContextField("context")
        }
        let allowed: [String: Set<String>] = [
            "system": [
                "cpuUtilizationPercent", "memoryPressure", "memoryUsedBytes", "memoryPhysicalBytes",
                "swapUsedBytes", "rootStorageFreeBytes", "rootStorageTotalBytes", "lowPowerMode", "thermalState"
            ],
            "network": ["sentBytes", "receivedBytes", "uploadBytesPerSecond", "downloadBytesPerSecond"],
            "battery": ["present", "acConnected", "charging", "stateOfChargePercent"],
            "cooling": ["primaryFanRPM", "primaryTemperatureCelsius"]
        ]
        var result: [String: EvidenceValue] = [:]
        for (section, value) in topLevel {
            guard case let .object(fields) = value else {
                throw EvidencePackageError.unsupportedContextField("context.\(section)")
            }
            var safeFields: [String: EvidenceValue] = [:]
            for (key, field) in fields {
                let isWindowSummaryField = section == "windowSummary" && (
                    key == "requestedStart" || key == "requestedEnd" || key == "coveredStart" ||
                        key == "coveredEnd" || key == "sampleCount" || key == "coverage" ||
                        key.hasPrefix("metric_") || key.hasPrefix("state_")
                )
                guard isWindowSummaryField || allowed[section]?.contains(key) == true else {
                    throw EvidencePackageError.unclassifiedField("context.\(section).\(key)")
                }
                guard isScalar(field) else {
                    throw EvidencePackageError.unsupportedContextField("context.\(section).\(key)")
                }
                safeFields[key] = field
            }
            result[section] = .object(safeFields)
        }
        return .object(result)
    }

    private static func redactOptionalValue(
        _ value: EvidenceValue?,
        path: String,
        registry: EvidenceSensitivityRegistry,
        packageScope: String,
        manifest: inout [EvidenceRedactionManifestEntry]
    ) throws -> EvidenceValue? {
        guard let value else { return nil }
        return try redactValue(value, path: path, registry: registry, packageScope: packageScope, manifest: &manifest)
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private static func redactValue(
        _ value: EvidenceValue,
        path: String,
        registry: EvidenceSensitivityRegistry,
        packageScope: String,
        manifest: inout [EvidenceRedactionManifestEntry]
    ) throws -> EvidenceValue {
        if let metadata = metadata(for: path, registry: registry) {
            switch action(for: metadata) {
            case .include:
                return try redactChildrenIfDeclared(
                    value,
                    path: path,
                    registry: registry,
                    packageScope: packageScope,
                    manifest: &manifest
                )
            case .omit:
                manifest.append(EvidenceRedactionManifestEntry(
                    path: EvidenceFieldPath(path),
                    classification: metadata.classification,
                    action: .omit
                ))
                return .null
            case .pseudonymize:
                let raw = try canonicalScalar(value, path: path)
                let result = pseudonym(raw, path: path, packageScope: packageScope)
                manifest.append(EvidenceRedactionManifestEntry(
                    path: EvidenceFieldPath(path),
                    classification: metadata.classification,
                    action: .pseudonymize,
                    method: pseudonymMethod,
                    scope: "package"
                ))
                return .string(result)
            }
        }

        switch value {
        case let .object(fields):
            if !fields.isEmpty, !hasDeclaredDescendant(path: path, registry: registry) {
                throw EvidencePackageError.unclassifiedField("\(path).\(fields.keys.sorted().first!)")
            }
            var transformed: [String: EvidenceValue] = [:]
            for key in fields.keys.sorted() {
                transformed[key] = try redactValue(
                    fields[key]!,
                    path: "\(path).\(key)",
                    registry: registry,
                    packageScope: packageScope,
                    manifest: &manifest
                )
            }
            return .object(transformed)
        case let .array(values):
            if !values.isEmpty, !hasDeclaredDescendant(path: path, registry: registry) {
                throw EvidencePackageError.unclassifiedField("\(path)[0]")
            }
            return try .array(values.enumerated().map { index, item in
                try redactValue(
                    item,
                    path: "\(path)[\(index)]",
                    registry: registry,
                    packageScope: packageScope,
                    manifest: &manifest
                )
            })
        default:
            throw EvidencePackageError.unclassifiedField(path)
        }
    }

    private static func redactChildrenIfDeclared(
        _ value: EvidenceValue,
        path: String,
        registry: EvidenceSensitivityRegistry,
        packageScope: String,
        manifest: inout [EvidenceRedactionManifestEntry]
    ) throws -> EvidenceValue {
        switch value {
        case let .object(fields):
            var output: [String: EvidenceValue] = [:]
            for key in fields.keys.sorted() {
                output[key] = try redactValue(
                    fields[key]!,
                    path: "\(path).\(key)",
                    registry: registry,
                    packageScope: packageScope,
                    manifest: &manifest
                )
            }
            return .object(output)
        case let .array(values):
            return try .array(values.enumerated().map { index, item in
                try redactValue(
                    item,
                    path: "\(path)[\(index)]",
                    registry: registry,
                    packageScope: packageScope,
                    manifest: &manifest
                )
            })
        default:
            return value
        }
    }

    private static func action(for metadata: EvidenceFieldSensitivity) -> EvidenceRedactionAction {
        switch metadata.classification {
        case .none:
            return .include
        case .personal, .applicationMetadata, .deviceMetadata, .networkMetadata, .filesystemMetadata:
            switch metadata.pseudonymization {
            case .allowed, .required:
                return .pseudonymize
            case .notApplicable, .unknown:
                return .omit
            }
        }
    }

    private static func metadata(for path: String, registry: EvidenceSensitivityRegistry) -> EvidenceFieldSensitivity? {
        if let exact = registry.fields.first(where: { $0.path.rawValue == path }) {
            return exact
        }
        let normalized = path.replacingOccurrences(of: #"\[\d+\]"#, with: "[*]", options: .regularExpression)
        return registry.fields.first(where: { $0.path.rawValue == normalized })
    }

    private static func hasDeclaredDescendant(path: String, registry: EvidenceSensitivityRegistry) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: #"\[\d+\]"#, with: "[*]", options: .regularExpression)
        let prefix = normalizedPath + "."
        let arrayPrefix = normalizedPath + "[*]"
        return registry.fields
            .contains { $0.path.rawValue.hasPrefix(prefix) || $0.path.rawValue.hasPrefix(arrayPrefix) }
    }

    private static func canonicalScalar(_ value: EvidenceValue, path: String) throws -> String {
        switch value {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .unsigned(value): return String(value)
        case let .decimal(value): return value
        case let .boolean(value): return value ? "true" : "false"
        case let .date(value): return ISO8601DateFormatter().string(from: value)
        case let .bytes(value): return value.base64EncodedString()
        case .array, .object, .null:
            throw EvidencePackageError.unclassifiedField(path)
        }
    }

    private static func isScalar(_ value: EvidenceValue) -> Bool {
        switch value {
        case .string, .integer, .unsigned, .decimal, .boolean, .date, .bytes, .null: return true
        case .array, .object: return false
        }
    }

    private static func pseudonym(_ raw: String, path: String, packageScope: String) -> String {
        let digest = SHA256.hash(data: Data("\(currentVersion)|\(packageScope)|\(path)|\(raw)".utf8))
        return "pseudonym-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func genericLabel(for type: EvidenceSubjectType) -> String {
        switch type {
        case .storageDisk: return "Storage disk"
        case .mountedVolume: return "Mounted volume"
        case .networkInterface: return "Network interface"
        case .powerSource: return "Power source"
        case .display: return "Display"
        case .sleepWakeBoundary: return "Sleep/wake boundary"
        case .thermal: return "Thermal state"
        case .usbDevice: return "USB device"
        case .systemContext: return "System context"
        case .unknown: return "Evidence subject"
        }
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private static func redactedTime(
        _ time: EvidenceTime,
        packageScope: String,
        manifest: inout [EvidenceRedactionManifestEntry]
    ) -> EvidenceTime {
        let processRunID = scopedUUID(time.processRunID, path: "time.processRunID", packageScope: packageScope)
        let correlationEpochID = scopedUUID(
            time.correlationEpochID,
            path: "time.correlationEpochID",
            packageScope: packageScope
        )
        let bootSessionID = time.bootSessionID.map { scopedString(
            $0,
            path: "time.bootSessionID",
            packageScope: packageScope
        ) }
        let clockDomainID = scopedString(
            time.orderingDomain.clockDomainID,
            path: "time.orderingDomain.clockDomainID",
            packageScope: packageScope
        )
        manifest.append(contentsOf: [
            EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("time.processRunID"),
                classification: .applicationMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            ),
            EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("time.correlationEpochID"),
                classification: .applicationMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            ),
            EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("time.bootSessionID"),
                classification: .applicationMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            ),
            EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("time.orderingDomain.processRunID"),
                classification: .applicationMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            ),
            EvidenceRedactionManifestEntry(
                path: EvidenceFieldPath("time.orderingDomain.clockDomainID"),
                classification: .applicationMetadata,
                action: .pseudonymize,
                method: pseudonymMethod,
                scope: "package"
            )
        ])
        return EvidenceTime(
            observedWallTime: time.observedWallTime,
            continuousNanoseconds: time.continuousNanoseconds,
            processUptimeNanoseconds: time.processUptimeNanoseconds,
            processRunID: processRunID,
            bootSessionID: bootSessionID,
            localSequence: time.localSequence,
            sourceTimestampQuality: time.sourceTimestampQuality,
            orderingDomain: EvidenceOrderingDomain(
                sourceID: time.orderingDomain.sourceID,
                processRunID: processRunID,
                clockDomainID: clockDomainID
            ),
            sourceOccurrence: time.sourceOccurrence,
            lifecycleBoundary: time.lifecycleBoundary,
            correlationEpochID: correlationEpochID
        )
    }

    private static func scopedUUID(_ value: UUID, path: String, packageScope: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(currentVersion)|\(packageScope)|\(path)|\(value.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    private static func scopedString(_ value: String, path: String, packageScope: String) -> String {
        pseudonym(value, path: path, packageScope: packageScope)
    }
    // Why: cohesive reviewed boundary.
} // swiftlint:disable:this file_length
