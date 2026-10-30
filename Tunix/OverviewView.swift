import AppKit
import Charts
import SwiftUI

// Why: canonical contract owner.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
struct OverviewView: View {
    @EnvironmentObject private var settings: SettingsManager
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
                header
                conditionPanel
                changesPanel
                performancePanel(for: layout)
                supportingPanel
                investigatePanel
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
        .task { await recentChanges.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .horizon2JournalDidResolve)) { _ in
            Task { await recentChanges.refresh() }
        }
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
        if !readings.isEmpty {
            return "Thermal \(cooling.thermalStateLabel) · " + readings.joined(separator: " · ")
        }
        return "Thermal \(cooling.thermalStateLabel) · \(cooling.sensorAvailabilityDescription)"
    }

    private var coolingStatusLabel: String {
        switch cooling.telemetryState {
        case .available: return "Normal"
        case .partial: return "Thermal state"
        case .stale: return "Stale sensors"
        case .unavailable: return "Thermal unavailable"
        }
    }

    private var conditionPanel: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: conditionIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(conditionColor)
                        .frame(width: 42, height: 42)
                        .background(conditionColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(conditionTitle)
                            .font(.title3.weight(.semibold))
                        Text(conditionDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    TunixStatusBadge(title: conditionBadge, systemImage: conditionIcon, tint: conditionColor)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        conditionFact("Thermal state", value: stats.thermalStateLabel, detail: stats.thermalStateDetail)
                        conditionFact(
                            "Performance data",
                            value: stats.systemTelemetryStatusLabel,
                            detail: "CPU, memory, storage, and network"
                        )
                        conditionFact("Hardware detail", value: coolingCoverageTitle, detail: coolingCoverageDetail)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        conditionFact("Thermal state", value: stats.thermalStateLabel, detail: stats.thermalStateDetail)
                        conditionFact(
                            "Performance data",
                            value: stats.systemTelemetryStatusLabel,
                            detail: "CPU, memory, storage, and network"
                        )
                        conditionFact("Hardware detail", value: coolingCoverageTitle, detail: coolingCoverageDetail)
                    }
                }
            }
        }
        .accessibilityIdentifier("overview-current-condition")
    }

    private var changesPanel: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    TunixSectionHeader(
                        title: "What changed?",
                        subtitle: "Recent observations with a known evidence basis"
                    )
                    Spacer(minLength: 12)
                    Button("Open Recent Changes") { navigate(to: .recentChanges) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("overview-open-recent-changes")
                }

                switch recentChanges.state {
                case .loading:
                    Label("Loading evidence history…", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("overview-changes-loading")
                case .journalUnavailable:
                    changeState(
                        "Evidence history is unavailable.",
                        detail: "Small Matter could not open its local evidence journal.",
                        identifier: "overview-changes-unavailable"
                    )
                case .journalCapacityUnavailable:
                    changeState(
                        "Evidence history may not be saving.",
                        detail: "Local evidence storage is full or unavailable. Existing history has not been " +
                            "reported as lost.",
                        identifier: "overview-changes-capacity"
                    )
                case .availableEmpty:
                    changeState(
                        "No qualifying changes have been observed yet.",
                        detail: "That does not establish that nothing changed; it means no supported transition is " +
                            "currently in the local history.",
                        identifier: "overview-changes-empty"
                    )
                case .availableWithChanges, .incompleteEvidence:
                    if recentChanges.rows.isEmpty {
                        changeState(
                            "No qualifying changes are available.",
                            detail: "Evidence coverage is limited, so the absence of a row is not a claim that " +
                                "nothing happened.",
                            identifier: "overview-changes-limited-empty"
                        )
                    } else {
                        ForEach(Array(recentChanges.rows.prefix(3))) { row in
                            overviewChangeRow(row)
                        }
                        if recentChanges.state == .incompleteEvidence {
                            Label(
                                recentChanges.coverageWarning ?? "Some changes may be missing.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("overview-changes-incomplete")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("overview-what-changed")
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
                            detail: "(stats.memoryPressureLabel) pressure"
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
                                detail: "(stats.memoryPressureLabel) pressure"
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                batterySummary
                storageSummary
            }
            VStack(spacing: TunixDesign.groupSpacing) {
                batterySummary
                storageSummary
            }
        }
    }

    private var batterySummary: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        "Battery & power",
                        systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
                    )
                    .font(.headline)
                    Spacer()
                    Button("Details") { navigate(to: .battery) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("overview-open-battery")
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(battery.chargePercentString)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(battery.powerStateLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(battery.powerDisplay)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(
                    battery.snapshot.availability == .unavailable
                        ? "Battery readings are unavailable."
                        : "Charging policy remains managed by macOS."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("overview-battery-summary")
    }

    private var storageSummary: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stats.storageHasSample ? stats.diskFreeText : "Unavailable")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    if let freePercent = storageFreePercent {
                        Text("free")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("(freePercent)%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(storageColor)
                    }
                }
                Text(stats
                    .storageHasSample ? "of (stats.diskTotalText) on the startup volume" :
                    "Storage capacity is unavailable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("overview-storage-summary")
    }

    private var investigatePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TunixSectionHeader(title: "Investigate", subtitle: "Choose the next useful view")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    investigateButton(
                        "Recent Changes",
                        systemImage: "clock.arrow.circlepath",
                        destination: .recentChanges
                    )
                    investigateButton("System Health", systemImage: "heart.text.square", destination: .security)
                    investigateButton("Cleanup", systemImage: "sparkles.rectangle.stack", destination: .cleanup)
                }
                VStack(spacing: 10) {
                    investigateButton(
                        "Recent Changes",
                        systemImage: "clock.arrow.circlepath",
                        destination: .recentChanges
                    )
                    investigateButton("System Health", systemImage: "heart.text.square", destination: .security)
                    investigateButton("Cleanup", systemImage: "sparkles.rectangle.stack", destination: .cleanup)
                }
            }
        }
        .accessibilityIdentifier("overview-investigate")
    }

    private func investigateButton(_ title: String, systemImage: String, destination: AppSection) -> some View {
        Button { navigate(to: destination) } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("overview-investigate-(destination.rawValue)")
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
        .accessibilityLabel("(title), (value), (detail)")
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
                .accessibilityValue("(stats.cpuUsageText) now; last minute of bounded history")
            }
        }
    }

    private func overviewChangeRow(_ row: RecentChangeRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.isSupplemental ? "network" : "arrow.triangle.2.circlepath")
                .foregroundStyle(row.isSupplemental ? TunixBrand.secondary : TunixBrand.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(row.timeText) · (row.sourceText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(row.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("(row.title), (row.summary), (row.timeText), source (row.sourceText), (row.statusText)")
    }

    private func conditionFact(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeState(_ title: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var conditionTitle: String {
        switch stats.thermalState {
        case .serious, .critical: return "Thermal pressure reported"
        default: return conditionIsLimited ? "Some information unavailable" : "Monitoring normally"
        }
    }

    private var conditionBadge: String {
        switch stats.thermalState {
        case .serious, .critical: return stats.thermalConditionLabel
        default: return conditionIsLimited ? "Limited coverage" : "Reporting"
        }
    }

    private var conditionDetail: String {
        switch stats.thermalState {
        case .serious, .critical:
            return "macOS is reporting thermal pressure. This is an observation, not a diagnosis of a " +
                "specific component."
        default:
            return conditionIsLimited
                ? "Available telemetry is updating, but one or more sources cannot currently provide complete coverage."
                : "Available telemetry is updating. Small Matter does not assign a synthetic health score."
        }
    }

    private var conditionIcon: String {
        switch stats.thermalState {
        case .serious, .critical: return "thermometer.sun"
        default: return conditionIsLimited ? "exclamationmark.circle" : "checkmark.circle"
        }
    }

    private var conditionColor: Color {
        switch stats.thermalState {
        case .serious, .critical: return stats.thermalStateColor
        default: return conditionIsLimited ? TunixBrand.warning : TunixBrand.healthy
        }
    }

    private var conditionIsLimited: Bool {
        stats.telemetrySnapshot.thermal.freshness == .unavailable
            || !stats.systemTelemetryIsAvailable
            || battery.snapshot.availability == .unavailable
    }

    private var coolingCoverageTitle: String {
        switch cooling.telemetryState {
        case .available: return "Available"
        case .partial: return "Partial"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        }
    }

    private var coolingCoverageDetail: String {
        switch cooling.telemetryState {
        case .available: return "Read-only cooling readings"
        case .partial: return "Some readings are available"
        case .stale: return "Last reading is old"
        case .unavailable: return "macOS thermal state remains separate"
        }
    }

    private var storageFreePercent: Int? {
        guard let free = stats.storageSnapshot.freeBytes,
              let total = stats.storageSnapshot.totalBytes,
              total > 0
        else { return nil }
        return Int((Double(free) / Double(total) * 100).rounded())
    }

    private var storageColor: Color {
        guard let freePercent = storageFreePercent else { return .secondary }
        return freePercent < 10 ? TunixBrand.warning : TunixBrand.accent
    }

    private func navigate(to section: AppSection) {
        NotificationCenter.default.post(name: .tunixNavigate, object: section.rawValue)
    }
}
