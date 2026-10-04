import Foundation

enum EvidenceClass: String, Codable, Equatable, Sendable {
    case stronglySupported = "STRONGLY_SUPPORTED"
    case supported = "SUPPORTED"
    case plausible = "PLAUSIBLE"
    case insufficientEvidence = "INSUFFICIENT_EVIDENCE"
}

struct EvidenceAlternative: Codable, Equatable, Sendable {
    let hypothesis: String
    let reason: String
}

struct EvidenceMissing: Codable, Equatable, Sendable {
    let sourceID: Horizon2SourceID?
    let reason: EvidenceUnknownReason
    let explanation: String
}

struct Inference: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    static let currentInputContractVersion = Horizon2EvidenceConfiguration.specificationVersion

    let id: UUID
    let evidenceSetID: UUID
    let generatedAt: Date
    let hypothesis: EvidenceValue
    let evidenceClass: EvidenceClass
    let supportingObservationIDs: [UUID]
    let contradictingObservationIDs: [UUID]
    let alternatives: [EvidenceAlternative]
    let missingEvidence: [EvidenceMissing]
    let nextTests: [NextTestReference]
    let ruleID: String
    let ruleVersion: String
    let inferenceSchemaVersion: Int
    let inputContractVersion: String

    /// Compatibility accessors for the pre-I7 model. These names are not
    /// independent authorities; they intentionally resolve to the explicit
    /// I7 schema/input-contract fields above.
    var schemaVersion: Int {
        inferenceSchemaVersion
    }

    var packageVersion: String {
        inputContractVersion
    }

    init(
        id: UUID,
        evidenceSetID: UUID,
        generatedAt: Date,
        hypothesis: EvidenceValue,
        evidenceClass: EvidenceClass,
        supportingObservationIDs: [UUID],
        contradictingObservationIDs: [UUID],
        alternatives: [EvidenceAlternative],
        missingEvidence: [EvidenceMissing],
        nextTests: [NextTestReference],
        ruleID: String,
        ruleVersion: String,
        inferenceSchemaVersion: Int = Inference.currentSchemaVersion,
        inputContractVersion: String = Inference.currentInputContractVersion,
        schemaVersion: Int? = nil,
        packageVersion: String? = nil
    ) {
        self.id = id
        self.evidenceSetID = evidenceSetID
        self.generatedAt = generatedAt
        self.hypothesis = hypothesis
        self.evidenceClass = evidenceClass
        self.supportingObservationIDs = supportingObservationIDs
        self.contradictingObservationIDs = contradictingObservationIDs
        self.alternatives = alternatives
        self.missingEvidence = missingEvidence
        self.nextTests = nextTests
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.inferenceSchemaVersion = schemaVersion ?? inferenceSchemaVersion
        self.inputContractVersion = packageVersion ?? inputContractVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case evidenceSetID
        case generatedAt
        case hypothesis
        case evidenceClass
        case supportingObservationIDs
        case contradictingObservationIDs
        case alternatives
        case missingEvidence
        case nextTests
        case ruleID
        case ruleVersion
        case inferenceSchemaVersion
        case inputContractVersion
        case legacySchemaVersion = "schemaVersion"
        case legacyPackageVersion = "packageVersion"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            evidenceSetID: container.decode(UUID.self, forKey: .evidenceSetID),
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            hypothesis: container.decode(EvidenceValue.self, forKey: .hypothesis),
            evidenceClass: container.decode(EvidenceClass.self, forKey: .evidenceClass),
            supportingObservationIDs: container.decode([UUID].self, forKey: .supportingObservationIDs),
            contradictingObservationIDs: container.decode([UUID].self, forKey: .contradictingObservationIDs),
            alternatives: container.decode([EvidenceAlternative].self, forKey: .alternatives),
            missingEvidence: container.decode([EvidenceMissing].self, forKey: .missingEvidence),
            nextTests: container.decode([NextTestReference].self, forKey: .nextTests),
            ruleID: container.decode(String.self, forKey: .ruleID),
            ruleVersion: container.decode(String.self, forKey: .ruleVersion),
            inferenceSchemaVersion: container.decodeIfPresent(Int.self, forKey: .inferenceSchemaVersion)
                ?? container.decodeIfPresent(Int.self, forKey: .legacySchemaVersion)
                ?? Inference.currentSchemaVersion,
            inputContractVersion: container.decodeIfPresent(String.self, forKey: .inputContractVersion)
                ?? container.decodeIfPresent(String.self, forKey: .legacyPackageVersion)
                ?? Inference.currentInputContractVersion
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(evidenceSetID, forKey: .evidenceSetID)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(hypothesis, forKey: .hypothesis)
        try container.encode(evidenceClass, forKey: .evidenceClass)
        try container.encode(supportingObservationIDs, forKey: .supportingObservationIDs)
        try container.encode(contradictingObservationIDs, forKey: .contradictingObservationIDs)
        try container.encode(alternatives, forKey: .alternatives)
        try container.encode(missingEvidence, forKey: .missingEvidence)
        try container.encode(nextTests, forKey: .nextTests)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(ruleVersion, forKey: .ruleVersion)
        try container.encode(inferenceSchemaVersion, forKey: .inferenceSchemaVersion)
        try container.encode(inputContractVersion, forKey: .inputContractVersion)
    }

    func referencesOnly(_ observationIDs: Set<UUID>) -> Bool {
        Set(supportingObservationIDs).isSubset(of: observationIDs)
            && Set(contradictingObservationIDs).isSubset(of: observationIDs)
    }
}
