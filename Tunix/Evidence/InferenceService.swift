import Foundation

struct IncidentInferenceService: Sendable {
    let journal: any EvidenceJournal
    let engine: InferenceEngine

    init(
        journal: any EvidenceJournal,
        engine: InferenceEngine = InferenceEngine()
    ) {
        self.journal = journal
        self.engine = engine
    }

    func process(incidentID: UUID) async throws -> [Inference] {
        guard let incident = await journal.incident(id: incidentID) else {
            throw EvidenceJournalError.invalidIncident
        }
        let currentSets = await journal.evidenceSets(incidentID: incidentID)
            .filter(InferenceVersionPolicy.isCurrentEvidenceSet)
        var outputs: [Inference] = []
        var allEntries: [NextTestCatalogEntry] = []
        for evidenceSet in currentSets {
            let observations = await withTaskGroup(of: Observation?.self, returning: [Observation].self) { group in
                for observationID in evidenceSet.memberObservationIDs {
                    group.addTask { await journal.observation(id: observationID) }
                }
                var found: [Observation] = []
                for await observation in group {
                    if let observation {
                        found.append(observation)
                    }
                }
                return found
            }
            let inference = try engine.evaluate(
                incident: incident,
                evidenceSet: evidenceSet,
                observations: observations
            )
            outputs.append(inference)
            allEntries.append(contentsOf: inference.nextTests.compactMap { engine.catalog.entry(for: $0) })
        }
        try await journal.persistInferences(
            incidentID: incidentID,
            inferences: outputs,
            catalogEntries: allEntries
        )
        return outputs.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func currentInferences(incidentID: UUID) async -> [Inference] {
        await journal.inferences(incidentID: incidentID, currentOnly: true)
    }
}
