import Foundation
@testable import Tunix
import XCTest

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
final class EvidenceExportTests: XCTestCase {
    func testSystemHealthHistoryFixtureAssemblesCanonicalPackage() async throws {
        let journal = RecentChangesFixture.journal(arguments: ["-UITestingIncident=history"])
        let summaries = await journal.incidentSummaries(limit: 1)
        let incident = try XCTUnwrap(summaries.first)
        _ = try await EvidencePackageAssembler().assemble(incidentID: incident.id, journal: journal)
    }

    func testPackageAssemblyIsDeterministicAndCurrentOnly() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let assembler = EvidencePackageAssembler()
        let first = try await assembler.assemble(incidentID: incidentID, journal: journal)
        let second = try await assembler.assemble(incidentID: incidentID, journal: journal)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try EvidencePackageJSONRenderer.render(first), try EvidencePackageJSONRenderer.render(second))
        XCTAssertEqual(try EvidencePackageTextRenderer.render(first), try EvidencePackageTextRenderer.render(second))
        XCTAssertEqual(first.evidenceSets.count, 1)
        XCTAssertEqual(first.inferences.count, 1)
        XCTAssertEqual(first.nextTestSnapshots.count, 1)
    }

    func testPackageAssemblyIsStableAcrossOneHundredBuildsAndSQLiteReopen() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let assembler = EvidencePackageAssembler()
        let first = try await assembler.assemble(incidentID: incidentID, journal: journal)
        for _ in 0 ..< 100 {
            let rebuilt = try await assembler.assemble(incidentID: incidentID, journal: journal)
            XCTAssertEqual(rebuilt, first)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "horizon2-i8-sqlite-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let sqlite = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let observation = storageObservation()
        try await sqlite.append(observation)
        let incident = journalIncident(observation: observation)
        try await sqlite.persist(incident: incident)
        let sets = try CorrelationEngine().correlate(incident: incident, observations: [observation])
        try await sqlite.persistEvidenceSets(incidentID: incident.id, sets: sets)
        let inferences = try sets.map { try InferenceEngine().evaluate(
            incident: incident,
            evidenceSet: $0,
            observations: [observation]
        ) }
        try await sqlite.persistInferences(
            incidentID: incident.id,
            inferences: inferences,
            catalogEntries: Horizon2NextTestCatalog.production.entries
        )
        let beforeReopen = try await assembler.assemble(incidentID: incident.id, journal: sqlite)
        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let afterReopen = try await assembler.assemble(incidentID: incident.id, journal: reopened)
        XCTAssertEqual(beforeReopen, afterReopen)
        XCTAssertEqual(
            try EvidencePackageJSONRenderer.render(beforeReopen),
            try EvidencePackageJSONRenderer.render(afterReopen)
        )
    }

    func testPackageJSONRoundTripAndPreviewDeriveFromCanonicalPackage() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        let data = try EvidencePackageJSONRenderer.render(package)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EvidencePackage.self, from: data)
        let preview = try EvidenceExportPreviewModel(package: package)

        XCTAssertEqual(decoded, package)
        XCTAssertEqual(preview.packageID, package.id)
        XCTAssertEqual(preview.observations, package.observations)
        XCTAssertEqual(preview.inferences, package.inferences)
        XCTAssertEqual(preview.redactionManifest, package.redactionManifest)
    }

    func testRedactionHandlesNestedArraysOptionalValuesAndSentinels() throws {
        let observation = nestedSensitiveObservation()
        let result = try EvidenceRedactionPolicy.redact(
            observation: observation,
            packageScope: incidentID.uuidString
        )
        let encoded = try XCTUnwrap(String(bytes: result.observation.deterministicData(), encoding: .utf8))

        XCTAssertFalse(encoded.contains("JEFF_PRIVATE_VOLUME_SENTINEL"))
        XCTAssertFalse(encoded.contains("JEFF_PRIVATE_PATH_SENTINEL"))
        XCTAssertTrue(encoded.contains("JEFF_SAFE_ATTRIBUTE"))
        XCTAssertTrue(result.manifest
            .contains { $0.action == .pseudonymize && $0.path.rawValue.contains("volumeName") })
        XCTAssertTrue(result.manifest.contains { $0.action == .omit && $0.path.rawValue.contains("filesystemPath") })
        XCTAssertTrue(result.manifest
            .contains { $0.action == .pseudonymize && $0.path.rawValue.contains("interfaces") })
    }

    func testPseudonymizationIsStableWithinPackageAndDifferentAcrossScopes() throws {
        let observation = nestedSensitiveObservation()
        let first = try EvidenceRedactionPolicy.redact(observation: observation, packageScope: "scope-a")
        let repeated = try EvidenceRedactionPolicy.redact(observation: observation, packageScope: "scope-a")
        let different = try EvidenceRedactionPolicy.redact(observation: observation, packageScope: "scope-b")

        XCTAssertEqual(first.observation, repeated.observation)
        XCTAssertNotEqual(first.observation, different.observation)
    }

    func testUnclassifiedDynamicFieldFailsClosedBeforeRendering() throws {
        let observation = try Observation(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000221")),
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            sourceID: .storage,
            subject: EvidenceSubject(
                type: .storageDisk,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: nil
            ),
            provenance: provenance,
            time: time,
            attributes: ["futureSecret": .string("JEFF_PRIVATE_FUTURE_SECRET")]
        )

        XCTAssertThrowsError(try EvidenceRedactionPolicy.redact(
            observation: observation,
            packageScope: "scope"
        )) { error in
            XCTAssertEqual(error as? EvidencePackageError, .unclassifiedField("attributes.futureSecret"))
        }
    }

    func testUnknownContextFieldFailsClosed() {
        XCTAssertThrowsError(try EvidenceRedactionPolicy.redactContext(.object([
            "system": .object(["futureSecret": .string("JEFF_PRIVATE_CONTEXT_SENTINEL")])
        ]))) { error in
            XCTAssertEqual(error as? EvidencePackageError, .unclassifiedField("context.system.futureSecret"))
        }
    }

    // swiftlint:disable:next function_body_length
    func testPersistedBuild7CoolingContextAssemblesAndExports() async throws {
        let incident = IncidentPackage(
            id: incidentID,
            marker: IncidentMarker(markerID: UUID(), wallTime: markerDate),
            status: .incomplete,
            completedAt: nil,
            materializedContext: .object([
                "system": .object(["thermalState": .string("Nominal")]),
                "network": .object([:]),
                "battery": .object(["present": .boolean(true)]),
                "cooling": .object([
                    "thermalState": .string("Nominal"),
                    "thermalStateSource": .string("ProcessInfo")
                ]),
                "windowSummary": .object([
                    "sampleCount": .unsigned(0),
                    "coverage": .string("PARTIAL")
                ])
            ]),
            observationIDs: [],
            unknowns: [EvidenceMissing(
                sourceID: nil,
                reason: .sourceCoverageGap,
                explanation: "Telemetry context covered 0 samples from partial window coverage."
            )]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "issue-14-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        try await journal.persist(incident: incident)

        let reopened = try SQLiteEvidenceJournal(databaseURL: databaseURL)
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: reopened)
        guard case let .object(contextFields) = package.context,
              case let .object(cooling)? = contextFields[EvidenceContextSchema.cooling]
        else {
            return XCTFail("The cooling context was not preserved in the assembled package.")
        }
        XCTAssertEqual(cooling[EvidenceContextSchema.Field.thermalState], .string("Nominal"))
        XCTAssertEqual(cooling[EvidenceContextSchema.Field.thermalStateSource], .string("ProcessInfo"))

        let json = try EvidencePackageJSONRenderer.render(package)
        let text = try EvidencePackageTextRenderer.render(package)
        XCTAssertTrue(String(bytes: json, encoding: .utf8)?.contains("thermalStateSource") == true)
        XCTAssertTrue(text.contains("WHAT WAS HAPPENING"))
        XCTAssertTrue(text.contains("Status: INCOMPLETE"))

        let writer = EvidenceExportWriter()
        let jsonDestination = root.appendingPathComponent("evidence.json")
        let textDestination = root.appendingPathComponent("evidence.txt")
        try writer.write(package: package, format: .json, to: jsonDestination)
        try writer.write(package: package, format: .text, to: textDestination)
        XCTAssertEqual(try Data(contentsOf: jsonDestination), try writer.data(for: package, format: .json))
        XCTAssertEqual(try Data(contentsOf: textDestination), try writer.data(for: package, format: .text))
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    func testIncidentCollectorAndWindowSummaryStayWithinExportContract() async throws {
        let systemStats = SystemStatsModel(refreshInterval: 60)
        let battery = BatteryManager(reader: ContractBatteryReader(), startTimer: false)
        let cooling = CoolingService(
            source: ContractCoolingSource(),
            thermalStateReader: { .nominal },
            automaticallyStart: false
        )
        cooling.refresh()
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = IncidentContextSnapshot.current(
            capturedAt: markerDate,
            systemStats: systemStats,
            battery: battery,
            cooling: cooling
        )
        XCTAssertNoThrow(try EvidenceRedactionPolicy.redactContext(snapshot.values))

        let summary = IncidentWindowSummary(
            requestedStart: markerDate.addingTimeInterval(-60),
            requestedEnd: markerDate.addingTimeInterval(120),
            coveredStart: markerDate.addingTimeInterval(-60),
            coveredEnd: markerDate.addingTimeInterval(120),
            sampleCount: 3,
            coverage: .partial,
            metrics: ["cpuUtilizationPercent": IncidentWindowMetric(
                sampleCount: 3,
                minimum: 1,
                maximum: 3,
                mean: 2
            )],
            states: ["thermalState": ["Nominal", "Fair"]]
        )
        let context = EvidenceValue.object([
            EvidenceContextSchema.system: .object([
                EvidenceContextSchema.Field.cpuUtilizationPercent: .decimal("12.50"),
                EvidenceContextSchema.Field.memoryPressure: .string("normal"),
                EvidenceContextSchema.Field.memoryUsedBytes: .unsigned(100),
                EvidenceContextSchema.Field.memoryPhysicalBytes: .unsigned(200),
                EvidenceContextSchema.Field.swapUsedBytes: .unsigned(0),
                EvidenceContextSchema.Field.rootStorageFreeBytes: .unsigned(300),
                EvidenceContextSchema.Field.rootStorageTotalBytes: .unsigned(400),
                EvidenceContextSchema.Field.lowPowerMode: .boolean(false),
                EvidenceContextSchema.Field.thermalState: .string("Nominal")
            ]),
            EvidenceContextSchema.network: .object([
                EvidenceContextSchema.Field.sentBytes: .unsigned(1),
                EvidenceContextSchema.Field.receivedBytes: .unsigned(2),
                EvidenceContextSchema.Field.uploadBytesPerSecond: .decimal("3.00"),
                EvidenceContextSchema.Field.downloadBytesPerSecond: .decimal("4.00")
            ]),
            EvidenceContextSchema.battery: .object([
                EvidenceContextSchema.Field.present: .boolean(true),
                EvidenceContextSchema.Field.acConnected: .boolean(true),
                EvidenceContextSchema.Field.charging: .boolean(false),
                EvidenceContextSchema.Field.stateOfChargePercent: .decimal("80.00")
            ]),
            EvidenceContextSchema.cooling: .object([
                EvidenceContextSchema.Field.thermalState: .string("Nominal"),
                EvidenceContextSchema.Field.thermalStateSource: .string("ProcessInfo"),
                EvidenceContextSchema.Field.primaryFanRPM: .integer(0),
                EvidenceContextSchema.Field.primaryTemperatureCelsius: .decimal("42.00")
            ]),
            EvidenceContextSchema.windowSummary: summary.evidenceValue
        ])

        XCTAssertNoThrow(try EvidenceRedactionPolicy.redactContext(context))
    }

    func testCoolingContextRejectsUnknownFieldsAndInvalidValueTypes() {
        XCTAssertThrowsError(try EvidenceRedactionPolicy.redactContext(.object([
            EvidenceContextSchema.cooling: .object([
                EvidenceContextSchema.Field.thermalStateSource: .object([:])
            ])
        ]))) { error in
            XCTAssertEqual(
                error as? EvidencePackageError,
                .unsupportedContextField("context.cooling.thermalStateSource")
            )
        }

        XCTAssertThrowsError(try EvidenceRedactionPolicy.redactContext(.object([
            EvidenceContextSchema.cooling: .object([
                "futureCoolingSecret": .string("JEFF_PRIVATE_CONTEXT_SENTINEL")
            ])
        ]))) { error in
            XCTAssertEqual(
                error as? EvidencePackageError,
                .unclassifiedField("context.cooling.futureCoolingSecret")
            )
        }
    }

    func testWindowSummaryContextIsScalarAndExportable() async throws {
        let context = EvidenceValue.object([
            "system": .object(["cpuUtilizationPercent": .decimal("12.50")]),
            "network": .object(["downloadBytesPerSecond": .decimal("20.00")]),
            "battery": .object(["acConnected": .boolean(true)]),
            "cooling": .object([:]),
            "windowSummary": .object([
                "requestedStart": .date(markerDate.addingTimeInterval(-60)),
                "requestedEnd": .date(markerDate.addingTimeInterval(120)),
                "coveredStart": .date(markerDate.addingTimeInterval(-60)),
                "coveredEnd": .date(markerDate.addingTimeInterval(120)),
                "sampleCount": .unsigned(181),
                "coverage": .string("COMPLETE"),
                "metric_cpuUtilizationPercent_mean": .decimal("12.50"),
                "state_memoryPressure": .string("normal")
            ])
        ])

        let redacted = try EvidenceRedactionPolicy.redactContext(context)
        XCTAssertEqual(redacted, context)
        let incident = IncidentPackage(
            id: incidentID,
            marker: IncidentMarker(markerID: UUID(), wallTime: markerDate),
            status: .complete,
            completedAt: markerDate.addingTimeInterval(120),
            materializedContext: context,
            observationIDs: []
        )
        let package = try await EvidencePackageAssembler().assemble(
            incidentID: incidentID,
            journal: InMemoryEvidenceJournal(incidents: [incident])
        )
        let text = try EvidencePackageTextRenderer.render(package)
        XCTAssertTrue(text.contains("WHAT WAS HAPPENING"))
        XCTAssertTrue(text.contains("CPU mean across captured samples: 12.50%"))
        XCTAssertTrue(text.contains("CHANGES OBSERVED"))
        XCTAssertTrue(text
            .contains("No interpretation was generated because no qualifying change observation was captured."))
    }

    func testIncompleteIncidentAndPowerOnlyIncidentRemainValid() async throws {
        let incompleteJournal = try await makeJournal(observations: [storageObservation()], status: .incomplete)
        let incomplete = try await EvidencePackageAssembler().assemble(
            incidentID: incidentID,
            journal: incompleteJournal
        )
        XCTAssertEqual(incomplete.incident?.status, .incomplete)
        XCTAssertEqual(
            incomplete.captureWindow.end.timeIntervalSince(incomplete.captureWindow.start),
            180,
            accuracy: 0.001
        )

        let powerJournal = try await makeJournal(observations: [powerObservation()])
        let powerOnly = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: powerJournal)
        XCTAssertEqual(powerOnly.observations.count, 1)
        XCTAssertTrue(powerOnly.evidenceSets.isEmpty)
        XCTAssertTrue(powerOnly.inferences.isEmpty)
        XCTAssertEqual(powerOnly.versionManifest?.correlationRules.map(\.ruleID), [
            "H2-CORR-NETWORK-PATH-TRANSITION",
            "H2-CORR-STORAGE-LIFECYCLE"
        ])
        XCTAssertEqual(powerOnly.versionManifest?.inferenceRules.map(\.ruleID), [
            "EXTERNAL_STORAGE_LIFECYCLE",
            "NETWORK_PATH_TRANSITION"
        ])
    }

    func testUsableIncompletePackageExportsWithExplicitStatusAndLimitations() async throws {
        let journal = try await makeJournal(observations: [storageObservation()], status: .incomplete)
        let incidentValue = await journal.incident(id: incidentID)
        let incident = try XCTUnwrap(incidentValue)
        let sets = try CorrelationEngine().correlate(incident: incident, observations: [storageObservation()])
        try await journal.persistEvidenceSets(incidentID: incidentID, sets: sets)

        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        XCTAssertEqual(package.incident?.status, .incomplete)
        XCTAssertTrue(package.unknowns.contains { $0.reason == .incompleteCapture })

        let text = try EvidencePackageTextRenderer.render(package)
        XCTAssertTrue(text.contains("Status: INCOMPLETE"))
        XCTAssertTrue(text.contains("IMPORTANT: This capture has known evidence or coverage gaps."))
        XCTAssertTrue(text.contains("Do not interpret missing evidence as proof that an event did not occur."))
        XCTAssertTrue(text.contains("UNKNOWN / LIMITATIONS"))

        let json = try EvidencePackageJSONRenderer.render(package)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EvidencePackage.self, from: json)
        XCTAssertEqual(decoded.incident?.status, .incomplete)
        XCTAssertTrue(decoded.incident?.unknowns.contains { $0.reason == .incompleteCapture } == true)
    }

    func testIntegrityBrokenIncompletePackageStillRefusesExport() async throws {
        let missingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000009901"))
        let incident = IncidentPackage(
            id: incidentID,
            marker: IncidentMarker(markerID: UUID(), wallTime: markerDate),
            status: .incomplete,
            completedAt: nil,
            materializedContext: .object([:]),
            observationIDs: [missingID],
            unknowns: [EvidenceMissing(
                sourceID: nil,
                reason: .incompleteCapture,
                explanation: "Capture was incomplete."
            )]
        )
        let journal = InMemoryEvidenceJournal(incidents: [incident])

        do {
            _ = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
            XCTFail("A package with a missing canonical observation must not export.")
        } catch let error as EvidencePackageError {
            XCTAssertEqual(error, .missingObservation(missingID))
        }
    }

    func testWriterProducesRendererBytesWithOwnerOnlyPermissions() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "horizon2-i8-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Small-Matter-Evidence-test.json")
        let writer = EvidenceExportWriter()

        try writer.write(package: package, format: .json, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try writer.data(for: package, format: .json))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let textDestination = directory.appendingPathComponent("Small-Matter-Evidence-test.txt")
        try writer.write(package: package, format: .text, to: textDestination)
        XCTAssertEqual(try Data(contentsOf: textDestination), try writer.data(for: package, format: .text))
        let textAttributes = try FileManager.default.attributesOfItem(atPath: textDestination.path)
        XCTAssertEqual((textAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.contains(".partial") })

        try writer.write(package: package, format: .json, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try writer.data(for: package, format: .json))
    }

    func testWriterFailsWithoutCreatingAPartialFile() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizon2-i8-missing-parent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("export.json")

        XCTAssertThrowsError(try EvidenceExportWriter().write(package: package, format: .json, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWriterPermissionFailureDoesNotExposeDestinationOrTemporaryFile() async throws {
        let journal = try await makeJournal(observations: [storageObservation()])
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "horizon2-i8-permission-(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")
        let writer = EvidenceExportWriter(permissionVerifier: { _ in
            throw EvidencePackageError.writeFailure("permission fixture")
        })

        XCTAssertThrowsError(try writer.write(package: package, format: .json, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.contains(".partial") })
    }

    func testTextRendererPreservesInferenceEpistemicCategories() async throws {
        let journal = try await makeJournal(
            observations: [networkObservation()],
            incidentUnknowns: [EvidenceMissing(
                sourceID: .network,
                reason: .sourceUnavailable,
                explanation: "Network capture was incomplete."
            )]
        )
        let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
        XCTAssertFalse(package.nextTestSnapshots.isEmpty)
        let text = try EvidencePackageTextRenderer.render(package)

        XCTAssertTrue(text.contains("Observed support:"))
        XCTAssertTrue(text.contains(networkObservation().id.uuidString))
        XCTAssertTrue(text.contains("Unknown: Physical cause was not established by this evidence."))
        XCTAssertTrue(text.contains("Network capture was incomplete."))
        XCTAssertTrue(text.contains("Alternative:"))
        XCTAssertTrue(text.contains("NEXT TEST"))
        XCTAssertTrue(text.contains("Inspect current macOS Network interface and path state"))
        XCTAssertTrue(text.contains("Inspect the current Network interface and path state in macOS."))
        XCTAssertTrue(text.contains("Stop when the current interface and path state is recorded."))
        XCTAssertTrue(text.contains("Small Matter does not ping, connect to, or modify the network."))
    }

    private let incidentID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private let markerDate = Date(timeIntervalSince1970: 1_735_689_600)
    private let time = EvidenceTime(
        observedWallTime: Date(timeIntervalSince1970: 1_735_689_610),
        continuousNanoseconds: 10_000_000_000,
        processUptimeNanoseconds: 10_000_000_000,
        processRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
        bootSessionID: "JEFF_PRIVATE_BOOT_SENTINEL",
        localSequence: 1,
        sourceTimestampQuality: .exact,
        orderingDomain: EvidenceOrderingDomain(
            sourceID: .storage,
            processRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
            clockDomainID: "JEFF_PRIVATE_CLOCK_SENTINEL"
        ),
        sourceOccurrence: nil
    )
    private let provenance = EvidenceProvenance(
        sourceID: .storage,
        apiName: "Fixture API",
        apiVersion: "1",
        captureChannel: "I8 fixture",
        sourceTimestampQuality: .exact,
        normalizationRuleID: "I8_FIXTURE",
        normalizationRuleVersion: "1.0.0",
        hostScope: .provenOnTestedHost,
        rawReferenceDigest: String(repeating: "a", count: 64)
    )

    private func journalIncident(observation: Observation) -> IncidentPackage {
        IncidentPackage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000231")!,
            marker: IncidentMarker(
                markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000232")!,
                wallTime: markerDate
            ),
            status: .complete,
            completedAt: markerDate.addingTimeInterval(120),
            materializedContext: .object([
                "system": .object(["cpuUtilizationPercent": .decimal("12.50")]),
                "battery": .object(["acConnected": .boolean(true)]),
                "cooling": .object([:])
            ]),
            observationIDs: [observation.id]
        )
    }

    private func storageObservation() -> Observation {
        Observation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000221")!,
            domain: .storage,
            eventKind: .storageDiskLifecycle,
            sourceID: .storage,
            subject: EvidenceSubject(
                type: .storageDisk,
                identityDigest: "JEFF_PRIVATE_DEVICE_SENTINEL",
                quality: .qualified,
                safeDisplayLabel: "JEFF_PRIVATE_VOLUME_SENTINEL"
            ),
            provenance: provenance,
            time: time,
            currentState: .object(["lifecycle": .string("diskDisappeared")]),
            attributes: ["lifecycle": .string("diskDisappeared")],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("subject.identityDigest"),
                    classification: .deviceMetadata,
                    pseudonymization: .required(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("provenance.rawReferenceDigest"),
                    classification: .deviceMetadata,
                    pseudonymization: .required(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.lifecycle"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.lifecycle"),
                    classification: .none,
                    pseudonymization: .notApplicable
                )
            ])
        )
    }

    private func networkObservation() -> Observation {
        Observation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000224")!,
            domain: .network,
            eventKind: .networkPathTransition,
            sourceID: .network,
            subject: EvidenceSubject(
                type: .networkInterface,
                identityDigest: nil,
                quality: .unavailable,
                safeDisplayLabel: "Network path"
            ),
            provenance: EvidenceProvenance(
                sourceID: .network,
                apiName: "Fixture API",
                apiVersion: "1",
                captureChannel: "I8.1 fixture",
                sourceTimestampQuality: .exact,
                normalizationRuleID: "I8_FIXTURE",
                normalizationRuleVersion: "1.0.0",
                hostScope: .provenOnTestedHost,
                rawReferenceDigest: nil
            ),
            time: time,
            previousState: .object(["status": .string("SATISFIED")]),
            currentState: .object(["status": .string("UNSATISFIED")]),
            attributes: ["supplemental": .boolean(true)],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("previousState.status"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.status"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.supplemental"),
                    classification: .none,
                    pseudonymization: .notApplicable
                )
            ])
        )
    }

    private func powerObservation() -> Observation {
        Observation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            domain: .power,
            eventKind: .powerSourceTransition,
            sourceID: .power,
            subject: EvidenceSubject(
                type: .powerSource,
                identityDigest: nil,
                quality: .provenStable,
                safeDisplayLabel: "Power source"
            ),
            provenance: EvidenceProvenance(
                sourceID: .power,
                apiName: "Fixture API",
                apiVersion: "1",
                captureChannel: "I8 fixture",
                sourceTimestampQuality: .exact,
                normalizationRuleID: "I8_FIXTURE",
                normalizationRuleVersion: "1.0.0",
                hostScope: .provenOnTestedHost,
                rawReferenceDigest: nil
            ),
            time: time,
            previousState: .object(["source": .string("AC")]),
            currentState: .object(["source": .string("BATTERY")]),
            attributes: ["transition": .string("POWER_SOURCE")],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("previousState.source"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.source"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.transition"),
                    classification: .none,
                    pseudonymization: .notApplicable
                )
            ])
        )
    }

    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private func nestedSensitiveObservation() -> Observation {
        Observation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000223")!,
            domain: .storage,
            eventKind: .storageMountLifecycle,
            sourceID: .storage,
            subject: EvidenceSubject(
                type: .mountedVolume,
                identityDigest: "JEFF_PRIVATE_DEVICE_SENTINEL",
                quality: .weak,
                safeDisplayLabel: "JEFF_PRIVATE_VOLUME_SENTINEL"
            ),
            provenance: provenance,
            time: time,
            currentState: .object(["lifecycle": .string("volumeMounted")]),
            attributes: [
                "mount": .object([
                    "volumeName": .string("JEFF_PRIVATE_VOLUME_SENTINEL"),
                    "filesystemPath": .string("JEFF_PRIVATE_PATH_SENTINEL"),
                    "safe": .string("JEFF_SAFE_ATTRIBUTE")
                ]),
                "interfaces": .array([.object(["name": .string("JEFF_PRIVATE_SSID_SENTINEL")])]),
                "optional": .null
            ],
            sensitivity: EvidenceSensitivityRegistry(fields: [
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("currentState.lifecycle"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.mount.volumeName"),
                    classification: .filesystemMetadata,
                    pseudonymization: .required(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.mount.filesystemPath"),
                    classification: .filesystemMetadata,
                    pseudonymization: .unknown
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.mount.safe"),
                    classification: .none,
                    pseudonymization: .notApplicable
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.interfaces[*].name"),
                    classification: .networkMetadata,
                    pseudonymization: .allowed(scope: "package")
                ),
                EvidenceFieldSensitivity(
                    path: EvidenceFieldPath("attributes.optional"),
                    classification: .none,
                    pseudonymization: .notApplicable
                )
            ])
        )
    }
}

