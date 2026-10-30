import AppKit
import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var stats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService
    @StateObject private var recentChanges: RecentChangesViewModel

    init(journal: any EvidenceJournal) {
        _recentChanges = StateObject(wrappedValue: RecentChangesViewModel(journal: journal))
    }

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                OverviewHeader(stats: stats)
                OverviewEvidencePanels(
                    stats: stats,
                    cooling: cooling,
                    recentChanges: recentChanges,
                    navigate: navigate
                )
                performancePanel(for: layout)
                supportingPanel
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
        .task { await recentChanges.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .horizon2JournalDidResolve)) { _ in
            Task { await recentChanges.refresh() }
        }
    }

    private func performancePanel(for layout: TunixLayoutClass) -> some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    TunixSectionHeader(
                        title: "Current performance",
                        subtitle: "Live readings with a short bounded trend"
                    )
                    Spacer(minLength: 12)
                    Button("Inspect Performance") { navigate(to: .performance) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("overview-open-performance")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        performanceMetric(title: "CPU", value: stats.cpuUsageText, detail: "Total utilization")
                        performanceMetric(
                            title: "Memory",
                            value: stats.memoryUsagePercentText,
                            detail: "\(stats.memoryPressureLabel) pressure"
                        )
                        trendChart
                            .frame(minWidth: layout == .compact ? 240 : 320, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 26) {
                            performanceMetric(title: "CPU", value: stats.cpuUsageText, detail: "Total utilization")
                            performanceMetric(
                                title: "Memory",
                                value: stats.memoryUsagePercentText,
                                detail: "\(stats.memoryPressureLabel) pressure"
                            )
                        }
                        trendChart
                    }
                }
            }
        }
        .accessibilityIdentifier("overview-current-performance")
    }

    private var supportingPanel: some View {
        OverviewSupportingPanels(stats: stats, battery: battery, navigate: navigate)
    }

    private func performanceMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 110, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU trend · last minute")
                .font(.caption)
                .foregroundStyle(.secondary)
            if stats.cpuHistory.isEmpty || stats.cpuSnapshot.freshness == .unavailable {
                Text("Trend unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                Chart(stats.cpuHistory) { sample in
                    AreaMark(x: .value("Time", sample.timestamp), y: .value("CPU", sample.value))
                        .foregroundStyle(TunixBrand.accent.opacity(0.13))
                    LineMark(x: .value("Time", sample.timestamp), y: .value("CPU", sample.value))
                        .foregroundStyle(TunixBrand.accent)
                }
                .chartYScale(domain: 0 ... 100)
                .chartXAxis(.hidden)
                .frame(height: 88)
                .accessibilityLabel("CPU trend")
                .accessibilityValue("\(stats.cpuUsageText) now; last minute of bounded history")
            }
        }
    }

    private func navigate(to section: AppSection) {
        NotificationCenter.default.post(name: .tunixNavigate, object: section.rawValue)
    }
}
