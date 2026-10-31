import SwiftUI

@MainActor
struct OverviewEvidencePanels: View {
    @ObservedObject var stats: SystemStatsModel
    @ObservedObject var cooling: CoolingService
    @ObservedObject var recentChanges: RecentChangesViewModel
    let navigate: (AppSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
            conditionPanel
            changesPanel
        }
    }

    private var conditionPanel: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: conditionIcon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(conditionColor)
                        .frame(width: 52, height: 52)
                        .background(conditionColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(conditionTitle)
                            .font(.title2.weight(.semibold))
                        Text(conditionDetail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 8) {
                        TunixStatusBadge(title: conditionBadge, systemImage: conditionIcon, tint: conditionColor)
                        Button("System Health") { navigate(.security) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("overview-open-system-health")
                    }
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        conditionFact("Thermal state", value: stats.thermalStateLabel, detail: stats.thermalStateDetail)
                        conditionFact(
                            "Performance data",
                            value: stats.systemTelemetryStatusLabel,
                            detail: "Updated \(stats.lastTelemetryUpdatedText)"
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
                    Button("Open Recent Changes") { navigate(.recentChanges) }
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
                Text("\(row.timeText) · \(row.sourceText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(row.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.title), \(row.summary), \(row.timeText), source \(row.sourceText), \(row.statusText)"
        )
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
}