private extension EvidenceExportTests {
    func makeJournal(
        observations: [Observation],
        status: IncidentCaptureStatus = .complete,
        incidentUnknowns: [EvidenceMissing] = []
    ) async throws -> any EvidenceJournal {
        let incident = IncidentPackage(
            id: incidentID,
            marker: IncidentMarker(
                markerID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                wallTime: markerDate
            ),
            status: status,
            completedAt: status == .complete ? markerDate.addingTimeInterval(120) : nil,
            materializedContext: .object([
                "system": .object(["cpuUtilizationPercent": .decimal("12.50")]),
                "battery": .object(["acConnected": .boolean(true)]),
                "cooling": .object([:])
            ]),
            observationIDs: observations.map(\.id),
            unknowns: status == .incomplete
                ? [EvidenceMissing(
                    sourceID: nil,
                    reason: .incompleteCapture,
                    explanation: "Capture ended before completion."
                )]
                : incidentUnknowns
        )
        let journal = InMemoryEvidenceJournal(observations: observations, incidents: [incident])
        if status == .complete, let observation = observations.first,
           observation.sourceID == .storage || observation.sourceID == .network {
            let sets = try CorrelationEngine().correlate(incident: incident, observations: observations)
            try await journal.persistEvidenceSets(incidentID: incidentID, sets: sets)
            let inferences = try sets.map { set in
                try InferenceEngine().evaluate(incident: incident, evidenceSet: set, observations: observations)
            }
            try await journal.persistInferences(
                incidentID: incidentID,
                inferences: inferences,
                catalogEntries: Horizon2NextTestCatalog.production.entries
            )
        }
        return journal
        // Why: cohesive reviewed boundary.
    }
}

