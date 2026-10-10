import CryptoKit
import Foundation

enum EvidencePackageError: Error, Equatable, LocalizedError, Sendable {
    case incidentUnavailable(UUID)
    case missingObservation(UUID)
    case missingEvidenceSet(UUID)
    case missingInference(UUID)
    case missingNextTestSnapshot(UUID, String)
    case derivedEvidenceIncomplete(UUID)
    case invalidReference(String)
    case duplicateIdentifier(String)
    case unclassifiedField(String)
    case unsupportedContextField(String)
    case unsupportedInferenceRule(String)
    case rendererFailure(String)
    case writeFailure(String)

    var errorDescription: String? {
        switch self {
        case let .incidentUnavailable(id): return "Incident " + id.uuidString + " is unavailable."
        case let .missingObservation(id): return "Observation " + id.uuidString + " is missing."
        case let .missingEvidenceSet(id): return "EvidenceSet " + id.uuidString + " is missing."
        case let .missingInference(id): return "Inference " + id.uuidString + " is missing."
        case let .missingNextTestSnapshot(id, testID): return "Next Test snapshot " + testID +
            " is missing for inference " + id.uuidString + "."
        case let .derivedEvidenceIncomplete(id): return "Current derived evidence is incomplete for EvidenceSet " + id
            .uuidString + "."
        case let .invalidReference(message): return message
        case let .duplicateIdentifier(value): return "Duplicate package identifier: " + value + "."
        case let .unclassifiedField(path): return "Unclassified dynamic field: " + path + "."
        case let .unsupportedContextField(path): return "Unsupported context field: " + path + "."
        case let .unsupportedInferenceRule(ruleID): return "Unsupported inference rule: " + ruleID + "."
        case let .rendererFailure(message): return message
        case let .writeFailure(message): return message
        }
    }
}

enum EvidenceExportFormat: String, Codable, Equatable, Sendable {
    case json
    case text

    var filenameExtension: String {
        rawValue
    }

    var contentTypeIdentifier: String {
        self == .json ? "public.json" : "public.plain-text"
    }
}

