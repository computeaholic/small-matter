// swiftlint:disable line_length function_parameter_count trailing_comma function_body_length cyclomatic_complexity type_body_length
import Foundation

enum RecentChangesFixture {
    static func journal(arguments: [String]) -> any EvidenceJournal {
        #if DEBUG
            let incidentMode = incidentMode(arguments: arguments)
            if incidentMode == "unavailable" {
                return InMemoryEvidenceJournal(availability: .unavailable)
            }
            if incidentMode == "capacity" {
                return InMemoryEvidenceJournal(availability: .capacityUnavailable)
            }
            if let incidentMode, [
                "history", "incomplete", "capacity-complete", "capacity-incomplete", "package-failure",
            ].contains(incidentMode) {
                let fixtureMode: String
                let availability: EvidenceJournalAvailability
                switch incidentMode {
                case "capacity-complete":
                    fixtureMode = "history"
                    availability = .capacityUnavailable
                case "capacity-incomplete":
                    fixtureMode = "incomplete"
                    availability = .capacityUnavailable
                default:
                    fixtureMode = incidentMode
                    availability = .available
                }
                return InMemoryEvidenceJournal(
                    observations: observations,
                    incidents: incidentPackages(mode: fixtureMode),
                    availability: availability
                )
            }
            guard let mode = arguments.first(where: { $0.hasPrefix("-UITestingRecentChanges=") })?
                .split(separator: "=", maxSplits: 1)
                .last
                .map(String.init)
            else {
                return InMemoryEvidenceJournal()
            }
            switch mode {
            case "loaded":
                return InMemoryEvidenceJournal(observations: observations)
            case "empty":
                return InMemoryEvidenceJournal()
            case "unavailable":
                return InMemoryEvidenceJournal(availability: .unavailable)
            case "capacity":
                return InMemoryEvidenceJournal(availability: .capacityUnavailable)
            case "incomplete":
                return InMemoryEvidenceJournal(
                    observations: observations,
                    healthRecords: [incompleteHealthRecord]
                )
            case "unknown":
                return InMemoryEvidenceJournal(observations: [unknownObservation])
            default:
                return InMemoryEvidenceJournal()
            }
        #else
            return InMemoryEvidenceJournal()
        #endif
    }

    #if DEBUG
        static func incidentMode(arguments: [String]) -> String? {
            arguments.first(where: { $0.hasPrefix("-UITestingIncident=") })?
                .split(separator: "=", maxSplits: 1)
                .last
                .map(String.init)
        }

