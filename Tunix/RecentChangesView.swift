// swiftlint:disable line_length file_length
import SwiftUI

struct RecentChangesView: View {
    @StateObject private var model: RecentChangesViewModel
    @EnvironmentObject private var incidentCapture: IncidentCaptureCoordinator
    @EnvironmentObject private var systemStats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService
    @State private var incidentToDelete: IncidentPackage?
    @State private var showingCapacityRecoveryConfirmation = false

    init(journal: any EvidenceJournal) {
        _model = StateObject(wrappedValue: RecentChangesViewModel(journal: journal))
    }

    var body: some View {
        NavigationStack {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("recent-changes-screen")
                .navigationTitle("Recent Changes")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("recent-changes-refresh")
                        .help("Refresh Recent Changes")
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    if let detail = model.detail(for: id) {
                        RecentChangeDetailView(detail: detail)
                    } else {
                        Text("Evidence unavailable")
                            .accessibilityIdentifier("recent-change-detail")
                    }
                }
        }
        .alert("Delete this capture?", isPresented: Binding(
            get: { incidentToDelete != nil },
            set: {
                if !$0 {
                    incidentToDelete = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                if let incidentToDelete {
                    incidentCapture.delete(incidentToDelete)
                }
                incidentToDelete = nil
            }
            Button("Cancel", role: .cancel) { incidentToDelete = nil }
        } message: {
            Text("The captured package and its membership will be deleted. Ordinary Recent Changes remain.")
        }
        .confirmationDialog(
            "Free safe evidence storage?",
            isPresented: $showingCapacityRecoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Unprotected Evidence", role: .destructive) {
                Task { await model.recoverCapacity() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes ordinary unprotected Recent Changes that are not part of a capture, evidence set, or inference. " +
                    "Completed captures and protected evidence remain. Existing history is not reported as lost until you confirm."
            )
        }
        .alert("Evidence storage recovery", isPresented: Binding(
            get: { model.capacityRecoveryMessage != nil },
            set: {
                if !$0 {
                    model.dismissCapacityRecoveryMessage()
                }
            }
        )) {
            Button("OK", role: .cancel) { model.dismissCapacityRecoveryMessage() }
        } message: {
            Text(model.capacityRecoveryMessage ?? "")
        }
        .task {
            await model.refresh()
            incidentCapture.refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .horizon2JournalDidResolve)) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Recent Changes…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("recent-changes-loading-state")
        case .availableWithChanges, .incompleteEvidence:
            VStack(alignment: .leading, spacing: 0) {
                incidentCapturePanel
                if model.state == .incompleteEvidence {
                    CoverageWarningView(text: model.coverageWarning ?? "Some changes may be missing.")
                }
                recentChangesList
            }
        case .availableEmpty:
            VStack(alignment: .leading, spacing: 0) {
                incidentCapturePanel
                stateMessage(
                    title: "No recent changes yet.",
                    detail: "Observed changes will appear here as Small Matter records them.",
                    identifier: "recent-changes-empty-state"
                )
            }
        case .journalUnavailable:
            VStack(alignment: .leading, spacing: 0) {
                incidentCapturePanel
                stateMessage(
                    title: "Recent Changes is unavailable.",
                    detail: "Local evidence could not be opened. Try Refresh to check again.",
                    identifier: "recent-changes-unavailable-state"
                )
            }
        case .journalCapacityUnavailable:
            VStack(alignment: .leading, spacing: 0) {
                incidentCapturePanel
                stateMessage(
                    title: "Recent changes may not be saved because local evidence storage is full.",
                    detail: "Capture is disabled until safe unprotected evidence is removed. Existing history has not been reported as lost.",
                    identifier: "recent-changes-capacity-state"
                )
            }
        }
    }

    private var incidentCapturePanel: some View {
        IncidentCapturePanel(
            state: model.state,
            coordinator: incidentCapture,
            journal: model.journal,
            context: IncidentContextSnapshot.current(
                capturedAt: Date(),
                systemStats: systemStats,
                battery: battery,
                cooling: cooling
            ),
            onDelete: { incidentToDelete = $0 },
            onRecoverCapacity: { showingCapacityRecoveryConfirmation = true }
        )
    }

    private var recentChangesList: some View {
        List(model.rows) { row in
            NavigationLink(value: row.id) {
                RecentChangeRowView(row: row)
            }
            .accessibilityIdentifier("recent-change-row-\(row.id.uuidString.lowercased())")
        }
        .listStyle(.inset)
        .accessibilityIdentifier("recent-changes-list")
    }

    private func stateMessage(title: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier(identifier)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct IncidentCapturePanel: View {
    let state: RecentChangesState
    @ObservedObject var coordinator: IncidentCaptureCoordinator
    let journal: any EvidenceJournal
    let context: IncidentContextSnapshot
    let onDelete: (IncidentPackage) -> Void
    let onRecoverCapacity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture what just happened")
                        .font(.headline)
                    Text("Capture 60 seconds before now and 2 minutes after.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                captureButton
            }

            if state == .journalCapacityUnavailable {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("Local evidence storage is full.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Free Safe Storage…", action: onRecoverCapacity)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("incident-capture-capacity-recovery")
                        .accessibilityHint("Remove only unprotected evidence after confirmation; completed captures and protected evidence remain.")
                }
            }

            switch coordinator.state {
            case .capturing, .finalizing:
                Label("Capturing…", systemImage: "record.circle")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("incident-capture-capturing")
                Text("Saving changes from 60 seconds before the marker through 2 minutes after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("incident-capture-window")
            case .complete:
                Text("Complete")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("incident-capture-complete")
            case .incomplete:
                Text("Incomplete")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("incident-capture-incomplete")
            case .unavailable, .failure:
                Text("Capture is unavailable right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("incident-capture-unavailable")
            default:
                EmptyView()
            }

            if !coordinator.incidents.isEmpty {
                Text("Captures")
                    .font(.subheadline.weight(.semibold))
                ForEach(coordinator.incidents) { incident in
                    NavigationLink {
                        IncidentSummaryView(
                            incident: incident,
                            journal: journal,
                            onDelete: { onDelete(incident) }
                        )
                    } label: {
                        HStack {
                            Text(incident.status == .complete ? "Complete" : "Incomplete")
                            Spacer()
                            Text(DateFormatter.recentChanges.string(from: incident.marker.wallTime))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("incident-history-row-\(incident.id.uuidString.lowercased())")
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private var captureButton: some View {
        let journalUnavailable = state == .journalUnavailable || state == .journalCapacityUnavailable
        return Button("Capture") {
            coordinator.start(context: context)
        }
        .buttonStyle(.borderedProminent)
        .disabled(journalUnavailable || coordinator.isActive)
        .accessibilityIdentifier("incident-capture-start")
        .accessibilityHint(
            journalUnavailable
                ? "Capture is unavailable because local evidence storage is full or unavailable. Use Free Safe Storage when offered."
                : "Capture 60 seconds before now and 2 minutes after"
        )
        .help("Capture 60 seconds before now and 2 minutes after")
    }
}

@MainActor
private struct IncidentSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let incident: IncidentPackage
    let journal: any EvidenceJournal
    let onDelete: () -> Void
    @State private var observations: [Observation] = []
    @State private var inferences: [Inference] = []
    @State private var nextTestSnapshots: [UUID: [NextTestCatalogEntry]] = [:]
    @State private var supportingObservations: [UUID: [Observation]] = [:]
    @State private var contradictingObservations: [UUID: [Observation]] = [:]
    @State private var packageForPreview: EvidencePackage?
    @State private var exportError: String?

    private var visibleObservations: [Observation] {
        IncidentChangeProjection.userVisibleObservations(observations)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("WHAT WAS HAPPENING") {
                    IncidentWindowSummaryView(context: incident.materializedContext)
                }

                Section("Capture") {
                    summaryRow("Status", incident.status == .complete ? "Complete" : "Incomplete")
                    summaryRow("Marker", DateFormatter.recentChanges.string(from: incident.marker.wallTime))
                    summaryRow("Window", "60 seconds before · 120 seconds after")
                    summaryRow("Observations", String(observations.count))
                    summaryRow("Context", "Marker context and bounded telemetry window")
                }

                if !incident.unknowns.isEmpty {
                    Section("Unknown or missing evidence") {
                        ForEach(Array(incident.unknowns.enumerated()), id: \.offset) { missing in
                            Text(missing.element.explanation)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("incident-summary-unknown-\(missing.offset)")
                        }
                    }
                }

                Section("CHANGES OBSERVED") {
                    if visibleObservations.isEmpty {
                        Text("No supported system transitions were observed during this capture window.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("incident-no-observations")
                    } else {
                        ForEach(visibleObservations) { observation in
                            IncidentObservationRow(observation: observation)
                        }
                    }
                }

                Section("Interpretation") {
                    if inferences.isEmpty {
                        Text("No interpretation was generated because no qualifying change observation was captured.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("incident-no-interpretation")
                    } else {
                        ForEach(inferences) { inference in
                            IncidentInferenceView(
                                inference: inference,
                                nextTests: nextTestSnapshots[inference.id] ?? [],
                                supportingObservations: supportingObservations[inference.id] ?? [],
                                contradictingObservations: contradictingObservations[inference.id] ?? []
                            )
                        }
                    }
                }

                Section("Evidence export") {
                    Button("Preview Evidence Export") {
                        Task {
                            do {
                                packageForPreview = try await EvidencePackageAssembler().assemble(
                                    incidentID: incident.id,
                                    journal: journal
                                )
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                    .accessibilityIdentifier("incident-preview-evidence-export")
                }

                Section {
                    Button("Delete Capture", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("incident-delete")
                }
            }
            .navigationTitle("Capture Summary")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .task {
                observations = await incident.observationIDs.asyncCompactMap { await journal.observation(id: $0) }
                inferences = await journal.inferences(incidentID: incident.id, currentOnly: true)
                let observationsByID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
                var support: [UUID: [Observation]] = [:]
                var contradictions: [UUID: [Observation]] = [:]
                var snapshots: [UUID: [NextTestCatalogEntry]] = [:]
                for inference in inferences {
                    support[inference.id] = inference.supportingObservationIDs.compactMap { observationsByID[$0] }
                    contradictions[inference.id] = inference.contradictingObservationIDs.compactMap { observationsByID[$0] }
                    snapshots[inference.id] = await journal.nextTestSnapshots(inferenceID: inference.id)
                }
                supportingObservations = support
                contradictingObservations = contradictions
                nextTestSnapshots = snapshots
            }
            .accessibilityIdentifier("incident-summary")
            .sheet(item: $packageForPreview) { package in
                EvidenceExportPreviewView(package: package)
            }
            .alert("Evidence export unavailable", isPresented: Binding(
                get: { exportError != nil },
                set: {
                    if !$0 {
                        exportError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "The evidence package could not be assembled.")
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

private struct IncidentWindowSummaryView: View {
    let context: EvidenceValue

    private var fields: [String: EvidenceValue] {
        guard case let .object(topLevel) = context,
              case let .object(window)? = topLevel["windowSummary"]
        else { return [:] }
        return window
    }

    var body: some View {
        if fields.isEmpty {
            Text("Marker context was recorded; no bounded telemetry history was available for this package.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("incident-window-summary-unavailable")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Coverage", string("coverage") ?? "UNKNOWN")
                summaryRow("Samples", string("sampleCount") ?? "0")
                if let coveredStart = date("coveredStart"), let coveredEnd = date("coveredEnd") {
                    summaryRow(
                        "Covered",
                        "\(DateFormatter.recentChanges.string(from: coveredStart)) – \(DateFormatter.recentChanges.string(from: coveredEnd))"
                    )
                }
                metricRow("CPU mean", key: "cpuUtilizationPercent")
                metricRow("Memory used mean", key: "memoryUsedBytes", formatter: byteFormatter)
                stateRow("Memory pressure", key: "memoryPressure")
                stateRow("Thermal state", key: "thermalState")
                stateRow("Power", key: "batteryACConnected")
                stateRow("Charging", key: "batteryCharging")
                metricRow("Network download mean", key: "networkDownloadBytesPerSecond", formatter: rateFormatter)
                metricRow("Primary fan mean", key: "primaryFanRPM", formatter: rpmFormatter)
            }
            .accessibilityIdentifier("incident-window-summary")
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    @ViewBuilder
    private func metricRow(
        _ label: String,
        key: String,
        formatter: ((Double) -> String)? = nil
    ) -> some View {
        if let mean = decimal("metric_\(key)_mean") {
            summaryRow(label, (formatter ?? { String(format: "%.2f", $0) })(mean))
        }
    }

    @ViewBuilder
    private func stateRow(_ label: String, key: String) -> some View {
        if let value = string("state_\(key)"), !value.isEmpty {
            summaryRow(label, value)
        }
    }

    private func string(_ key: String) -> String? {
        guard let value = fields[key] else { return nil }
        switch value {
        case let .string(value):
            return value
        case let .integer(value):
            return String(value)
        case let .unsigned(value):
            return String(value)
        case let .decimal(value):
            return value
        case let .boolean(value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private func decimal(_ key: String) -> Double? {
        guard case let .decimal(value)? = fields[key] else { return nil }
        return Double(value)
    }

    private func date(_ key: String) -> Date? {
        guard case let .date(value)? = fields[key] else { return nil }
        return value
    }

    private var byteFormatter: (Double) -> String {
        { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary) }
    }

    private var rateFormatter: (Double) -> String {
        { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary))/s" }
    }

    private var rpmFormatter: (Double) -> String {
        { "\(Int($0.rounded())) RPM" }
    }
}

private struct IncidentInferenceView: View {
    let inference: Inference
    let nextTests: [NextTestCatalogEntry]
    let supportingObservations: [Observation]
    let contradictingObservations: [Observation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inferred")
                    .font(.headline)
                Spacer()
                Text(inference.evidenceClassLabel)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("inference-evidence-class")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inference-status")

            Text(summary)
                .font(.body)
                .accessibilityIdentifier("inference-row-\(inference.id.uuidString.lowercased())")

            if !inference.supportingObservationIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Observed support")
                        .font(.subheadline.weight(.semibold))
                    Text("Captured observations support this narrow interpretation.")
                        .foregroundStyle(.secondary)
                    ForEach(supportingObservations) { observation in
                        IncidentObservationRow(
                            observation: observation,
                            identifierPrefix: "inference-support-observation"
                        )
                    }
                }
            }

            if !contradictingObservations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Observed contradiction")
                        .font(.subheadline.weight(.semibold))
                    Text("These captured observations do not establish the interpretation.")
                        .foregroundStyle(.secondary)
                    ForEach(contradictingObservations) { observation in
                        IncidentObservationRow(
                            observation: observation,
                            identifierPrefix: "inference-contradiction-observation"
                        )
                    }
                }
            }

            if showsExplicitUnknown {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unknown")
                        .font(.subheadline.weight(.semibold))
                    if inference.missingEvidence.isEmpty {
                        Text(inference.evidenceClass == .insufficientEvidence
                            ? "The captured evidence does not establish a supported interpretation."
                            : "The physical cause was not observed.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(inference.missingEvidence.enumerated()), id: \.offset) { item in
                            Text(item.element.explanation)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("inference-unknown")
            }

            ForEach(Array(inference.alternatives.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alternative")
                        .font(.subheadline.weight(.semibold))
                    Text("\(item.element.hypothesis) — \(item.element.reason)")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("inference-alternative-\(item.offset)")
            }

            ForEach(nextTests, id: \.reference.testID) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next Test")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("inference-next-test-\(entry.reference.testID)")
                    labeledNextTestField("Purpose", entry.reference.purpose, identifier: "purpose")
                    labeledNextTestField("Action", entry.userAction, identifier: "action")
                    labeledNextTestField("Evidence expected", entry.reference.evidenceExpected, identifier: "evidence")
                    labeledNextTestField("Stopping condition", entry.stoppingCondition, identifier: "stopping")
                    labeledNextTestField("Safety", entry.safetyWarning, identifier: "safety")
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incident-inference-section")
    }

    private func labeledNextTestField(_ label: String, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("inference-next-test-\(identifier)")
    }

    private var showsExplicitUnknown: Bool {
        if inference.evidenceClass == .insufficientEvidence || !inference.missingEvidence.isEmpty {
            return true
        }
        guard case let .object(values) = inference.hypothesis else { return false }
        return values["physicalCause"] == .string("UNKNOWN")
    }

    private var summary: String {
        guard inference.evidenceClass == .supported else { return "The captured evidence is insufficient for a supported interpretation." }
        if case let .object(values) = inference.hypothesis,
           case let .string(kind)? = values["kind"]
        // swiftlint:disable:next opening_brace
        {
            switch kind {
            case "EXTERNAL_STORAGE_LIFECYCLE":
                let subject = storageSubjectLabel(values["subjectType"])
                return "Captured evidence supports a \(subject) lifecycle change."
            case "NETWORK_PATH_TRANSITION": return "Captured evidence supports a network path/interface availability change."
            default: break
            }
        }
        return "Captured evidence supports an observed change."
    }

    private func storageSubjectLabel(_ value: EvidenceValue?) -> String {
        guard case let .string(subjectType)? = value else { return "storage subject" }
        switch subjectType {
        case "STORAGE_DISK": return "storage disk"
        case "MOUNTED_VOLUME": return "mounted volume"
        default: return "storage subject"
        }
    }
}

private struct IncidentObservationRow: View {
    let observation: Observation
    let identifierPrefix: String

    init(observation: Observation, identifierPrefix: String = "incident-evidence-row") {
        self.observation = observation
        self.identifierPrefix = identifierPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(observation.eventKind.captureDisplayTitle)
                .font(.headline)
            Text("Observed · \(observation.sourceID == .network ? "Supplemental" : "Fact")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifierPrefix)-\(observation.id.uuidString.lowercased())")
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var values: [T] = []
        for element in self {
            if let value = await transform(element) {
                values.append(value)
            }
        }
        return values
    }
}

private extension EvidenceEventKind {
    var captureDisplayTitle: String {
        switch self {
        case .storageDiskLifecycle: return "Storage lifecycle changed"
        case .storageMountLifecycle: return "Volume lifecycle changed"
        case .networkPathTransition: return "Network path changed"
        case .powerSourceTransition: return "Power source changed"
        default: return "Observed change"
        }
    }
}

private struct RecentChangeRowView: View {
    let row: RecentChangeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(row.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(row.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(row.subjectText)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(row.timeText)
                Spacer(minLength: 4)
                if row.isSupplemental {
                    Text("Supplemental")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(row.isSupplemental ? "Observed, Supplemental" : "Observed")
    }

    private var accessibilityLabel: String {
        let supplemental = row.isSupplemental ? ", Supplemental" : ""
        return "\(row.title), \(row.subjectText), \(row.timeText), Observed\(supplemental)"
    }
}

private struct CoverageWarningView: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .accessibilityIdentifier("recent-changes-incomplete-state")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .accessibilityIdentifier("recent-changes-incomplete-state")
    }
}

private struct RecentChangeDetailView: View {
    let detail: RecentChangeDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.row.title)
                        .font(.title2.weight(.semibold))
                    Text(detail.row.summary)
                        .foregroundStyle(.secondary)
                    Text("Observed")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recent-change-status")
                }

                detailSection("When") {
                    detailField("Time", detail.row.timeText, identifier: "recent-change-time")
                    detailField("Time quality", detail.row.timeQualityText)
                }

                detailSection("What Small Matter observed") {
                    detailField("Source", detail.row.sourceText, identifier: "recent-change-source")
                    detailField("State", detail.row.title, identifier: "recent-change-state")
                    ForEach(Array(detail.fields.dropFirst(2))) { field in
                        detailField(field.label, field.value)
                    }
                }

                if let availabilityText = detail.availabilityText {
                    detailSection("Availability") {
                        Text(availabilityText)
                            .foregroundStyle(.secondary)
                    }
                }

                if let supplementalLimitation = detail.supplementalLimitation {
                    detailSection("Supplemental limitation") {
                        Text(supplementalLimitation)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Recent Change")
        .accessibilityIdentifier("recent-change-detail")
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func detailField(_ label: String, _ value: String, identifier: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "recent-change-field-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

extension Notification.Name {
    static let horizon2JournalDidResolve = Notification.Name("com.tunix.horizon2.journalDidResolve")
}

// swiftlint:enable line_length
