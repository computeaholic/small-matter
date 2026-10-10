import Foundation

enum InferenceEngineError: Error, Equatable, Sendable {
    case invalidIncidentStatus
    case unsupportedRule(String)
    case unsupportedCorrelationInput(String)
    case invalidEvidenceSet(String)
    case missingObservation(UUID)
    case unlistedObservation(UUID)
    case duplicateObservation(UUID)
    case unsupportedSource(Horizon2SourceID)
    case unsupportedEventKind
    case invalidCatalog(String)
}

struct InferenceRuleDefinition: Equatable, Sendable {
    let id: String
    let version: String
    let acceptedCorrelationRuleID: String
    let acceptedCorrelationRuleVersion: String
    let acceptedEvidenceSetSchemaVersion: Int
    let supportedSource: Horizon2SourceID
    let supportedEventKinds: Set<String>
    let requiredNextTestIDs: [String]
}

enum InitialInferenceRule {
    static let version = "1.0.0"

    static let storage = InferenceRuleDefinition(
        id: "EXTERNAL_STORAGE_LIFECYCLE",
        version: version,
        acceptedCorrelationRuleID: "H2-CORR-STORAGE-LIFECYCLE",
        acceptedCorrelationRuleVersion: InitialCorrelationRule.currentVersion,
        acceptedEvidenceSetSchemaVersion: EvidenceSet.currentSchemaVersion,
        supportedSource: .storage,
        supportedEventKinds: ["STORAGE_DISK_LIFECYCLE", "STORAGE_MOUNT_LIFECYCLE"],
        requiredNextTestIDs: ["INSPECT_STORAGE_STATE"]
    )

    static let network = InferenceRuleDefinition(
        id: "NETWORK_PATH_TRANSITION",
        version: version,
        acceptedCorrelationRuleID: "H2-CORR-NETWORK-PATH-TRANSITION",
        acceptedCorrelationRuleVersion: InitialCorrelationRule.currentVersion,
        acceptedEvidenceSetSchemaVersion: EvidenceSet.currentSchemaVersion,
        supportedSource: .network,
        supportedEventKinds: ["NETWORK_PATH_TRANSITION"],
        requiredNextTestIDs: ["INSPECT_NETWORK_INTERFACE_STATE"]
    )
}

struct InitialInferenceRuleRegistry: Sendable {
    let definitions: [String: InferenceRuleDefinition]

    static let production = InitialInferenceRuleRegistry(definitions: [
        InitialInferenceRule.storage.id: InitialInferenceRule.storage,
        InitialInferenceRule.network.id: InitialInferenceRule.network
    ])

    func validateProductionInventory() -> Bool {
        Set(definitions.keys) == Horizon2EvidenceConfiguration.initialRuleIDs
    }

    func definition(for id: String) -> InferenceRuleDefinition? {
        definitions[id] ?? definitions.values.first { $0.acceptedCorrelationRuleID == id }
    }
}

private struct InferenceComponents {
    let hypothesis: EvidenceValue
    let evidenceClass: EvidenceClass
    let supporting: [UUID]
    let contradictions: [UUID]
    let alternatives: [EvidenceAlternative]
    let missing: [EvidenceMissing]
    let nextTests: [NextTestReference]
}

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
struct InferenceEngine: Sendable {
    let registry: InitialInferenceRuleRegistry
    let catalog: NextTestCatalogSnapshot

    init(
        registry: InitialInferenceRuleRegistry = .production,
        catalog: NextTestCatalogSnapshot = Horizon2NextTestCatalog.production
    ) {
        self.registry = registry
        self.catalog = catalog
    }

