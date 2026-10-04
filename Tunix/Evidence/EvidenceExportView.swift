import AppKit
import SwiftUI

private enum EvidenceExportSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed
}

struct EvidenceExportPreviewView: View {
    let package: EvidencePackage
    private let writer = EvidenceExportWriter()
    @Environment(\.dismiss) private var dismiss
    @State private var saveState: EvidenceExportSaveState = .idle

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    previewValue("Status", package.incident?.status.rawValue ?? "Unavailable", identifier: "evidence-export-status")
                    if let incident = package.incident {
                        previewValue("Marker", DateFormatter.recentChanges.string(from: incident.markerTime))
                        previewValue("Window", "60 seconds before · 120 seconds after")
                        if incident.status == .incomplete {
                            Text("IMPORTANT: This capture has known evidence or coverage gaps. Missing evidence is not proof that an event did not occur.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("evidence-export-incomplete-warning")
                        }
                    }
                }

                Section("Export") {
                    HStack {
                        Button("Save JSON") { beginExport(.json) }
                            .accessibilityIdentifier("evidence-export-save-json")
                        Button("Save Text") { beginExport(.text) }
                            .accessibilityIdentifier("evidence-export-save-text")
                    }
                    .disabled(saveState == .saving)
                    switch saveState {
                    case .idle:
                        EmptyView()
                    case .saving:
                        Text("Saving…")
                            .accessibilityIdentifier("evidence-export-save-result")
                    case .saved:
                        Text("Saved")
                            .accessibilityIdentifier("evidence-export-save-result")
                    case .failed:
                        Text("Unable to save the evidence export.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("evidence-export-save-error")
                    }
                }

                Section("CAPTURE MEMBERSHIP") {
                    Text("\(package.observations.count) canonical observation\(package.observations.count == 1 ? "" : "s") retained in this capture")
                        .accessibilityIdentifier("evidence-export-membership")
                }

                Section("CHANGES OBSERVED") {
                    let visibleObservations = IncidentChangeProjection.userVisibleObservations(package.observations)
                    Text("\(visibleObservations.count) visible change\(visibleObservations.count == 1 ? "" : "s")")
                        .accessibilityIdentifier("evidence-export-observed")
                    if visibleObservations.isEmpty {
                        Text("No supported system transitions were observed during this capture window.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("evidence-export-no-observations")
                    }
                    ForEach(visibleObservations.sorted(by: compareObservations), id: \.id) { observation in
                        Text(observationTitle(observation))
                    }
                }

                Section("Inferred") {
                    if package.inferences.isEmpty {
                        Text("No inferred interpretations.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(package.inferences.sorted(by: compareInferences), id: \.id) { inference in
                            inferencePreview(inference)
                        }
                    }
                }
                .accessibilityIdentifier("evidence-export-inferred")

                if package.inferences.contains(where: { !$0.alternatives.isEmpty }) {
                    Section("Alternative") {
                        ForEach(package.inferences.sorted(by: compareInferences), id: \.id) { inference in
                            ForEach(Array(inference.alternatives.sorted { $0.hypothesis < $1.hypothesis }.enumerated()), id: \.offset) { index, alternative in
                                Text("Alternative: \(alternative.hypothesis) — \(alternative.reason)")
                                    .accessibilityIdentifier("evidence-export-alternative-\(inference.id.uuidString)-\(index)")
                            }
                        }
                    }
                    .accessibilityIdentifier("evidence-export-alternatives")
                }

                if !package.unknowns.isEmpty || package.inferences.contains(where: { !$0.missingEvidence.isEmpty || hasUnknownNetworkCause($0) }) {
                    Section("Unknown") {
                        ForEach(Array(package.unknowns.sorted(by: compareUnknowns).enumerated()), id: \.offset) { item in
                            Text(item.element.explanation)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(package.inferences.sorted(by: compareInferences), id: \.id) { inference in
                            ForEach(Array(inference.missingEvidence.sorted(by: compareUnknowns).enumerated()), id: \.offset) { _, item in
                                Text("\(inference.ruleID): \(item.explanation)")
                                    .foregroundStyle(.secondary)
                            }
                            if hasUnknownNetworkCause(inference) {
                                Text("Physical cause was not established by this evidence.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("evidence-export-unknown")
                }

                Section("Next Test") {
                    if package.nextTestSnapshots.isEmpty {
                        Text("No Next Test was recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(package.nextTestSnapshots, id: \.reference.testID) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.reference.testID)
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)")
                                Text(entry.reference.purpose)
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-purpose")
                                Text("Action: \(entry.userAction)")
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-action")
                                    .foregroundStyle(.secondary)
                                Text("Evidence expected: \(entry.reference.evidenceExpected)")
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-evidence")
                                    .foregroundStyle(.secondary)
                                if !entry.prerequisites.isEmpty {
                                    Text("Prerequisites: \(entry.prerequisites.map(\.rawValue).joined(separator: ", "))")
                                        .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-prerequisites")
                                        .foregroundStyle(.secondary)
                                }
                                Text("Risk: \(entry.riskClass.rawValue)")
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-risk")
                                    .foregroundStyle(.secondary)
                                Text("Stopping condition: \(entry.stoppingCondition)")
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-stopping")
                                    .foregroundStyle(.secondary)
                                Text("Safety: \(entry.safetyWarning)")
                                    .accessibilityIdentifier("evidence-export-next-test-\(entry.reference.testID)-safety")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("evidence-export-next-tests")

                Section("Sources") {
                    ForEach(package.sourceManifest.sorted(by: { $0.sourceID.rawValue < $1.sourceID.rawValue }), id: \.sourceID) { entry in
                        Text("\(entry.sourceID.rawValue) · \(entry.disposition.rawValue) · \(entry.includedObservationCount) observed")
                    }
                }
                .accessibilityIdentifier("evidence-export-source-manifest")

                Section("Redaction") {
                    Text("Policy \(package.redactionPolicyVersion)")
                    let pseudonymizedCount = package.redactionManifest.filter { $0.action == .pseudonymize }.count
                    let omittedCount = package.redactionManifest.filter { $0.action == .omit }.count
                    Text("Approved fields included unchanged · Pseudonymized: \(pseudonymizedCount) · Omitted: \(omittedCount)")
                    ForEach(Array(package.redactionManifest.sorted(by: compareManifestEntries).enumerated()), id: \.offset) { index, entry in
                        Text("\(entry.action.rawValue) · \(entry.path.rawValue)")
                            .accessibilityLabel("\(entry.action.rawValue), \(entry.classification.rawValue), \(entry.path.rawValue)")
                            .accessibilityIdentifier("redaction-row-\(index)")
                    }
                }
                .accessibilityIdentifier("evidence-export-redaction-manifest")

                if let versions = package.versionManifest {
                    Section("Versions") {
                        Text("Specification \(versions.specificationVersion)")
                        Text("Package schema \(versions.evidencePackageSchemaVersion)")
                        Text("Correlation \(versions.correlationRules.map { "\($0.ruleID) \($0.version)" }.joined(separator: ", "))")
                        Text("Inference \(versions.inferenceRules.map { "\($0.ruleID) \($0.version)" }.joined(separator: ", "))")
                        Text("Next Test catalog \(versions.nextTestCatalogVersion)")
                        Text("Redaction policy \(versions.redactionPolicyVersion)")
                    }
                    .accessibilityIdentifier("evidence-export-version-manifest")
                }
            }
            .navigationTitle("Preview Evidence Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("evidence-export-preview")
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private func beginExport(_ format: EvidenceExportFormat) {
        saveState = .saving
        #if DEBUG
            if let injectedPath = injectedExportPath {
                save(to: URL(fileURLWithPath: injectedPath), format: format)
                return
            }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = writer.defaultFilename(for: package, format: format)
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                saveState = .idle
                return
            }
            save(to: url, format: format)
        }
    }

    private func save(to destination: URL, format: EvidenceExportFormat) {
        do {
            try writer.write(package: package, format: format, to: destination)
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    #if DEBUG
        private var injectedExportPath: String? {
            ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("-UITestingEvidenceExportDestination=") })?
                .split(separator: "=", maxSplits: 1)
                .last
                .map(String.init)
        }
    #endif

    private func previewValue(_ label: String, _ value: String, identifier: String? = nil) -> some View {
        LabeledContent(label, value: value)
            .accessibilityIdentifier(identifier ?? "evidence-export-\(label.lowercased())")
    }

    private func observationTitle(_ observation: Observation) -> String {
        "Observed \(observation.eventKind) from \(observation.sourceID.rawValue)"
    }

    private func inferencePreview(_ inference: Inference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inferred: \(inference.ruleID)")
                .font(.subheadline.weight(.semibold))
            Text("Evidence class: \(inference.evidenceClass.rawValue)")
            Text("Interpretation: \(canonicalValue(inference.hypothesis))")
            if !inference.supportingObservationIDs.isEmpty {
                Text("Observed support")
                    .font(.caption.weight(.semibold))
                ForEach(inference.supportingObservationIDs, id: \.self) { id in
                    Text("\(id.uuidString) · \(observationLabel(id))")
                        .accessibilityIdentifier("evidence-export-support-\(id.uuidString)")
                }
            }
            if !inference.contradictingObservationIDs.isEmpty {
                Text("Contradicting observation")
                    .font(.caption.weight(.semibold))
                ForEach(inference.contradictingObservationIDs, id: \.self) { id in
                    Text("\(id.uuidString) · \(observationLabel(id))")
                        .accessibilityIdentifier("evidence-export-contradiction-\(id.uuidString)")
                }
            }
        }
    }

    private func observationLabel(_ id: UUID) -> String {
        guard let observation = package.observations.first(where: { $0.id == id }) else { return "Observation unavailable" }
        return "\(observation.sourceID.rawValue) · \(observation.eventKind)"
    }

    private func hasUnknownNetworkCause(_ inference: Inference) -> Bool {
        guard inference.ruleID == "NETWORK_PATH_TRANSITION",
              case let .object(values) = inference.hypothesis,
              case let .string(cause) = values["physicalCause"] else { return false }
        return cause == "UNKNOWN"
    }

    private func canonicalValue(_ value: EvidenceValue) -> String {
        guard let data = try? value.deterministicData() else { return "Additional detail unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
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

private func compareInferences(_ lhs: Inference, _ rhs: Inference) -> Bool {
    if lhs.ruleID != rhs.ruleID {
        return lhs.ruleID < rhs.ruleID
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func compareUnknowns(_ lhs: EvidenceMissing, _ rhs: EvidenceMissing) -> Bool {
    "\(lhs.sourceID?.rawValue ?? "")|\(lhs.reason.rawValue)|\(lhs.explanation)" < "\(rhs.sourceID?.rawValue ?? "")|\(rhs.reason.rawValue)|\(rhs.explanation)"
}

private func compareManifestEntries(_ lhs: EvidenceRedactionManifestEntry, _ rhs: EvidenceRedactionManifestEntry) -> Bool {
    "\(lhs.path.rawValue)|\(lhs.action.rawValue)" < "\(rhs.path.rawValue)|\(rhs.action.rawValue)"
}
