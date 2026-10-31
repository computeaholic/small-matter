import Charts
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var stats: SystemStatsModel

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "Performance",
                    subtitle: "A focused view of load, memory pressure, and network activity."
                )
                performanceContent(for: layout)
            }
        }
        .navigationTitle("Performance")
    }

    @ViewBuilder
    private func performanceContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact:
            VStack(spacing: TunixDesign.sectionSpacing) {
                cpuSection
                memorySection
                networkSection
            }
        case .standard:
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                    cpuSection
                    memorySection
                }
                VStack(spacing: TunixDesign.sectionSpacing) {
                    cpuSection
                    memorySection
                }
            }
            networkSection
        case .wide, .large:
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                    cpuSection.frame(maxWidth: 560)
                    memorySection.frame(maxWidth: 560)
                }
                networkSection.frame(maxWidth: 1140)
            }
        }
    }

    private var cpuSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                TunixSectionHeader(title: "CPU", subtitle: "Total system utilization")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stats.cpuUsageText)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of all logical CPUs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                PerformanceHistoryChart(stats: stats, kind: .cpu)
                detailGrid([
                    ("User", stats.cpuUserText),
                    ("System", stats.cpuSystemText),
                    ("Idle", stats.cpuIdleText),
                    ("Logical CPUs", stats.logicalCPUText)
                ])
            }
        }
    }

    private var memorySection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    TunixSectionHeader(title: "Memory", subtitle: "Physical memory in use")
                    Spacer(minLength: 12)
                    Text(stats.memoryPressureLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(memoryColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stats.memoryHeadline)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(stats.memoryUsagePercentText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                PerformanceHistoryChart(stats: stats, kind: .memory)
                detailGrid([
                    ("App", stats.memoryAppText),
                    ("Wired", stats.memoryWiredText),
                    ("Compressed", stats.memoryCompressedText),
                    ("Cached", stats.memoryCachedText),
                    ("Swap", stats.memorySwapText),
                    ("Physical", stats.memoryPhysicalText)
                ])
            }
        }
    }

    private var networkSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    TunixSectionHeader(title: "Network", subtitle: stats.networkInterfaceLabel)
                    Spacer(minLength: 12)
                    Text("Last sample")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 28) {
                    TunixValueBlock(label: "Download", value: stats.networkDownloadRateText, emphasis: .title2)
                    TunixValueBlock(label: "Upload", value: stats.networkUploadRateText, emphasis: .title2)
                }
                PerformanceHistoryChart(stats: stats, kind: .network)
                HStack(spacing: 16) {
                    legendItem("Download", systemImage: "arrow.down")
                    legendItem("Upload", systemImage: "arrow.up")
                }
            }
        }
    }

    private var memoryColor: Color {
        switch stats.memoryTelemetry.pressure {
        case .normal: return .secondary
        case .elevated: return TunixBrand.warning
        case .high, .critical: return TunixBrand.critical
        case .unavailable: return .secondary
        }
    }

    private func detailGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                TunixMetricRow(title: item.0, value: item.1)
            }
        }
    }

    private func legendItem(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(title == "Download" ? TunixBrand.accent : TunixBrand.secondary)
    }
}

enum PerformanceChartKind {
    case cpu
    case memory
    case network

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        }
    }
}

struct PerformanceHistoryChart: View {
    @ObservedObject var stats: SystemStatsModel
    let kind: PerformanceChartKind
    var height: CGFloat = TunixDesign.chartHeight

    var body: some View {
        historyContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.title) history")
            .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var historyContent: some View {
        switch kind {
        case .cpu:
            historyChart(
                freshness: stats.cpuSnapshot.freshness,
                isEmpty: stats.cpuHistory.isEmpty
            ) {
                Chart(stats.cpuHistory) { sample in
                    AreaMark(x: .value("Time", sample.timestamp), y: .value("CPU", sample.value))
                        .foregroundStyle(TunixBrand.accent.opacity(0.12))
                    LineMark(x: .value("Time", sample.timestamp), y: .value("CPU", sample.value))
                        .foregroundStyle(TunixBrand.accent)
                }
                .chartYScale(domain: 0 ... 100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(TunixDesign.chartGrid)
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent))%")
                            }
                        }
                    }
                }
                .chartXAxis { timeAxis }
            }
        case .memory:
            historyChart(
                freshness: stats.telemetrySnapshot.memory.freshness,
                isEmpty: stats.memoryHistory.isEmpty
            ) {
                Chart(stats.memoryHistory) { sample in
                    AreaMark(x: .value("Time", sample.timestamp), y: .value("Memory", sample.value))
                        .foregroundStyle(TunixBrand.accent.opacity(0.10))
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Memory", sample.value))
                        .foregroundStyle(TunixBrand.accent)
                }
                .chartYScale(domain: 0 ... max(Double(stats.memoryTelemetry.physicalBytes), 1))
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(TunixDesign.chartGrid)
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(memoryAxisLabel(bytes))
                            }
                        }
                    }
                }
                .chartXAxis { timeAxis }
            }
        case .network:
            historyChart(
                freshness: stats.networkSnapshot.freshness,
                isEmpty: stats.networkHistory.isEmpty
            ) {
                Chart(stats.networkHistory) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Download", sample.downloadBytesPerSecond)
                    )
                    .foregroundStyle(TunixBrand.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Upload", sample.uploadBytesPerSecond)
                    )
                    .foregroundStyle(TunixBrand.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
                .chartYScale(domain: 0 ... networkMaximum)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(TunixDesign.chartGrid)
                        AxisValueLabel {
                            if let rate = value.as(Double.self) {
                                Text(rateAxisLabel(rate))
                            }
                        }
                    }
                }
                .chartXAxis { timeAxis }
            }
        }
    }

    @ViewBuilder
    private func historyChart<Content: View>(
        freshness: TelemetryFreshness,
        isEmpty: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if freshness == .unavailable {
            historyState("Telemetry unavailable")
        } else if freshness == .stale {
            historyState("Telemetry stale")
        } else if isEmpty {
            historyState("Waiting for bounded history")
        } else {
            TunixChartFrame(height: height) { content() }
        }
    }

    private func historyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(TunixDesign.chartGrid)
            AxisValueLabel(format: .dateTime.hour().minute())
        }
    }

    private var accessibilityValue: String {
        switch kind {
        case .cpu: return "Current \(stats.cpuUsageText); bounded history"
        case .memory: return "Current \(stats.memoryUsagePercentText); bounded history"
        case .network:
            return "Download \(stats.networkDownloadRateText), upload \(stats.networkUploadRateText); bounded history"
        }
    }

    private var networkMaximum: Double {
        max(
            stats.networkHistory
                .flatMap { [$0.downloadBytesPerSecond, $0.uploadBytesPerSecond] }
                .max() ?? 0,
            1
        )
    }

    private func memoryAxisLabel(_ bytes: Double) -> String {
        let gigabytes = bytes / 1_000_000_000
        return gigabytes >= 10 ? "\(Int(gigabytes.rounded())) GB" : String(format: "%.1f GB", gigabytes)
    }

    private func rateAxisLabel(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_000_000_000...:
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        default:
            return String(format: "%.0f KB/s", bytesPerSecond / 1000)
        }
    }
}
