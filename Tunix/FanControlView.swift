import SwiftUI

struct FanControlView: View {
    @EnvironmentObject private var cooling: CoolingService
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
            VStack(alignment: .leading, spacing: 12) {
                TunixSectionHeader(title: "Temperatures", subtitle: "Representative readings")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                        ForEach(groups) { group in
                            temperatureRow(group)
                        }
                    }
                    VStack(spacing: TunixDesign.rowSpacing) {
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                        ForEach(cooling.snapshot.fans, id: \.fanIndex) { fan in
                            fanModule(fan)
                        }
                    }
                    VStack(spacing: TunixDesign.rowSpacing) {
                        ForEach(cooling.snapshot.fans, id: \.fanIndex) { fan in
                            fanModule(fan)
                        }
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
        HStack {
            Text(group.label)
                .font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(group.valueCelsius, specifier: "%.1f")°C")
                    .font(.body.weight(.semibold).monospacedDigit())
                if group.readingCount > 1 {
                    Text("\(group.readingCount) readings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.label), \(group.valueCelsius, specifier: "%.1f") degrees Celsius")
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
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(TunixDesign.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan \(fan.fanIndex + 1), \(fan.currentRPM) RPM, \(rangeText(for: fan))")
    }

    func rangeText(for fan: CoolingFan) -> String {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else {
            return "Operating range unavailable"
        }
        return "Range \(minimum)–\(maximum) RPM"
    }
}
