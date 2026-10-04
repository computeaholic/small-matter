import Foundation

enum EvidenceRedactionAction: String, Codable, Equatable, Sendable {
    case include = "INCLUDE"
    case omit = "OMIT"
    case pseudonymize = "PSEUDONYMIZE"
}

struct EvidenceSourceManifestEntry: Codable, Equatable, Sendable {
    let sourceID: Horizon2SourceID
    let disposition: Horizon2SourceDisposition
    let userFacingEvidenceAllowed: Bool
    let includedObservationCount: Int

    init(
        sourceID: Horizon2SourceID,
        disposition: Horizon2SourceDisposition,
        userFacingEvidenceAllowed: Bool,
        includedObservationCount: Int = 0
    ) {
        self.sourceID = sourceID
        self.disposition = disposition
        self.userFacingEvidenceAllowed = userFacingEvidenceAllowed
        self.includedObservationCount = includedObservationCount
    }
}

struct EvidenceRedactionManifestEntry: Codable, Equatable, Sendable {
    let path: EvidenceFieldPath
    let classification: EvidenceSensitivity
    let action: EvidenceRedactionAction
    let method: String?
    let scope: String?

    init(
        path: EvidenceFieldPath,
        classification: EvidenceSensitivity,
        action: EvidenceRedactionAction,
        method: String? = nil,
        scope: String? = nil
    ) {
        self.path = path
        self.classification = classification
        self.action = action
        self.method = method
        self.scope = scope
    }
}

struct EvidenceRuleVersion: Codable, Equatable, Sendable {
    let ruleID: String
    let version: String
}

struct EvidencePackageVersionManifest: Codable, Equatable, Sendable {
    let specificationVersion: String
    let evidencePackageSchemaVersion: Int
    let observationSchemaVersion: Int
    let incidentPackageSchemaVersion: Int
    let evidenceSetSchemaVersion: Int
    let inferenceSchemaVersion: Int
    let inferenceInputContractVersion: String
    let correlationRules: [EvidenceRuleVersion]
    let inferenceRules: [EvidenceRuleVersion]
    let nextTestCatalogVersion: String
    let redactionPolicyVersion: String
}

struct EvidencePackageIncident: Codable, Equatable, Sendable {
    let id: UUID
    let status: IncidentCaptureStatus
    let markerTime: Date
    let captureWindow: EvidenceTimeBounds
    let unknowns: [EvidenceMissing]
}

