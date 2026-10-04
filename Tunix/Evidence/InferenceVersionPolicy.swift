import Foundation

enum InferenceVersionPolicy {
    static func isCurrentEvidenceSet(_ evidenceSet: EvidenceSet) -> Bool {
        guard evidenceSet.evidenceSetSchemaVersion == EvidenceSet.currentSchemaVersion,
              evidenceSet.ruleVersion == InitialCorrelationRule.currentVersion,
              let ruleID = evidenceSet.ruleID
        else {
            return false
        }
        return Horizon2EvidenceConfiguration.initialCorrelationRuleIDs.contains(ruleID)
    }

    static func isCurrent(
        inference: Inference,
        evidenceSet: EvidenceSet?,
        approvedCatalogVersion: String = Horizon2NextTestCatalog.currentVersion
    ) -> Bool {
        guard let evidenceSet,
              isCurrentEvidenceSet(evidenceSet),
              inference.inferenceSchemaVersion == Inference.currentSchemaVersion,
              inference.inputContractVersion == Inference.currentInputContractVersion,
              inference.nextTests.allSatisfy({ reference in
                  reference.catalogVersion == approvedCatalogVersion
                      && Horizon2NextTestCatalog.production.entries.contains {
                          $0.reference.testID == reference.testID
                              && $0.reference.catalogVersion == reference.catalogVersion
                      }
              })
        else {
            return false
        }

        guard let definition = InitialInferenceRuleRegistry.production.definition(for: inference.ruleID) else {
            return false
        }
        return inference.ruleVersion == definition.version
            && evidenceSet.ruleID == definition.acceptedCorrelationRuleID
            && evidenceSet.ruleVersion == definition.acceptedCorrelationRuleVersion
            && evidenceSet.evidenceSetSchemaVersion == definition.acceptedEvidenceSetSchemaVersion
    }
}
