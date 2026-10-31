import SwiftUI

@MainActor
struct OverviewPerformanceHero: View {
    @ObservedObject var stats: SystemStatsModel
    @ObservedObject var battery: BatteryManager
    let layout: TunixLayoutClass
    let navigate: (AppSection) -> Void

    var body: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    TunixSectionHeader(
                        title: "Live performance",
                        subtitle: "CPU, memory, and network with bounded system history"
                    )
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        TunixStatusBadge(
                            title: stats.systemTelemetryStatusLabel,
                            systemImage: freshnessIcon,
                            tint: freshnessColor
                        )
                        Text("Updated \(stats.lastTelemetryUpdatedText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Inspect Performance") { navigate(.performance) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("overview-open-performance")
                }

                chartLayout

                OverviewSupportingPanels(stats: stats, battery: battery, navigate: navigate)
            }
        }
        .accessibilityIdentifier("overview-performance-hero")
    }

    @ViewBuilder
    private var chartLayout: some View {
        switch layout {
        case .compact:
            VStack(spacing: TunixDesign.groupSpacing) {
                chartCard(.cpu)
                chartCard(.memory)
                chartCard(.network)
            }
        case .standard, .wide, .large:
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: TunixDesign.groupSpacing),
                    count: 3
                ),
                spacing: TunixDesign.groupSpacing
            ) {
                chartCard(.cpu)
                chartCard(.memory)
                chartCard(.network)
            }
        }
    }

    private func chartCard(_ kind: PerformanceChartKind) -> some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 12) {
                switch kind {
                case .cpu:
                    metricHeader(
                        title: "CPU",
                        headline: stats.cpuUsageText,
                        detail: "Total utilization · \(stats.logicalCPUText) logical CPUs"
                    )
                    PerformanceHistoryChart(stats: stats, kind: .cpu, height: 118)
                case .memory:
                    metricHeader(
                        title: "Memory",
                        headline: stats.memoryUsagePercentText,
                        detail: "\(stats.memoryHeadline) · \(stats.memoryPressureLabel) pressure"
                    )
                    PerformanceHistoryChart(stats: stats, kind: .memory, height: 118)
                case .network:
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Network")
                            .font(.headline)
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            rateMetric(label: "Download", value: stats.networkDownloadRateText, icon: "arrow.down")
                            rateMetric(label: "Upload", value: stats.networkUploadRateText, icon: "arrow.up")
                        }
                        Text(stats.networkInterfaceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    PerformanceHistoryChart(stats: stats, kind: .network, height: 118)
                }
            }
        }
        .accessibilityIdentifier("overview-performance-\(kindIdentifier(kind))")
    }

    private func metricHeader(title: String, headline: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            Text(headline)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func rateMetric(label: String, value: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(label == "Download" ? TunixBrand.accent : TunixBrand.secondary)
        }
    }

    private var freshnessIcon: String {
        switch stats.cpuSnapshot.freshness {
        case .fresh: return "checkmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "exclamationmark.circle"
        }
    }

    private var freshnessColor: Color {
        switch stats.cpuSnapshot.freshness {
        case .fresh: return TunixBrand.healthy
        case .stale: return TunixBrand.warning
        case .unavailable: return TunixBrand.critical
        }
    }

    private func kindIdentifier(_ kind: PerformanceChartKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .network: return "network"
        }
    }
}