private struct EvidencePackageAssemblyInput: Sendable {
    let incident: IncidentPackage
    let observations: [Observation]
    let allEvidenceSets: [EvidenceSet]
    let currentEvidenceSets: [EvidenceSet]
    let currentInferences: [Inference]
    let incompleteDerivedEvidenceSetIDs: [UUID]
}

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
struct EvidencePackageAssembler: Sendable {
    static let productIdentity = "Small Matter"

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    func assemble(incidentID: UUID, journal: any EvidenceJournal) async throws -> EvidencePackage {
        let input = try await loadAssemblyInput(incidentID: incidentID, journal: journal)
        let incident = input.incident
        let observations = input.observations
        _ = input.allEvidenceSets
        let currentSets = input.currentEvidenceSets
        let currentInferences = input.currentInferences

        var snapshotsByReference: [String: NextTestCatalogEntry] = [:]
        for inference in currentInferences {
            let snapshots = await journal.nextTestSnapshots(inferenceID: inference.id)
            for reference in inference.nextTests {
                guard let snapshot = snapshots.first(where: { $0.reference == reference }) else {
                    throw EvidencePackageError.missingNextTestSnapshot(inference.id, reference.testID)
                }
                let key = "\(reference.testID)|\(reference.catalogVersion)"
                if let existing = snapshotsByReference[key], existing != snapshot {
                    throw EvidencePackageError.invalidReference("Conflicting NextTest snapshot for \(key).")
                }
                snapshotsByReference[key] = snapshot
            }
        }

        let orderedSets = currentSets.sorted(by: compareEvidenceSets)
        let orderedInferences = currentInferences.sorted(by: compareInferences)
        let snapshots = snapshotsByReference.values.sorted { lhs, rhs in
            if lhs.reference.testID != rhs.reference.testID {
                return lhs.reference.testID < rhs.reference.testID
            }
            return lhs.reference.catalogVersion < rhs.reference.catalogVersion
        }
        let versionManifest = makeVersionManifest(
            nextTestCatalogVersion: snapshots.map(\.reference.catalogVersion).first ?? Horizon2NextTestCatalog
                .currentVersion
        )

        let context = try EvidenceRedactionPolicy.redactContext(incident.materializedContext)
        let packageScope = "\(incident.id.uuidString)|\(EvidenceRedactionPolicy.currentVersion)"
        var redactedObservations: [Observation] = []
        var manifest: [EvidenceRedactionManifestEntry] = []
        for observation in observations.sorted(by: compareObservations) {
            let result = try EvidenceRedactionPolicy.redact(observation: observation, packageScope: packageScope)
            redactedObservations.append(result.observation)
            manifest.append(contentsOf: result.manifest.map { entry in
                EvidenceRedactionManifestEntry(
                    path: EvidenceFieldPath("observations[\(observation.id.uuidString)].\(entry.path.rawValue)"),
                    classification: entry.classification,
                    action: entry.action,
                    method: entry.method,
                    scope: entry.scope
                )
            })
        }
        var packageUnknowns = incident.unknowns
        for evidenceSetID in input.incompleteDerivedEvidenceSetIDs {
            packageUnknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .incompleteCapture,
                explanation: "Derived interpretation was not available for EvidenceSet \(evidenceSetID.uuidString); " +
                    "captured observations remain preserved."
            ))
        }
        let orderedUnknowns = packageUnknowns.sorted(by: compareUnknowns)
        let packageIncident = EvidencePackageIncident(
            id: incident.id,
            status: incident.status,
            markerTime: incident.marker.wallTime,
            captureWindow: EvidenceTimeBounds(
                start: incident.marker.wallTime
                    .addingTimeInterval(-Double(Horizon2EvidenceConfiguration.incidentPreWindowSeconds)),
                end: incident.marker.wallTime
                    .addingTimeInterval(Double(Horizon2EvidenceConfiguration.incidentPostWindowSeconds))
            ),
            unknowns: orderedUnknowns
        )
        let sourceManifest = Horizon2SourceID.allCases.sorted { $0.rawValue < $1.rawValue }.map { sourceID in
            EvidenceSourceManifestEntry(
                sourceID: sourceID,
                disposition: Horizon2EvidenceConfiguration.sourceDispositions[sourceID]!,
                userFacingEvidenceAllowed: Horizon2SourceCapability.canProvideUserFacingEvidence(sourceID),
                includedObservationCount: redactedObservations.filter { $0.sourceID == sourceID }.count
            )
        }
        let packageID = try makePackageID(
            incident: incident,
            observations: observations,
            evidenceSets: orderedSets,
            inferences: orderedInferences,
            versionManifest: versionManifest,
            context: incident.materializedContext
        )
        return EvidencePackage(
            id: packageID,
            productIdentity: Self.productIdentity,
            incident: packageIncident,
            context: context,
            observations: redactedObservations,
            evidenceSets: orderedSets,
            inferences: orderedInferences,
            nextTestSnapshots: snapshots,
            sourceManifest: sourceManifest,
            versionManifest: versionManifest,
            redactionManifest: manifest.sorted(by: compareManifestEntries),
            redactionPolicyVersion: EvidenceRedactionPolicy.currentVersion
        )
    }

    private func loadAssemblyInput(
        incidentID: UUID,
        journal: any EvidenceJournal
    ) async throws -> EvidencePackageAssemblyInput {
        guard let incident = await journal.incident(id: incidentID) else {
            throw EvidencePackageError.incidentUnavailable(incidentID)
        }

        let observationIDs = incident.observationIDs
        var observations: [Observation] = []
        for id in observationIDs {
            guard let observation = await journal.observation(id: id) else {
                throw EvidencePackageError.missingObservation(id)
            }
            observations.append(observation)
        }
        try validateUnique(observationIDs, label: "observation")

        let allEvidenceSets = await journal.evidenceSets(incidentID: incidentID)
        let currentEvidenceSets = allEvidenceSets.filter(InferenceVersionPolicy.isCurrentEvidenceSet)
        try validateUnique(currentEvidenceSets.map(\.id), label: "evidence set")
        let currentInferences = await journal.inferences(incidentID: incidentID, currentOnly: true)
        try validateUnique(currentInferences.map(\.id), label: "inference")
        try validateReferences(
            observations: observations,
            allEvidenceSets: allEvidenceSets,
            currentEvidenceSets: currentEvidenceSets,
            currentInferences: currentInferences,
            incident: incident
        )

        let inferenceBySet = Dictionary(grouping: currentInferences, by: \.evidenceSetID)
        let incompleteDerivedEvidenceSetIDs = currentEvidenceSets
            .filter { isInitialRule($0.ruleID) && inferenceBySet[$0.id]?.count != 1 }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        if incident.status == .complete, let evidenceSetID = incompleteDerivedEvidenceSetIDs.first {
            throw EvidencePackageError.derivedEvidenceIncomplete(evidenceSetID)
        }

        return EvidencePackageAssemblyInput(
            incident: incident,
            observations: observations,
            allEvidenceSets: allEvidenceSets,
            currentEvidenceSets: currentEvidenceSets,
            currentInferences: currentInferences,
            incompleteDerivedEvidenceSetIDs: incompleteDerivedEvidenceSetIDs
        )
    }

    private func validateReferences(
        observations: [Observation],
        allEvidenceSets: [EvidenceSet],
        currentEvidenceSets: [EvidenceSet],
        currentInferences: [Inference],
        incident: IncidentPackage
    ) throws {
        let observationIDs = Set(observations.map(\.id))
        let allSetIDs = Set(allEvidenceSets.map(\.id))
        let currentSetIDs = Set(currentEvidenceSets.map(\.id))
        for set in allEvidenceSets {
            guard Set(set.memberObservationIDs).isSubset(of: observationIDs) else {
                throw EvidencePackageError
                    .invalidReference("EvidenceSet \(set.id) references an observation outside the incident.")
            }
        }
        guard Set(incident.observationIDs) == observationIDs else {
            throw EvidencePackageError.invalidReference("Incident membership does not match loaded observations.")
        }
        for inference in currentInferences {
            guard allSetIDs.contains(inference.evidenceSetID)
            else { throw EvidencePackageError.missingEvidenceSet(inference.evidenceSetID) }
            guard currentSetIDs.contains(inference.evidenceSetID) else {
                throw EvidencePackageError.invalidReference("Current inference references a historical EvidenceSet.")
            }
            let set = allEvidenceSets.first { $0.id == inference.evidenceSetID }!
            let support = Set(inference.supportingObservationIDs + inference.contradictingObservationIDs)
            guard support.isSubset(of: observationIDs), support.isSubset(of: Set(set.memberObservationIDs)) else {
                throw EvidencePackageError
                    .invalidReference("Inference \(inference.id) references an unsupported Observation.")
            }
            guard InitialInferenceRuleRegistry.production.definition(for: inference.ruleID) != nil else {
                throw EvidencePackageError.unsupportedInferenceRule(inference.ruleID)
            }
        }
    }

    private func makeVersionManifest(nextTestCatalogVersion: String) -> EvidencePackageVersionManifest {
        EvidencePackageVersionManifest(
            specificationVersion: Horizon2EvidenceConfiguration.specificationVersion,
            evidencePackageSchemaVersion: EvidencePackage.currentSchemaVersion,
            observationSchemaVersion: Observation.currentSchemaVersion,
            incidentPackageSchemaVersion: Horizon2EvidenceConfiguration.incidentPackageSchemaVersion,
            evidenceSetSchemaVersion: EvidenceSet.currentSchemaVersion,
            inferenceSchemaVersion: Inference.currentSchemaVersion,
            inferenceInputContractVersion: Inference.currentInputContractVersion,
            correlationRules: currentCorrelationRuleAuthorities,
            inferenceRules: currentInferenceRuleAuthorities,
            nextTestCatalogVersion: nextTestCatalogVersion,
            redactionPolicyVersion: EvidenceRedactionPolicy.currentVersion
        )
    }

    private var currentCorrelationRuleAuthorities: [EvidenceRuleVersion] {
        [
            EvidenceRuleVersion(ruleID: "H2-CORR-NETWORK-PATH-TRANSITION", version: "1.0.1"),
            EvidenceRuleVersion(ruleID: "H2-CORR-STORAGE-LIFECYCLE", version: "1.0.1")
        ]
    }

    private var currentInferenceRuleAuthorities: [EvidenceRuleVersion] {
        [
            EvidenceRuleVersion(ruleID: "EXTERNAL_STORAGE_LIFECYCLE", version: "1.0.0"),
            EvidenceRuleVersion(ruleID: "NETWORK_PATH_TRANSITION", version: "1.0.0")
        ]
    }

    // Why: complete canonical inputs.
    // swiftlint:disable:next function_parameter_count
    private func makePackageID(
        incident: IncidentPackage,
        observations: [Observation],
        evidenceSets: [EvidenceSet],
        inferences: [Inference],
        versionManifest: EvidencePackageVersionManifest,
        context: EvidenceValue
    ) throws -> UUID {
        let seed = try EvidencePackageIdentitySeed(
            incidentID: incident.id,
            incidentStatus: incident.status,
            markerTime: incident.marker.wallTime,
            contextDigest: digest(context.deterministicData()),
            observationDigests: observations.sorted(by: compareObservations).map { try digest($0.deterministicData()) },
            evidenceSetIDs: evidenceSets.map(\.id.uuidString),
            inferenceIDs: inferences.map(\.id.uuidString),
            schemaVersion: EvidencePackage.currentSchemaVersion,
            policyVersion: EvidenceRedactionPolicy.currentVersion,
            versionManifest: versionManifest
        )
        let data = try deterministicEncode(seed)
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        var uuidBytes = bytes
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    private func validateUnique(_ ids: [UUID], label: String) throws {
        guard ids.count == Set(ids).count else { throw EvidencePackageError.duplicateIdentifier(label) }
    }

    private func isInitialRule(_ ruleID: String?) -> Bool {
        guard let ruleID else { return false }
        return Horizon2EvidenceConfiguration.initialCorrelationRuleIDs.contains(ruleID)
    }
}

