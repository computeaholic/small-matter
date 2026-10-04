import SwiftUI

struct FanControlView: View {
    @EnvironmentObject private var cooling: CoolingService
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var systemStats: SystemStatsModel

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "Cooling",
                    subtitle: "A calm view of thermal condition and fan response. macOS manages cooling policy."
                )
                coolingContent(for: layout)
            }
        }
        .navigationTitle("Cooling")
    }

    @ViewBuilder
    private func coolingContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact, .standard:
            thermalSummary
            temperatureSection
            fanSection
            policyNote
        case .wide, .large:
            HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    thermalSummary
                    temperatureSection
                }
                fanSection
                    .frame(maxWidth: 560)
            }
            policyNote
        }
    }
}

private extension FanControlView {
    var thermalSummary: some View {
        TunixPanel {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thermal condition")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(systemStats.thermalConditionLabel)
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(systemStats.thermalStateDetail)
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                    if cooling.telemetryState == .stale || cooling.telemetryState == .unavailable {
                        TunixStatusBadge(
                            title: cooling.telemetryState == .stale ? "Reading stale" : "Reading unavailable",
                            systemImage: "exclamationmark.circle",
                            tint: .orange
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    var temperatureSection: some View {
        let groups = CoolingTemperaturePresentation.groups(cooling.snapshot.temperatures)
        if !groups.isEmpty {
            TunixPanel {
                VStack(alignment: .leading, spacing: 14) {
                    TunixSectionHeader(title: "Temperatures", subtitle: "Representative readings")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170, maximum: 230), alignment: .leading)],
                        alignment: .leading,
                        spacing: TunixDesign.groupSpacing
                    ) {
                        ForEach(groups) { group in
                            temperatureRow(group)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var fanSection: some View {
        if !cooling.snapshot.fans.isEmpty, cooling.telemetryState != .unavailable {
            VStack(alignment: .leading, spacing: 12) {
                TunixSectionHeader(title: "Fans", subtitle: "Current speed and operating range")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 280), alignment: .leading)],
                    alignment: .leading,
                    spacing: TunixDesign.groupSpacing
                ) {
                    ForEach(cooling.snapshot.fans, id: \.fanIndex) { fan in
                        fanModule(fan)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                cooling.telemetryState == .stale ? "Fan telemetry is stale" : "Fan telemetry unavailable",
                systemImage: "fan.slash",
                description: Text("Cooling policy remains managed by macOS.")
            )
        }
    }

    var policyNote: some View {
        Label("Cooling is managed automatically by macOS.", systemImage: "checkmark.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func temperatureRow(_ group: CoolingTemperatureGroup) -> some View {
        let temperatureText = TemperaturePresentation.string(
            celsius: group.valueCelsius,
            unit: settings.settings.temperatureUnit
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(group.label)
                .font(.subheadline.weight(.semibold))
            Text(temperatureText)
                .font(.title2.weight(.semibold).monospacedDigit())
            if group.readingCount > 1 {
                Text("\(group.readingCount) sensors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 230, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cooling-temperature-\(group.label.lowercased())")
        .accessibilityLabel("\(group.label), \(temperatureText)")
    }

    func fanModule(_ fan: CoolingFan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text("Fan \(fan.fanIndex + 1)")
                    .font(.headline)
            }
            Text("\(fan.currentRPM) RPM")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(rangeText(for: fan))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: 280, minHeight: 132, alignment: .leading)
        .background(TunixDesign.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan \(fan.fanIndex + 1), \(fan.currentRPM) RPM, \(rangeText(for: fan))")
    }

    func rangeText(for fan: CoolingFan) -> String {
        return reportedRangeText(for: fan)
    }
}

extension FanControlView {
    func reportedRangeText(for fan: CoolingFan) -> String {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else {
            return "Operating range unavailable"
        }
        return "Reported range \(minimum)–\(maximum) RPM"
    }
}
