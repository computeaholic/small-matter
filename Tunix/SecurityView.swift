// swiftlint:disable trailing_comma type_body_length
import AppKit
import SwiftUI

struct SecurityView: View {
    @EnvironmentObject private var stats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var snapshotMessage: String?

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
    }

    @ViewBuilder
    private func healthContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact, .standard:
            integritySection
            telemetrySection
            detailsSection
        case .wide, .large:
            HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    integritySection
                    telemetrySection
                }
                detailsSection
                    .frame(maxWidth: 420, alignment: .topLeading)
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
            DisclosureGroup("Diagnostics") {
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
                        Button {
                            copySupportSnapshot()
                        } label: {
                            Label("Copy Support Snapshot", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .help("Copy a privacy-preserving JSON diagnostic summary")
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

// swiftlint:enable trailing_comma type_body_length