private struct EvidencePackageIdentitySeed: Codable {
    let incidentID: UUID
    let incidentStatus: IncidentCaptureStatus
    let markerTime: Date
    let contextDigest: String
    let observationDigests: [String]
    let evidenceSetIDs: [String]
    let inferenceIDs: [String]
    let schemaVersion: Int
    let policyVersion: String
    let versionManifest: EvidencePackageVersionManifest
}

struct EvidenceExportPreviewModel: Equatable, Sendable {
    let packageID: UUID
    let status: IncidentCaptureStatus
    let markerTime: Date
    let captureWindow: EvidenceTimeBounds
    let observations: [Observation]
    let inferences: [Inference]
    let unknowns: [EvidenceMissing]
    let nextTests: [NextTestCatalogEntry]
    let sourceManifest: [EvidenceSourceManifestEntry]
    let redactionManifest: [EvidenceRedactionManifestEntry]
    let versionManifest: EvidencePackageVersionManifest?

    init(package: EvidencePackage) throws {
        guard let incident = package.incident else {
            throw EvidencePackageError.invalidReference("Preview requires an incident-based package.")
        }
        packageID = package.id
        status = incident.status
        markerTime = incident.markerTime
        captureWindow = incident.captureWindow
        observations = package.observations
        inferences = package.inferences
        unknowns = package.unknowns
        nextTests = package.nextTestSnapshots
        sourceManifest = package.sourceManifest
        redactionManifest = package.redactionManifest
        versionManifest = package.versionManifest
    }
}