        static func seedIncidentFixture(
            mode: String,
            journal: any EvidenceJournal,
            processRunID: UUID
        ) async {
            guard ![
                "idle", "unavailable", "capacity", "history", "incomplete",
                "capacity-complete", "capacity-incomplete", "package-failure",
            ].contains(mode) else { return }

            let context = EvidenceValue.object([
                "system": .object(["cpuUtilizationPercent": .decimal("12.50")]),
                "battery": .object(["acConnected": .boolean(true)]),
                "cooling": .object([:]),
            ])
            let markerDate = mode == "capturing" ? Date() : baseDate.addingTimeInterval(240)
            let observationsInWindow = observations.map(\.id)

            switch mode {
            case "capturing":
                let session = IncidentCaptureSession(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
                        wallTime: markerDate
                    ),
                    startedAt: markerDate,
                    processRunID: processRunID,
                    materializedContext: context,
                    observationIDs: []
                )
                try? await journal.beginIncidentCapture(session)
            case "history":
                await seedCompletedPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
                    markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
                    markerDate: markerDate,
                    context: context,
                    observationIDs: observationsInWindow,
                    journal: journal
                )
                await seedCompletedPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                    markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
                    markerDate: markerDate.addingTimeInterval(-180),
                    context: context,
                    observationIDs: Array(observationsInWindow.prefix(3)),
                    journal: journal
                )
            case "incomplete":
                let package = IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000314")!,
                        wallTime: markerDate
                    ),
                    status: .incomplete,
                    completedAt: markerDate,
                    materializedContext: context,
                    observationIDs: Array(observationsInWindow.prefix(2)),
                    unknowns: [EvidenceMissing(sourceID: nil, reason: .processInterrupted, explanation: "Small Matter was closed before this capture finished.")],
                    failureReason: .processInterrupted
                )
                try? await journal.finalizeIncidentCapture(package)
            case "zero-event", "storage-inference-supported", "volume-inference-supported", "network-inference-supported", "network-inference-alternatives", "inference-insufficient", "inference-none", "export-supported", "export-redacted", "export-power-only":
                let selected: [Observation]
                switch mode {
                case "storage-inference-supported": selected = [observations[0]]
                case "volume-inference-supported": selected = [observations[1]]
                case "network-inference-supported", "network-inference-alternatives": selected = [observations[3]]
                case "export-supported", "export-redacted": selected = [observations[0], observations[3]]
                case "export-power-only": selected = [observations[2]]
                case "inference-insufficient":
                    try? await journal.append(networkNoTransitionObservation)
                    selected = [networkNoTransitionObservation]
                default: selected = []
                }
                await seedCompletedPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
                    markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000315")!,
                    markerDate: markerDate,
                    context: context,
                    observationIDs: selected.map(\.id),
                    journal: journal
                )
            case "export-incomplete":
                let package = IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000315")!,
                        wallTime: markerDate
                    ),
                    status: .incomplete,
                    completedAt: nil,
                    materializedContext: context,
                    observationIDs: [observations[0].id],
                    unknowns: [EvidenceMissing(sourceID: .network, reason: .incompleteCapture, explanation: "Network capture ended before the incident was complete.")],
                    failureReason: .incompleteCapture
                )
                try? await journal.finalizeIncidentCapture(package)
            case "inference-multi-source":
                await seedCompletedPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
                    markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000315")!,
                    markerDate: markerDate,
                    context: context,
                    observationIDs: [observations[0].id, observations[2].id, observations[3].id],
                    journal: journal
                )
            case "inference-current-and-historical":
                await seedCurrentAndHistoricalPackage(
                    markerDate: markerDate,
                    context: context,
                    observation: observations[0],
                    journal: journal
                )
            case "inference-snapshot":
                await seedSnapshotPackage(
                    markerDate: markerDate,
                    context: context,
                    observation: observations[0],
                    journal: journal
                )
            default:
                break
            }
        }

        private static func seedCompletedPackage(
            id: UUID,
            markerID: UUID,
            markerDate: Date,
            context: EvidenceValue,
            observationIDs: [UUID],
            journal: any EvidenceJournal
        ) async {
            let package = IncidentPackage(
                id: id,
                marker: IncidentMarker(markerID: markerID, wallTime: markerDate),
                status: .complete,
                completedAt: markerDate.addingTimeInterval(120),
                materializedContext: context,
                observationIDs: observationIDs
            )
            try? await journal.finalizeIncidentCapture(package)
            _ = try? await IncidentCorrelationService(journal: journal).process(incidentID: package.id)
            _ = try? await IncidentInferenceService(journal: journal).process(incidentID: package.id)
        }

        private static func seedCurrentAndHistoricalPackage(
            markerDate: Date,
            context: EvidenceValue,
            observation: Observation,
            journal: any EvidenceJournal
        ) async {
            let package = makePackage(markerDate: markerDate, context: context, observationIDs: [observation.id])
            try? await journal.finalizeIncidentCapture(package)
            _ = try? await IncidentCorrelationService(journal: journal).process(incidentID: package.id)
            _ = try? await IncidentInferenceService(journal: journal).process(incidentID: package.id)
            guard let currentSet = await journal.evidenceSets(incidentID: package.id).first,
                  let currentInference = await journal.inferences(incidentID: package.id, currentOnly: false).first
            else { return }
            let legacySet = EvidenceSet(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000306")!,
                members: currentSet.members,
                ruleID: currentSet.ruleID,
                ruleVersion: InitialCorrelationRule.legacyVersion,
                temporalBounds: currentSet.temporalBounds,
                orderingQuality: currentSet.orderingQuality,
                evidenceSetSchemaVersion: EvidenceSet.legacySchemaVersion
            )
            let legacyInference = Inference(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000307")!,
                evidenceSetID: legacySet.id,
                generatedAt: currentInference.generatedAt,
                hypothesis: currentInference.hypothesis,
                evidenceClass: currentInference.evidenceClass,
                supportingObservationIDs: currentInference.supportingObservationIDs,
                contradictingObservationIDs: currentInference.contradictingObservationIDs,
                alternatives: currentInference.alternatives,
                missingEvidence: currentInference.missingEvidence,
                nextTests: currentInference.nextTests,
                ruleID: currentInference.ruleID,
                ruleVersion: currentInference.ruleVersion,
                inferenceSchemaVersion: currentInference.inferenceSchemaVersion,
                inputContractVersion: currentInference.inputContractVersion
            )
            try? await journal.persistEvidenceSets(incidentID: package.id, sets: [legacySet])
            try? await journal.persistInferences(
                incidentID: package.id,
                inferences: [legacyInference],
                catalogEntries: Horizon2NextTestCatalog.production.entries
            )
        }

        private static func seedSnapshotPackage(
            markerDate: Date,
            context: EvidenceValue,
            observation: Observation,
            journal: any EvidenceJournal
        ) async {
            let package = makePackage(markerDate: markerDate, context: context, observationIDs: [observation.id])
            try? await journal.finalizeIncidentCapture(package)
            _ = try? await IncidentCorrelationService(journal: journal).process(incidentID: package.id)
            guard let set = await journal.evidenceSets(incidentID: package.id).first else { return }
            let base = Horizon2NextTestCatalog.production.entries[0]
            let snapshotReference = NextTestReference(
                testID: base.reference.testID,
                catalogVersion: base.reference.catalogVersion,
                purpose: "Confirm the persisted fixture storage presentation.",
                evidenceExpected: "The fixture storage disk lifecycle fact is visible."
            )
            let snapshotEntry = NextTestCatalogEntry(
                reference: snapshotReference,
                prerequisites: base.prerequisites,
                prerequisiteExplanation: base.prerequisiteExplanation,
                riskClass: base.riskClass,
                actionKind: base.actionKind,
                userAction: "Record the persisted fixture storage presentation.",
                stoppingCondition: "Stop after the fixture storage presentation is recorded.",
                expectedObservations: "The fixture storage disk lifecycle fact is visible.",
                safetyWarning: "This persisted fixture does not change storage state.",
                catalogProvenance: "Horizon 2 I7.1 snapshot fixture"
            )
            let snapshot = NextTestCatalogSnapshot(version: Horizon2NextTestCatalog.currentVersion, entries: [snapshotEntry])
            guard let inference = try? InferenceEngine(catalog: snapshot).evaluate(
                incident: package,
                evidenceSet: set,
                observations: [observation]
            ) else { return }
            try? await journal.persistInferences(
                incidentID: package.id,
                inferences: [inference],
                catalogEntries: [snapshotEntry]
            )
        }

        private static func makePackage(
            markerDate: Date,
            context: EvidenceValue,
            observationIDs: [UUID]
        ) -> IncidentPackage {
            IncidentPackage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
                marker: IncidentMarker(
                    markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000315")!,
                    wallTime: markerDate
                ),
                status: .complete,
                completedAt: markerDate.addingTimeInterval(120),
                materializedContext: context,
                observationIDs: observationIDs
            )
        }
    #endif

    #if DEBUG
        private static let processRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        private static let correlationEpochID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        private static let baseDate = Date(timeIntervalSince1970: 1_735_689_600)

        private static func incidentPackages(mode: String) -> [IncidentPackage] {
            let context = EvidenceValue.object([
                "system": .object(["cpuUtilizationPercent": .decimal("12.50")]),
                "battery": .object(["acConnected": .boolean(true)]),
                "cooling": .object([:]),
            ])
            let ids = observations.map(\.id)
            let markerDate = baseDate.addingTimeInterval(240)
            if mode == "package-failure" {
                return [IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000306")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000316")!,
                        wallTime: markerDate
                    ),
                    status: .complete,
                    completedAt: markerDate.addingTimeInterval(120),
                    materializedContext: context,
                    observationIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000399")!]
                )]
            }
            if mode == "incomplete" {
                return [IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000314")!,
                        wallTime: markerDate
                    ),
                    status: .incomplete,
                    completedAt: markerDate,
                    materializedContext: context,
                    observationIDs: Array(ids.prefix(2)),
                    unknowns: [EvidenceMissing(sourceID: nil, reason: .processInterrupted, explanation: "Small Matter was closed before this capture finished.")],
                    failureReason: .processInterrupted
                )]
            }
            return [
                IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
                        wallTime: markerDate
                    ),
                    status: .complete,
                    completedAt: markerDate.addingTimeInterval(120),
                    materializedContext: context,
                    observationIDs: ids
                ),
                IncidentPackage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                    marker: IncidentMarker(
                        markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
                        wallTime: markerDate.addingTimeInterval(-180)
                    ),
                    status: .complete,
                    completedAt: markerDate.addingTimeInterval(-60),
                    materializedContext: context,
                    observationIDs: Array(ids.prefix(3))
                ),
            ]
        }

        private static var observations: [Observation] {
            [
                observation(
                    id: "00000000-0000-0000-0000-000000000101",
                    sequence: 1,
                    domain: .storage,
                    eventKind: .storageDiskLifecycle,
                    sourceID: .storage,
                    subject: EvidenceSubject(type: .storageDisk, identityDigest: "fixture-storage-digest", quality: .qualified, safeDisplayLabel: "External storage disk"),
                    source: "Disk Arbitration",
                    currentState: .object(["lifecycle": .string("diskAppeared")]),
                    attributes: ["lifecycle": .string("diskAppeared"), "identityQuality": .string("QUALIFIED"), "isWholeDisk": .boolean(true)]
                ),
                observation(
                    id: "00000000-0000-0000-0000-000000000102",
                    sequence: 2,
                    domain: .storage,
                    eventKind: .storageMountLifecycle,
                    sourceID: .storage,
                    subject: EvidenceSubject(type: .mountedVolume, identityDigest: "fixture-volume-digest", quality: .weak, safeDisplayLabel: "Mounted storage volume"),
                    source: "NSWorkspace",
                    currentState: .object(["lifecycle": .string("volumeMounted")]),
                    attributes: ["lifecycle": .string("volumeMounted"), "identityQuality": .string("WEAK")]
                ),
                observation(
                    id: "00000000-0000-0000-0000-000000000103",
                    sequence: 3,
                    domain: .power,
                    eventKind: .powerSourceTransition,
                    sourceID: .power,
                    subject: EvidenceSubject(type: .powerSource, identityDigest: "power-source", quality: .provenStable, safeDisplayLabel: "Direct power source"),
                    source: "IOPowerSources",
                    previousState: .object(["source": .string("AC"), "externalPowerConnected": .boolean(true)]),
                    currentState: .object(["source": .string("BATTERY"), "externalPowerConnected": .boolean(false)]),
                    attributes: ["transition": .string("POWER_SOURCE")]
                ),
                observation(
                    id: "00000000-0000-0000-0000-000000000104",
                    sequence: 4,
                    domain: .network,
                    eventKind: .networkPathTransition,
                    sourceID: .network,
                    subject: EvidenceSubject(type: .networkInterface, identityDigest: nil, quality: .unavailable, safeDisplayLabel: "Network path"),
                    source: "Network.framework",
                    previousState: .object(["status": .string("SATISFIED"), "interfaces": .array([.string("WIRED_ETHERNET")])]),
                    currentState: .object(["status": .string("UNSATISFIED"), "interfaces": .array([])]),
                    attributes: ["supplemental": .boolean(true), "interfaceTypes": .array([])]
                ),
                unknownObservation,
            ]
        }

        private static let unknownObservation = observation(
            id: "00000000-0000-0000-0000-000000000105",
            sequence: 5,
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            sourceID: .storage,
            subject: EvidenceSubject(type: .storageDisk, identityDigest: nil, quality: .unavailable, safeDisplayLabel: "Storage disk"),
            source: "Disk Arbitration",
            availability: .unknown(.identityUnavailable),
            attributes: ["lifecycle": .string("diskDisappeared")]
        )

        private static let networkNoTransitionObservation = observation(
            id: "00000000-0000-0000-0000-000000000106",
            sequence: 6,
            domain: .network,
            eventKind: .networkPathTransition,
            sourceID: .network,
            subject: EvidenceSubject(type: .networkInterface, identityDigest: nil, quality: .unavailable, safeDisplayLabel: "Network path"),
            source: "Network.framework",
            previousState: .object(["status": .string("SATISFIED")]),
            currentState: .object(["status": .string("SATISFIED")]),
            attributes: ["supplemental": .boolean(true)]
        )

        private static let incompleteHealthRecord = EvidenceSourceHealthRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            sourceID: .storage,
            event: .sourceUnavailable,
            reason: .incompleteCapture,
            suppressedCount: 2,
            observedAt: baseDate.addingTimeInterval(3600),
            detail: "fixture coverage warning"
        )

        private static func observation(
            id: String,
            sequence: UInt64,
            domain: EvidenceDomain,
            eventKind: EvidenceEventKind,
            sourceID: Horizon2SourceID,
            subject: EvidenceSubject,
            source: String,
            availability: EvidenceAvailability = .available,
            previousState: EvidenceValue? = nil,
            currentState: EvidenceValue? = nil,
            attributes: [String: EvidenceValue]
        ) -> Observation {
            Observation(
                id: UUID(uuidString: id)!,
                domain: domain,
                eventKind: eventKind,
                sourceID: sourceID,
                subject: subject,
                provenance: EvidenceProvenance(
                    sourceID: sourceID,
                    apiName: source,
                    apiVersion: nil,
                    captureChannel: "UI fixture",
                    sourceTimestampQuality: .exact,
                    normalizationRuleID: "I4_FIXTURE",
                    normalizationRuleVersion: "1.0.0",
                    hostScope: .supportedProductBehavior,
                    rawReferenceDigest: nil
                ),
                time: EvidenceTime(
                    observedWallTime: baseDate.addingTimeInterval(Double(sequence) * 60),
                    continuousNanoseconds: UInt64(sequence) * 1_000_000_000,
                    processUptimeNanoseconds: UInt64(sequence) * 1_000_000_000,
                    processRunID: processRunID,
                    bootSessionID: "fixture-boot",
                    localSequence: sequence,
                    sourceTimestampQuality: .exact,
                    orderingDomain: EvidenceOrderingDomain(sourceID: sourceID, processRunID: processRunID, clockDomainID: "fixture-clock"),
                    sourceOccurrence: EvidenceSourceOccurrence(wallTime: baseDate, continuousNanoseconds: UInt64(sequence) * 1_000_000_000, quality: .exact),
                    correlationEpochID: correlationEpochID
                ),
                availability: availability,
                previousState: previousState,
                currentState: currentState,
                attributes: attributes,
                sensitivity: fixtureSensitivity(previousState: previousState, currentState: currentState, attributes: attributes)
            )
        }

        private static func fixtureSensitivity(
            previousState: EvidenceValue?,
            currentState: EvidenceValue?,
            attributes: [String: EvidenceValue]
        ) -> EvidenceSensitivityRegistry {
            var fields: [EvidenceFieldSensitivity] = []
            appendFixtureFields(&fields, value: previousState, prefix: "previousState")
            appendFixtureFields(&fields, value: currentState, prefix: "currentState")
            appendFixtureFields(&fields, value: .object(attributes), prefix: "attributes")
            return EvidenceSensitivityRegistry(fields: fields)
        }

        private static func appendFixtureFields(
            _ fields: inout [EvidenceFieldSensitivity],
            value: EvidenceValue?,
            prefix: String
        ) {
            guard let value else { return }
            switch value {
            case let .object(values):
                for key in values.keys.sorted() {
                    appendFixtureFields(&fields, value: values[key], prefix: "\(prefix).\(key)")
                }
            case let .array(values):
                if values.isEmpty {
                    fields.append(EvidenceFieldSensitivity(path: EvidenceFieldPath(prefix), classification: .none, pseudonymization: .notApplicable))
                } else {
                    fields.append(EvidenceFieldSensitivity(path: EvidenceFieldPath("\(prefix)[*]"), classification: .none, pseudonymization: .notApplicable))
                }
            default:
                fields.append(EvidenceFieldSensitivity(path: EvidenceFieldPath(prefix), classification: .none, pseudonymization: .notApplicable))
            }
        }
    #endif
}

// swiftlint:enable line_length function_parameter_count trailing_comma