struct EvidencePackage: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = Horizon2EvidenceConfiguration.evidencePackageSchemaVersion

    let id: UUID
    let evidencePackageSchemaVersion: Int
    let productIdentity: String
    let incident: EvidencePackageIncident?
    let captureWindow: EvidenceTimeBounds
    let context: EvidenceValue
    let currentState: EvidenceValue?
    let observations: [Observation]
    let evidenceSets: [EvidenceSet]
    let inferences: [Inference]
    let nextTestSnapshots: [NextTestCatalogEntry]
    let unknowns: [EvidenceMissing]
    let sourceManifest: [EvidenceSourceManifestEntry]
    let versionManifest: EvidencePackageVersionManifest?
    let redactionManifest: [EvidenceRedactionManifestEntry]
    let redactionPolicyVersion: String

    var schemaVersion: Int {
        evidencePackageSchemaVersion
    }

    var systemMetadata: EvidenceValue {
        context
    }

    var nextTests: [NextTestReference] {
        nextTestSnapshots.map(\.reference)
    }

    var exportPolicyVersion: String {
        redactionPolicyVersion
    }

    init(
        id: UUID,
        schemaVersion: Int = EvidencePackage.currentSchemaVersion,
        productIdentity: String,
        systemMetadata: EvidenceValue,
        captureWindow: EvidenceTimeBounds,
        currentState: EvidenceValue?,
        observations: [Observation],
        evidenceSets: [EvidenceSet],
        inferences: [Inference],
        unknowns: [EvidenceMissing],
        nextTests: [NextTestReference],
        sourceManifest: [EvidenceSourceManifestEntry],
        redactionManifest: [EvidenceRedactionManifestEntry],
        exportPolicyVersion: String
    ) {
        self.init(
            id: id,
            evidencePackageSchemaVersion: schemaVersion,
            productIdentity: productIdentity,
            incident: nil,
            captureWindow: captureWindow,
            context: systemMetadata,
            currentState: currentState,
            observations: observations,
            evidenceSets: evidenceSets,
            inferences: inferences,
            nextTestSnapshots: nextTests.map { reference in
                NextTestCatalogEntry(
                    reference: reference,
                    prerequisites: [],
                    riskClass: .safe,
                    actionKind: .inspect,
                    userAction: "",
                    stoppingCondition: "",
                    expectedObservations: "",
                    safetyWarning: "",
                    catalogProvenance: "compatibility"
                )
            },
            unknowns: unknowns,
            sourceManifest: sourceManifest,
            versionManifest: nil,
            redactionManifest: redactionManifest,
            redactionPolicyVersion: exportPolicyVersion
        )
    }

    init(
        id: UUID,
        evidencePackageSchemaVersion: Int = EvidencePackage.currentSchemaVersion,
        productIdentity: String,
        incident: EvidencePackageIncident,
        context: EvidenceValue,
        observations: [Observation],
        evidenceSets: [EvidenceSet],
        inferences: [Inference],
        nextTestSnapshots: [NextTestCatalogEntry],
        sourceManifest: [EvidenceSourceManifestEntry],
        versionManifest: EvidencePackageVersionManifest,
        redactionManifest: [EvidenceRedactionManifestEntry],
        redactionPolicyVersion: String
    ) {
        self.init(
            id: id,
            evidencePackageSchemaVersion: evidencePackageSchemaVersion,
            productIdentity: productIdentity,
            incident: incident,
            captureWindow: incident.captureWindow,
            context: context,
            currentState: nil,
            observations: observations,
            evidenceSets: evidenceSets,
            inferences: inferences,
            nextTestSnapshots: nextTestSnapshots,
            unknowns: incident.unknowns,
            sourceManifest: sourceManifest,
            versionManifest: versionManifest,
            redactionManifest: redactionManifest,
            redactionPolicyVersion: redactionPolicyVersion
        )
    }

    private init(
        id: UUID,
        evidencePackageSchemaVersion: Int,
        productIdentity: String,
        incident: EvidencePackageIncident?,
        captureWindow: EvidenceTimeBounds,
        context: EvidenceValue,
        currentState: EvidenceValue?,
        observations: [Observation],
        evidenceSets: [EvidenceSet],
        inferences: [Inference],
        nextTestSnapshots: [NextTestCatalogEntry],
        unknowns: [EvidenceMissing],
        sourceManifest: [EvidenceSourceManifestEntry],
        versionManifest: EvidencePackageVersionManifest?,
        redactionManifest: [EvidenceRedactionManifestEntry],
        redactionPolicyVersion: String
    ) {
        self.id = id
        self.evidencePackageSchemaVersion = evidencePackageSchemaVersion
        self.productIdentity = productIdentity
        self.incident = incident
        self.captureWindow = captureWindow
        self.context = context
        self.currentState = currentState
        self.observations = observations
        self.evidenceSets = evidenceSets
        self.inferences = inferences
        self.nextTestSnapshots = nextTestSnapshots
        self.unknowns = unknowns
        self.sourceManifest = sourceManifest
        self.versionManifest = versionManifest
        self.redactionManifest = redactionManifest
        self.redactionPolicyVersion = redactionPolicyVersion
    }

    func hasConsistentInferenceReferences() -> Bool {
        let observationsByID = Set(observations.map(\.id))
        let evidenceSetsByID = Dictionary(
            uniqueKeysWithValues: evidenceSets.map { ($0.id, Set($0.memberObservationIDs)) }
        )
        return inferences.allSatisfy { inference in
            guard let memberIDs = evidenceSetsByID[inference.evidenceSetID] else { return false }
            let referenced = Set(inference.supportingObservationIDs + inference.contradictingObservationIDs)
            return referenced.isSubset(of: observationsByID) && referenced.isSubset(of: memberIDs)
        }
    }
}