enum EvidencePackageJSONRenderer {
    static func render(_ package: EvidencePackage) throws -> Data {
        try deterministicEncode(package)
    }
}

enum EvidencePackageTextRenderer {
    // Why: ordered canonical flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func render(_ package: EvidencePackage) throws -> String {
        guard let incident = package.incident else {
            throw EvidencePackageError.rendererFailure("Human-readable export requires an incident package.")
        }
        var lines = [
            "Small Matter Evidence Package",
            "Package ID: \(package.id.uuidString)",
            "Status: \(incident.status.rawValue)",
            incident.status == .incomplete
                ? "IMPORTANT: This capture has known evidence or coverage gaps."
                : nil,
            incident.status == .incomplete
                ? "Do not interpret missing evidence as proof that an event did not occur."
                : nil,
            "Marker: \(iso8601(incident.markerTime))",
            "Window: \(iso8601(incident.captureWindow.start)) through \(iso8601(incident.captureWindow.end))",
            "",
            "WHAT WAS HAPPENING",
            humanWindowSummary(package.context),
            "",
            "CONTEXT",
            canonicalValue(package.context),
            "",
            "CHANGES OBSERVED"
        ].compactMap { $0 }
        let visibleObservations = IncidentChangeProjection.userVisibleObservations(package.observations)
        for observation in visibleObservations.sorted(by: compareObservations) {
            lines
                .append(
                    "- \(observation.id.uuidString) | \(observation.sourceID.rawValue) | " +
                        "\(observation.eventKind) | \(iso8601(observation.time.observedWallTime))"
                )
            lines.append("  state: \(canonicalValue(observation.currentState ?? .null))")
        }
        if visibleObservations.isEmpty {
            lines.append("No supported system transitions were observed during this capture window.")
        }
        lines.append("")
        lines.append("INTERPRETATION")
        if package.inferences.isEmpty {
            lines.append("No interpretation was generated because no qualifying change observation was captured.")
        }
        for inference in package.inferences.sorted(by: compareInferences) {
            lines.append("- \(inference.id.uuidString) | \(inference.ruleID) | \(inference.evidenceClass.rawValue)")
            lines.append("  hypothesis: \(canonicalValue(inference.hypothesis))")
            if !inference.supportingObservationIDs.isEmpty {
                let supportIDs = inference.supportingObservationIDs.map(\.uuidString).joined(separator: ", ")
                lines.append("  Observed support: \(supportIDs)")
            }
            if !inference.contradictingObservationIDs.isEmpty {
                let contradictionIDs = inference.contradictingObservationIDs.map(\.uuidString).joined(separator: ", ")
                lines.append("  Contradicting observation: \(contradictionIDs)")
            }
            for missing in inference.missingEvidence.sorted(by: compareUnknowns) {
                let sourceID = missing.sourceID?.rawValue ?? "NONE"
                lines.append("  Unknown: \(sourceID) | \(missing.reason.rawValue) | \(missing.explanation)")
            }
            if inference.ruleID == "NETWORK_PATH_TRANSITION" {
                lines.append("  Unknown: Physical cause was not established by this evidence.")
            }
            for alternative in inference.alternatives.sorted(by: { $0.hypothesis < $1.hypothesis }) {
                lines.append("  Alternative: \(alternative.hypothesis) — \(alternative.reason)")
            }
        }
        lines.append("")
        lines.append("UNKNOWN / LIMITATIONS")
        for unknown in package.unknowns.sorted(by: compareUnknowns) {
            lines
                .append(
                    "- \(unknown.sourceID?.rawValue ?? "NONE") | \(unknown.reason.rawValue) | \(unknown.explanation)"
                )
        }
        lines.append("")
        lines.append("NEXT TEST")
        for entry in package.nextTestSnapshots {
            lines.append("- \(entry.reference.testID) | \(entry.reference.purpose)")
            lines.append("  action: \(entry.userAction)")
            lines.append("  evidence expected: \(entry.reference.evidenceExpected)")
            if !entry.prerequisites.isEmpty {
                let prerequisites = entry.prerequisites.map(\.rawValue).joined(separator: ", ")
                lines.append("  prerequisites: \(prerequisites)")
            }
            lines.append("  risk: \(entry.riskClass.rawValue)")
            lines.append("  stopping: \(entry.stoppingCondition)")
            lines.append("  safety: \(entry.safetyWarning)")
        }
        lines.append("")
        lines.append("SOURCE MANIFEST")
        for entry in package.sourceManifest.sorted(by: { $0.sourceID.rawValue < $1.sourceID.rawValue }) {
            lines
                .append(
                    "- \(entry.sourceID.rawValue) | \(entry.disposition.rawValue) | " +
                        "observations: \(entry.includedObservationCount)"
                )
        }
        lines.append("")
        lines.append("REDACTION")
        lines.append("Policy: \(package.redactionPolicyVersion)")
        lines.append("Approved fields included unchanged")
        lines.append("Pseudonymized: \(package.redactionManifest.filter { $0.action == .pseudonymize }.count)")
        lines.append("Omitted: \(package.redactionManifest.filter { $0.action == .omit }.count)")
        for entry in package.redactionManifest.sorted(by: compareManifestEntries) {
            lines.append("- \(entry.path.rawValue) | \(entry.classification.rawValue) | \(entry.action.rawValue)")
        }
        lines.append("")
        lines.append("VERSIONS")
        if let versionManifest = package.versionManifest {
            lines.append(canonicalValue(.object([
                "specificationVersion": .string(versionManifest.specificationVersion),
                "evidencePackageSchemaVersion": .integer(Int64(versionManifest.evidencePackageSchemaVersion)),
                "observationSchemaVersion": .integer(Int64(versionManifest.observationSchemaVersion)),
                "incidentPackageSchemaVersion": .integer(Int64(versionManifest.incidentPackageSchemaVersion)),
                "evidenceSetSchemaVersion": .integer(Int64(versionManifest.evidenceSetSchemaVersion)),
                "inferenceSchemaVersion": .integer(Int64(versionManifest.inferenceSchemaVersion)),
                "inferenceInputContractVersion": .string(versionManifest.inferenceInputContractVersion),
                "nextTestCatalogVersion": .string(versionManifest.nextTestCatalogVersion),
                "redactionPolicyVersion": .string(versionManifest.redactionPolicyVersion)
            ])))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func canonicalValue(_ value: EvidenceValue) -> String {
        guard let data = try? value.deterministicData() else { return "<unavailable>" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func humanWindowSummary(_ context: EvidenceValue) -> String {
        guard case let .object(topLevel) = context,
              case let .object(window)? = topLevel["windowSummary"]
        else {
            return "Marker context recorded; no bounded telemetry history was available for this package."
        }
        let coverage = scalar(window["coverage"]) ?? "UNKNOWN"
        let samples = scalar(window["sampleCount"]) ?? "0"
        var result = "Coverage: \(coverage)\nSamples: \(samples)"
        if let mean = scalar(window["metric_cpuUtilizationPercent_mean"]) {
            result += "\nCPU mean across captured samples: \(mean)%"
        }
        if let pressure = scalar(window["state_memoryPressure"]) {
            result += "\nMemory pressure states: \(pressure)"
        }
        if let thermal = scalar(window["state_thermalState"]) {
            result += "\nThermal states: \(thermal)"
        }
        return result
    }

    private static func scalar(_ value: EvidenceValue?) -> String? {
        switch value {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .unsigned(value): return String(value)
        case let .decimal(value): return value
        case let .boolean(value): return value ? "true" : "false"
        default: return nil
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct EvidenceExportWriter {
    private let permissionVerifier: (URL) throws -> Void

    init(permissionVerifier: @escaping (URL) throws -> Void = { url in
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw EvidencePackageError.writeFailure("Could not verify export permissions.")
        }
    }) {
        self.permissionVerifier = permissionVerifier
    }

    func data(for package: EvidencePackage, format: EvidenceExportFormat) throws -> Data {
        switch format {
        case .json: return try EvidencePackageJSONRenderer.render(package)
        case .text: return try Data(EvidencePackageTextRenderer.render(package).utf8)
        }
    }

    func write(package: EvidencePackage, format: EvidenceExportFormat, to destination: URL) throws {
        let data = try data(for: package, format: format)
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw EvidencePackageError.writeFailure("Could not create the temporary export.")
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try permissionVerifier(temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw EvidencePackageError.writeFailure("Could not write the requested EvidencePackage export.")
        }
    }

    func defaultFilename(for package: EvidencePackage, format: EvidenceExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: package.captureWindow.start.addingTimeInterval(60))
        return "Small-Matter-Evidence-\(timestamp).\(format.filenameExtension)"
    }
}

private func deterministicEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func compareObservations(_ lhs: Observation, _ rhs: Observation) -> Bool {
    if lhs.time.observedWallTime != rhs.time.observedWallTime {
        return lhs.time.observedWallTime < rhs.time.observedWallTime
    }
    if lhs.time.localSequence != rhs.time.localSequence {
        return lhs.time.localSequence < rhs.time.localSequence
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func compareEvidenceSets(_ lhs: EvidenceSet, _ rhs: EvidenceSet) -> Bool {
    let left = "\(lhs.ruleID ?? "")|\(lhs.ruleVersion ?? "")"
    let right = "\(rhs.ruleID ?? "")|\(rhs.ruleVersion ?? "")"
    if left != right {
        return left < right
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func compareInferences(_ lhs: Inference, _ rhs: Inference) -> Bool {
    let left = "\(lhs.ruleID)|\(lhs.ruleVersion)"
    let right = "\(rhs.ruleID)|\(rhs.ruleVersion)"
    if left != right {
        return left < right
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func compareUnknowns(_ lhs: EvidenceMissing, _ rhs: EvidenceMissing) -> Bool {
    let left = "\(lhs.sourceID?.rawValue ?? "")|\(lhs.reason.rawValue)|\(lhs.explanation)"
    let right = "\(rhs.sourceID?.rawValue ?? "")|\(rhs.reason.rawValue)|\(rhs.explanation)"
    return left < right
}

private func compareManifestEntries(_ lhs: EvidenceRedactionManifestEntry,
                                    _ rhs: EvidenceRedactionManifestEntry) -> Bool {
    let left = "\(lhs.path.rawValue)|\(lhs.action.rawValue)|\(lhs.classification.rawValue)"
    let right = "\(rhs.path.rawValue)|\(rhs.action.rawValue)|\(rhs.classification.rawValue)"
    return left < right
}

private func uniqueRuleVersions(_ values: [EvidenceRuleVersion]) -> [EvidenceRuleVersion] {
    var seen = Set<String>()
    return values.filter { seen.insert("\($0.ruleID)|\($0.version)").inserted }
        .sorted {
            if $0.ruleID != $1.ruleID {
                return $0.ruleID < $1.ruleID
            }
            return $0.version < $1.version
        }
    // Why: cohesive reviewed boundary.
} // swiftlint:disable:this file_length