    // Why: explicit fail-closed matrix.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func evaluate(
        incident: IncidentPackage,
        evidenceSet: EvidenceSet,
        observations: [Observation]
    ) throws -> Inference {
        guard incident.status == .complete || incident.status == .incomplete else {
            throw InferenceEngineError.invalidIncidentStatus
        }
        guard registry.validateProductionInventory(),
              let ruleID = evidenceSet.ruleID,
              let definition = registry.definition(for: ruleID)
        else {
            throw InferenceEngineError.unsupportedRule(evidenceSet.ruleID ?? "missing")
        }
        guard evidenceSet.ruleVersion == definition.acceptedCorrelationRuleVersion,
              evidenceSet.evidenceSetSchemaVersion == definition.acceptedEvidenceSetSchemaVersion,
              evidenceSet.ruleID == definition.acceptedCorrelationRuleID
        else {
            throw InferenceEngineError.unsupportedCorrelationInput(
                "Only current correlation \(definition.acceptedCorrelationRuleID) " +
                    "\(definition.acceptedCorrelationRuleVersion) with EvidenceSet schema " +
                    "\(definition.acceptedEvidenceSetSchemaVersion) is eligible."
            )
        }
        _ = try catalog.validated()

        let memberIDs = evidenceSet.memberObservationIDs
        guard Set(memberIDs).count == memberIDs.count else {
            throw InferenceEngineError.invalidEvidenceSet("EvidenceSet contains duplicate members.")
        }
        var byID: [UUID: Observation] = [:]
        for observation in observations {
            guard byID[observation.id] == nil else {
                throw InferenceEngineError.duplicateObservation(observation.id)
            }
            byID[observation.id] = observation
        }
        for memberID in memberIDs where byID[memberID] == nil {
            throw InferenceEngineError.missingObservation(memberID)
        }
        for observationID in byID.keys where !memberIDs.contains(observationID) {
            throw InferenceEngineError.unlistedObservation(observationID)
        }
        let ordered = evidenceSet.memberObservationIDs.compactMap { byID[$0] }.sorted(by: canonicalOrder)
        guard ordered.allSatisfy({ $0.sourceID == definition.supportedSource }) else {
            throw InferenceEngineError
                .unsupportedSource(ordered.first(where: { $0.sourceID != definition.supportedSource })!.sourceID)
        }
        guard ordered.allSatisfy({ definition.supportedEventKinds.contains(eventCode($0.eventKind)) }) else {
            throw InferenceEngineError.unsupportedEventKind
        }

        switch definition.id {
        case InitialInferenceRule.storage.id:
            return try evaluateStorage(incident: incident, set: evidenceSet, observations: ordered, rule: definition)
        case InitialInferenceRule.network.id:
            return try evaluateNetwork(incident: incident, set: evidenceSet, observations: ordered, rule: definition)
        default:
            throw InferenceEngineError.unsupportedRule(definition.id)
        }
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private func evaluateStorage(
        incident: IncidentPackage,
        set: EvidenceSet,
        observations: [Observation],
        rule: InferenceRuleDefinition
    ) throws -> Inference {
        var support: [UUID] = []
        var contradictions: [UUID] = []
        var missing: [EvidenceMissing] = []
        var transitions: [String] = []
        let subjectTypes = observations.map { $0.subject.type.rawValue }

        for observation in observations {
            guard let lifecycle = lifecycleValue(for: observation) else {
                missing.append(EvidenceMissing(
                    sourceID: .storage,
                    reason: .notObserved,
                    explanation: "Storage lifecycle value was not observed."
                ))
                continue
            }
            if observation.eventKind == .storageDiskLifecycle,
               lifecycle == "volumeMounted" || lifecycle == "volumeUnmounted" {
                contradictions.append(observation.id)
                continue
            }
            if observation.eventKind == .storageMountLifecycle,
               lifecycle == "diskAppeared" || lifecycle == "diskDisappeared" {
                contradictions.append(observation.id)
                continue
            }
            guard ["diskAppeared", "diskDisappeared", "volumeMounted", "volumeUnmounted"].contains(lifecycle) else {
                missing.append(EvidenceMissing(
                    sourceID: .storage,
                    reason: .notObserved,
                    explanation: "Storage lifecycle value was not recognized."
                ))
                continue
            }
            support.append(observation.id)
            transitions.append(lifecycle)
        }

        appendRelevantUnknowns(from: incident, source: .storage, to: &missing)
        let subjectType = subjectTypes.first ?? "STORAGE_DISK"
        let hypothesis = EvidenceValue.object([
            "kind": .string(rule.id),
            "subjectType": .string(subjectType),
            "observedTransitions": .array(transitions.map(EvidenceValue.string))
        ])
        let refs = try references(for: rule)
        return makeInference(
            incident: incident,
            set: set,
            rule: rule,
            components: InferenceComponents(
                hypothesis: hypothesis,
                evidenceClass: support.isEmpty || !missing.isEmpty || !contradictions
                    .isEmpty ? .insufficientEvidence : .supported,
                supporting: support,
                contradictions: contradictions,
                alternatives: [],
                missing: missing,
                nextTests: refs
            )
        )
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private func evaluateNetwork(
        incident: IncidentPackage,
        set: EvidenceSet,
        observations: [Observation],
        rule: InferenceRuleDefinition
    ) throws -> Inference {
        var support: [UUID] = []
        var contradictions: [UUID] = []
        var missing: [EvidenceMissing] = []
        var states: [EvidenceValue] = []

        for observation in observations {
            guard let previous = statusValue(from: observation.previousState) else {
                missing.append(EvidenceMissing(
                    sourceID: .network,
                    reason: .notObserved,
                    explanation: "Network previous path state was not observed."
                ))
                continue
            }
            guard let current = statusValue(from: observation.currentState) else {
                missing.append(EvidenceMissing(
                    sourceID: .network,
                    reason: .notObserved,
                    explanation: "Network current path state was not observed."
                ))
                continue
            }
            guard previous != current else {
                contradictions.append(observation.id)
                continue
            }
            support.append(observation.id)
            states.append(.object(["previous": .string(previous), "current": .string(current)]))
        }

        appendRelevantUnknowns(from: incident, source: .network, to: &missing)
        let hypothesis = EvidenceValue.object([
            "kind": .string(rule.id),
            "observedPathStates": .array(states),
            "physicalCause": .string("UNKNOWN")
        ])
        let alternatives = [
            EvidenceAlternative(
                hypothesis: "A local physical-interface condition",
                reason: "This supplemental path evidence does not establish it."
            ),
            EvidenceAlternative(
                hypothesis: "A configuration or interface-selection change",
                reason: "This supplemental path evidence does not establish it."
            ),
            EvidenceAlternative(
                hypothesis: "An upstream router, network, or service condition",
                reason: "This supplemental path evidence does not establish it."
            )
        ]
        let refs = try references(for: rule)
        return makeInference(
            incident: incident,
            set: set,
            rule: rule,
            components: InferenceComponents(
                hypothesis: hypothesis,
                evidenceClass: support.isEmpty || !missing.isEmpty || !contradictions
                    .isEmpty ? .insufficientEvidence : .supported,
                supporting: support,
                contradictions: contradictions,
                alternatives: alternatives,
                missing: missing,
                nextTests: refs
            )
        )
    }

    private func references(for rule: InferenceRuleDefinition) throws -> [NextTestReference] {
        try rule.requiredNextTestIDs.map { id in
            guard let entry = catalog.entries.first(where: { $0.reference.testID == id }) else {
                throw InferenceEngineError.invalidCatalog("Missing catalog entry (id).")
            }
            return try entry.validatedReference()
        }
    }

    private func makeInference(
        incident: IncidentPackage,
        set: EvidenceSet,
        rule: InferenceRuleDefinition,
        components: InferenceComponents
    ) -> Inference {
        let generatedAt = incident.completedAt ?? incident.marker.wallTime
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let semanticData = (try? encoder.encode(incident)) ?? Data()
        let semanticDigest = EvidenceIdentityDigest.make(
            scope: "incident-semantics",
            material: [String(bytes: semanticData, encoding: .utf8) ?? ""]
        ) ?? ""
        let material = [
            set.id.uuidString,
            rule.id,
            rule.version,
            String(Inference.currentSchemaVersion),
            catalog.version,
            incident.id.uuidString,
            incident.status.rawValue,
            semanticDigest
        ]
        let id = EvidenceIdentityDigest.makeUUID(scope: "horizon2-inference", material: material)!
        return Inference(
            id: id,
            evidenceSetID: set.id,
            generatedAt: generatedAt,
            hypothesis: components.hypothesis,
            evidenceClass: components.evidenceClass,
            supportingObservationIDs: components.supporting,
            contradictingObservationIDs: components.contradictions,
            alternatives: components.alternatives,
            missingEvidence: components.missing,
            nextTests: components.nextTests,
            ruleID: rule.id,
            ruleVersion: rule.version,
            inferenceSchemaVersion: Inference.currentSchemaVersion,
            inputContractVersion: Inference.currentInputContractVersion
        )
    }

    private func appendRelevantUnknowns(
        from incident: IncidentPackage,
        source: Horizon2SourceID,
        to missing: inout [EvidenceMissing]
    ) {
        for unknown in incident.unknowns {
            let relevant = unknown.sourceID == source
                ||
                (unknown.sourceID == nil && incident
                    .status == .incomplete &&
                    (unknown.reason == .incompleteCapture || unknown.reason == .sourceCoverageGap))
            guard relevant, !missing.contains(unknown) else { continue }
            missing.append(unknown)
        }
    }

    private func lifecycleValue(for observation: Observation) -> String? {
        if let value = observation.attributes["lifecycle"], case let .string(lifecycle) = value {
            return lifecycle
        }
        guard case let .object(state)? = observation.currentState,
              case let .string(lifecycle)? = state["lifecycle"] else { return nil }
        return lifecycle
    }

    private func statusValue(from value: EvidenceValue?) -> String? {
        guard case let .object(state)? = value,
              case let .string(status)? = state["status"] else { return nil }
        return status
    }

    private func eventCode(_ kind: EvidenceEventKind) -> String {
        switch kind {
        case .storageDiskLifecycle: return "STORAGE_DISK_LIFECYCLE"
        case .storageMountLifecycle: return "STORAGE_MOUNT_LIFECYCLE"
        case .networkPathTransition: return "NETWORK_PATH_TRANSITION"
        default: return "UNSUPPORTED"
        }
    }

    private func canonicalOrder(_ lhs: Observation, _ rhs: Observation) -> Bool {
        if lhs.time.observedWallTime != rhs.time.observedWallTime {
            return lhs.time.observedWallTime < rhs.time.observedWallTime
        }
        if lhs.time.localSequence != rhs.time.localSequence {
            return lhs.time.localSequence < rhs.time.localSequence
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

extension Inference {
    var evidenceClassLabel: String {
        switch evidenceClass {
        case .supported: return "Supported"
        case .insufficientEvidence: return "Insufficient evidence"
        case .stronglySupported: return "Supported"
        case .plausible: return "Supported"
        }
        // Why: cohesive reviewed boundary.
    }
} // swiftlint:disable:this file_length