private struct ContractBatteryReader: BatteryTelemetryReading {
    func read() -> BatterySnapshot? {
        BatterySnapshot(
            timestamp: .now,
            availability: .fresh,
            source: .powerSources,
            present: true,
            isACConnected: true,
            isCharging: true,
            isFullyCharged: false,
            stateOfChargePercent: 80,
            currentCapacityMAh: 4000,
            maxCapacityMAh: 4800,
            designCapacityMAh: 5000,
            healthPercent: 96,
            cycleCount: 42,
            voltageMillivolts: 12000,
            currentMilliamps: 1000,
            powerWatts: 12,
            temperatureCelsius: 32,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: 30,
            temperatureSource: .ioRegistry,
            voltageSource: .ioRegistry,
            currentSource: .ioRegistry,
            powerSource: .ioRegistry,
            timeToEmptySource: nil,
            timeToFullSource: .ioRegistry
        )
    }
}

private final class ContractCoolingSource: CoolingTelemetrySource, @unchecked Sendable {
    func collect() -> Result<CoolingRawObservation, CoolingCollectionError> {
        .success(CoolingRawObservation(
            fanCount: 1,
            fans: [CoolingFan(fanIndex: 0, currentRPM: 0, minimumRPM: 0, maximumRPM: 5000)],
            temperatures: [CoolingTemperature(name: "CPU", valueCelsius: 42, sourceKey: "TC0P")],
            thermalState: .nominal
        ))
    }
} // swiftlint:disable:this file_length
