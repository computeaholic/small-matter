// swiftlint:disable type_body_length
import AppKit
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var stats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                header
                overviewContent(for: layout)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
    }

    @ViewBuilder
    private func overviewContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact:
            VStack(alignment: .leading, spacing: TunixDesign.groupSpacing) {
                compactPrimaryMetrics
                compactStatusMetrics
                compactSupportingMetrics
            }
        case .standard:
            primaryMetrics
            statusMetrics
            supportingMetrics
        case .wide, .large:
            wideOverview
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            TunixPageHeader(
                title: "Overview",
                subtitle: "A quiet read on what your Mac is doing right now."
            )
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 4) {
                if !stats.systemTelemetryIsAvailable {
                    TunixStatusBadge(
                        title: stats.systemTelemetryStatusLabel,
                        systemImage: "exclamationmark.circle",
                        tint: .orange
                    )
                }
                Text("Updated \(stats.lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryMetrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                primaryMetric(
                    title: "CPU",
                    value: stats.cpuUsageText,
                    detail: "Total utilization",
                    systemImage: "cpu"
                )
                primaryMetric(
                    title: "Memory",
                    value: stats.memoryHeadline,
                    detail: memoryDetail,
                    systemImage: "memorychip"
                )
            }
            VStack(spacing: TunixDesign.groupSpacing) {
                primaryMetric(
                    title: "CPU",
                    value: stats.cpuUsageText,
                    detail: "Total utilization",
                    systemImage: "cpu"
                )
                primaryMetric(
                    title: "Memory",
                    value: stats.memoryHeadline,
                    detail: memoryDetail,
                    systemImage: "memorychip"
                )
            }
        }
    }

    private var statusMetrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                statusMetric(
                    title: "Cooling",
                    value: coolingStatusLabel,
                    detail: coolingDetail,
                    systemImage: "fanblades.fill"
                )
                statusMetric(
                    title: "Battery",
                    value: battery.chargePercentString,
                    detail: batteryDetail,
                    systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
                )
            }
            VStack(spacing: TunixDesign.groupSpacing) {
                statusMetric(
                    title: "Cooling",
                    value: coolingStatusLabel,
                    detail: coolingDetail,
                    systemImage: "fanblades.fill"
                )
                statusMetric(
                    title: "Battery",
                    value: battery.chargePercentString,
                    detail: batteryDetail,
                    systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
                )
            }
        }
    }

    private var supportingMetrics: some View {
        HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
            supportingMetric(
                title: "Storage",
                value: stats.storageHasSample ? stats.diskFreeText : "Unavailable",
                detail: storageDetail,
                systemImage: "internaldrive"
            )
            supportingMetric(
                title: "Network",
                value: networkValue,
                detail: networkDetail,
                systemImage: "network"
            )
        }
    }

    private var compactPrimaryMetrics: some View {
        VStack(spacing: TunixDesign.groupSpacing) {
            primaryMetric(
                title: "CPU",
                value: stats.cpuUsageText,
                detail: "Total utilization",
                systemImage: "cpu"
            )
            primaryMetric(
                title: "Memory",
                value: stats.memoryHeadline,
                detail: memoryDetail,
                systemImage: "memorychip"
            )
        }
    }

    private var compactStatusMetrics: some View {
        VStack(spacing: TunixDesign.groupSpacing) {
            statusMetric(
                title: "Cooling",
                value: coolingStatusLabel,
                detail: coolingDetail,
                systemImage: "fanblades.fill"
            )
            statusMetric(
                title: "Battery",
                value: battery.chargePercentString,
                detail: batteryDetail,
                systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
            )
        }
    }

    private var compactSupportingMetrics: some View {
        VStack(spacing: TunixDesign.groupSpacing) {
            supportingMetric(
                title: "Storage",
                value: stats.storageHasSample ? stats.diskFreeText : "Unavailable",
                detail: storageDetail,
                systemImage: "internaldrive"
            )
            supportingMetric(
                title: "Network",
                value: networkValue,
                detail: networkDetail,
                systemImage: "network"
            )
        }
    }

    private var wideOverview: some View {
        VStack(alignment: .leading, spacing: TunixDesign.groupSpacing) {
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                primaryMetric(
                    title: "CPU",
                    value: stats.cpuUsageText,
                    detail: "Total utilization",
                    systemImage: "cpu"
                )
                primaryMetric(
                    title: "Memory",
                    value: stats.memoryHeadline,
                    detail: memoryDetail,
                    systemImage: "memorychip"
                )
            }
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                statusMetric(
                    title: "Cooling",
                    value: coolingStatusLabel,
                    detail: coolingDetail,
                    systemImage: "fanblades.fill"
                )
                statusMetric(
                    title: "Battery",
                    value: battery.chargePercentString,
                    detail: batteryDetail,
                    systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
                )
                supportingMetric(
                    title: "Storage",
                    value: stats.storageHasSample ? stats.diskFreeText : "Unavailable",
                    detail: storageDetail,
                    systemImage: "internaldrive"
                )
                supportingMetric(
                    title: "Network",
                    value: networkValue,
                    detail: networkDetail,
                    systemImage: "network"
                )
            }
        }
    }

    private func primaryMetric(title: String, value: String, detail: String, systemImage: String) -> some View {
        metricPanel(title: title, value: value, detail: detail, systemImage: systemImage, emphasis: .title)
            .frame(minHeight: 142)
    }

    private func statusMetric(title: String, value: String, detail: String, systemImage: String) -> some View {
        metricPanel(title: title, value: value, detail: detail, systemImage: systemImage, emphasis: .title2)
            .frame(minHeight: 112)
    }

    private func supportingMetric(title: String, value: String, detail: String, systemImage: String) -> some View {
        metricPanel(title: title, value: value, detail: detail, systemImage: systemImage, emphasis: .title3)
            .frame(minHeight: 102)
    }

    private func metricPanel(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        emphasis: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(value)
                .font(emphasis.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TunixDesign.panelFill,
            in: RoundedRectangle(cornerRadius: TunixDesign.panelRadius, style: .continuous)
        )
        .contextMenu {
            Button("Copy \(title)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }

    private var storageDetail: String {
        guard let free = stats.storageSnapshot.freeBytes,
              let total = stats.storageSnapshot.totalBytes,
              total > 0
        else { return "Storage unavailable" }
        let freePercent = Int((Double(free) / Double(total)) * 100)
        return "\(freePercent)% free of \(stats.diskTotalText)"
    }

    private var memoryDetail: String {
        "\(stats.memoryUsagePercentText) used · \(stats.memoryPressureLabel) pressure"
    }

    private var batteryDetail: String {
        "\(battery.powerStateLabel) · \(battery.powerDisplay)"
    }

    private var networkValue: String {
        "↓ \(stats.networkDownloadRateText)"
    }

    private var networkDetail: String {
        "↑ \(stats.networkUploadRateText) · \(stats.networkInterfaceLabel)"
    }

    private var coolingDetail: String {
        let fans = cooling.snapshot.fans.prefix(2).map { "Fan \($0.fanIndex + 1) \($0.currentRPM) RPM" }
        let temperature = CoolingTemperaturePresentation.groups(cooling.snapshot.temperatures).first.map {
            let value = TemperaturePresentation.string(
                celsius: $0.valueCelsius,
                unit: settings.settings.temperatureUnit
            )
            return "\($0.label) \(value)"
        }
        let readings = Array(fans) + (temperature.map { [$0] } ?? [])
        return readings.isEmpty ? "Cooling telemetry unavailable" : readings.joined(separator: " · ")
    }

    private var coolingStatusLabel: String {
        switch cooling.telemetryState {
        case .available: return "Normal"
        case .partial: return "Limited"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        }
    }
}

// swiftlint:enable type_body_length
