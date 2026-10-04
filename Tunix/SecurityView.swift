// swiftlint:disable trailing_comma type_body_length
import AppKit
import SwiftUI

struct SecurityView: View {
    @EnvironmentObject private var stats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @EnvironmentObject private var evidenceRuntime: EvidenceRuntime
    @State private var snapshotMessage: String?
    @State private var evidenceSupportState: EvidenceSupportState = .loading
    @State private var latestEvidencePackage: EvidencePackage?
    @State private var evidenceError: String?
    @State private var evidenceLoading = true
    @State private var diagnosticsExpanded = ProcessInfo.processInfo.arguments.contains("-UITesting")

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "System Health",
                    subtitle: "A readable view of data sources, freshness, and the read-only product boundary."
                )
                healthContent(for: layout)
            }
        }
        .navigationTitle("System Health")
        .task {
            await refreshEvidenceSupport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .horizon2JournalDidResolve)) { _ in
            Task { await refreshEvidenceSupport() }
        }
        .sheet(item: $latestEvidencePackage) { package in
            EvidenceExportPreviewView(package: package)
        }
        .alert("Evidence unavailable", isPresented: Binding(
            get: { evidenceError != nil },
            set: {
                if !$0 {
                    evidenceError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { evidenceError = nil }
        } message: {
            Text(evidenceError ?? "Unable to prepare the evidence package.")
        }
    }

    @ViewBuilder
    private func healthContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact, .standard:
            integritySection
            telemetrySection
            detailsSection
            evidenceSupportSection
        case .wide, .large:
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                    VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                        integritySection
                        telemetrySection
                    }
                    detailsSection
                        .frame(maxWidth: 420, alignment: .topLeading)
                }
                evidenceSupportSection
            }
        }
    }

    private var evidenceSupportSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 12) {
                TunixSectionHeader(title: "Evidence & Support")
                    .accessibilityIdentifier("system-health-evidence-section")

                Text("Captured evidence is separate from the current system snapshot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                evidenceStatusRow("Evidence history", evidenceHistoryLabel)
                    .accessibilityIdentifier("system-health-evidence-status")
                evidenceStatusRow("Latest capture", latestCaptureLabel)
                    .accessibilityIdentifier("system-health-latest-capture")

                if let latestCapture {
                    Text("Marker \(DateFormatter.recentChanges.string(from: latestCapture.marker.wallTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Open Recent Changes") {
                        NotificationCenter.default.post(name: .tunixNavigate, object: "Recent Changes")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("system-health-open-recent-changes")

                    if latestCapture != nil {
                        Button("Preview Latest Evidence Package") {
                            previewLatestEvidence()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("system-health-preview-latest-evidence")
                    }
                }

                if evidenceLoading {
                    ProgressView("Loading evidence status…")
                        .controlSize(.small)
                        .accessibilityIdentifier("system-health-evidence-loading")
                } else if case .availableNoCapture = evidenceSupportState {
                    Text("No evidence capture yet.")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("system-health-no-capture")
                    Text("Use Capture in Recent Changes after something happens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let evidenceError {
                    Text(evidenceError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("system-health-evidence-error")
                }
            }
        }
    }

    private func evidenceStatusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private var evidenceHistoryLabel: String {
        switch evidenceSupportState {
        case .loading: return "Loading"
        case .availableNoCapture, .availableCapture: return "Available"
        case .capacityNoCapture, .capacityCapture:
            return "Storage full"
        case .unavailable:
            return "Unavailable"
        case let .packageFailure(availability, _):
            return availability == .capacityUnavailable ? "Storage full" : "Available"
        }
    }

    private var latestCaptureLabel: String {
        guard let latestCapture else { return "No capture" }
        return latestCapture.status == .complete ? "Complete" : "Incomplete"
    }

    private var latestCapture: IncidentPackage? {
        switch evidenceSupportState {
        case let .availableCapture(package), let .capacityCapture(package), let .packageFailure(_, package):
            return package
        case .loading, .availableNoCapture, .capacityNoCapture, .unavailable:
            return nil
        }
    }

    @MainActor
    private func refreshEvidenceSupport() async {
        evidenceLoading = true
        evidenceError = nil
        let status = await evidenceRuntime.journal.retentionStatus()
        let latest: IncidentPackage?
        switch status.availability {
        case .available, .capacityUnavailable:
            latest = await evidenceRuntime.journal.incidentSummaries(limit: 1).first
        case .unavailable:
            latest = nil
        }
        switch (status.availability, latest) {
        case let (.available, package?): evidenceSupportState = .availableCapture(package)
        case (.available, nil): evidenceSupportState = .availableNoCapture
        case let (.capacityUnavailable, package?): evidenceSupportState = .capacityCapture(package)
        case (.capacityUnavailable, nil): evidenceSupportState = .capacityNoCapture
        case (.unavailable, _): evidenceSupportState = .unavailable
        }
        evidenceLoading = false
    }

    private func previewLatestEvidence() {
        guard let latestCapture else { return }
        evidenceError = nil
        Task {
            do {
                latestEvidencePackage = try await EvidencePackageAssembler().assemble(
                    incidentID: latestCapture.id,
                    journal: evidenceRuntime.journal
                )
            } catch {
                let availability: EvidenceJournalAvailability
                switch evidenceSupportState {
                case .capacityCapture, .packageFailure(.capacityUnavailable, _):
                    availability = .capacityUnavailable
                case .unavailable, .packageFailure(.unavailable, _):
                    availability = .unavailable
                default:
                    availability = .available
                }
                evidenceSupportState = .packageFailure(availability: availability, latestCapture)
                evidenceError = "Unable to prepare the evidence package."
            }
        }
    }

    private var integritySection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 14) {
                TunixSectionHeader(title: "Security & Integrity")
                HStack(spacing: 18) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(ProductIdentity.displayName) runs as the logged-in user")
                            .font(.body.weight(.semibold))
                        Text(
                            "Hardware telemetry is read-only. macOS remains responsible for thermal and battery policy."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TunixSectionHeader(title: "Telemetry")
            TunixPanel {
                VStack(spacing: 0) {
                    telemetryRow("CPU", freshnessLabel(stats.cpuSnapshot.freshness), stats.cpuSnapshot.source.rawValue)
                    telemetryRow(
                        "Memory",
                        freshnessLabel(stats.telemetrySnapshot.memory.freshness),
                        stats.telemetrySnapshot.memory.source.rawValue
                    )
                    telemetryRow(
                        "Network",
                        freshnessLabel(stats.networkSnapshot.freshness),
                        stats.networkSnapshot.source.rawValue
                    )
                    telemetryRow(
                        "Storage",
                        freshnessLabel(stats.storageSnapshot.freshness),
                        stats.storageSnapshot.source.rawValue
                    )
                    telemetryRow(
                        "Cooling",
                        cooling.telemetryState.label,
                        cooling.snapshot.source.rawValue
                    )
                    telemetryRow("Battery", battery.telemetryStatusLabel, battery.sourceDisplay)
                }
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                TunixPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        TunixSectionHeader(title: "Freshness")
                        diagnosticRow(
                            "Cooling last sample",
                            cooling.lastSuccessfulSampleAt?.formatted(date: .omitted, time: .shortened) ?? "Unavailable"
                        )
                        diagnosticRow("Cooling failures", "\(cooling.consecutiveFailures)")
                        diagnosticRow(
                            "Battery last sample",
                            battery.lastSuccessfulSampleAt?.formatted(date: .omitted, time: .shortened) ?? "Unavailable"
                        )
                        Divider()
                        TunixSectionHeader(title: "Product boundary")
                        diagnosticRow("Process", "Unprivileged app")
                        diagnosticRow("Hardware access", "Read-only")
                        diagnosticRow("Background service", "None")
                        diagnosticRow("Thermal policy", "Managed by macOS")
                        diagnosticRow("Battery policy", "Managed by macOS")
                        Divider()
                        TunixSectionHeader(title: "Keep Awake")
                        diagnosticRow("Status", keepAwake.statusLabel)
                        diagnosticRow("Behavior", keepAwake.statusDetail)
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                copySupportSnapshot()
                            } label: {
                                Label("Copy Current System Snapshot", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("system-health-copy-current-snapshot")
                            .help("Copy a privacy-preserving JSON diagnostic summary")
                            Text("This is a point-in-time system summary. Captured diagnostic evidence is available from Recent Changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("system-health-current-snapshot")
                        }
                        if let snapshotMessage {
                            Text(snapshotMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func telemetryRow(_ label: String, _ status: String, _ source: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body.weight(.semibold))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(status)
                    .font(.subheadline)
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(status), source \(source)")
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private func copySupportSnapshot() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: supportSnapshot(),
                options: [.prettyPrinted, .sortedKeys]
            )
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadUnknown) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            snapshotMessage = "Copied"
        } catch {
            snapshotMessage = "Unable to create support snapshot."
        }
    }

    private func supportSnapshot() -> [String: Any] {
        [
            "application": applicationInfo,
            "telemetry": telemetryInfo,
            "security": [
                "executionModel": "unprivileged",
                "privilegedHelper": false,
                "hardwareWrites": false,
            ],
            "policy": [
                "thermalOwner": "macOS",
                "batteryOwner": "macOS",
            ],
        ]
    }

    private var applicationInfo: [String: String] {
        [
            "name": ProductIdentity.displayName,
            "version": appVersion ?? "unknown",
            "build": appBuild ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "keepAwake": keepAwake.statusLabel.lowercased(),
        ]
    }

    private var telemetryInfo: [String: Any] {
        [
            "cpu": statusInfo(stats.cpuSnapshot.freshness, source: stats.cpuSnapshot.source),
            "memory": statusInfo(
                stats.telemetrySnapshot.memory.freshness,
                source: stats.telemetrySnapshot.memory.source
            ),
            "network": statusInfo(stats.networkSnapshot.freshness, source: stats.networkSnapshot.source),
            "storage": statusInfo(stats.storageSnapshot.freshness, source: stats.storageSnapshot.source),
            "cooling": coolingInfo,
            "battery": batteryInfo,
        ]
    }

    private func statusInfo(_ freshness: TelemetryFreshness, source: TelemetrySource) -> [String: String] {
        [
            "status": freshnessValue(freshness),
            "source": source.rawValue,
        ]
    }

    private var coolingInfo: [String: Any] {
        var info: [String: Any] = [
            "status": cooling.telemetryState.rawValue,
            "source": cooling.snapshot.source.rawValue,
        ]
        if let fanCount = cooling.snapshot.fanCount {
            info["fanCount"] = fanCount
        }
        if let age = sampleAge(cooling.lastSuccessfulSampleAt) {
            info["sampleAgeSeconds"] = age
        }
        return info
    }

    private var batteryInfo: [String: Any] {
        var info: [String: Any] = [
            "status": freshnessValue(battery.snapshot.availability),
            "source": battery.snapshot.source.rawValue,
        ]
        if let age = sampleAge(battery.lastSuccessfulSampleAt) {
            info["sampleAgeSeconds"] = age
        }
        return info
    }

    private func freshnessLabel(_ freshness: TelemetryFreshness) -> String {
        switch freshness {
        case .fresh: return "Available"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        }
    }

    private func freshnessValue(_ freshness: TelemetryFreshness) -> String {
        switch freshness {
        case .fresh: return "available"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        }
    }

    private func sampleAge(_ date: Date?) -> Double? {
        date.map { max(0, Date.now.timeIntervalSince($0)) }
    }

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}

private enum EvidenceSupportState {
    case loading
    case availableNoCapture
    case availableCapture(IncidentPackage)
    case capacityNoCapture
    case capacityCapture(IncidentPackage)
    case unavailable
    case packageFailure(availability: EvidenceJournalAvailability, IncidentPackage)
}

// swiftlint:enable trailing_comma type_body_length
