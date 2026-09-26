// swiftlint:disable trailing_comma
import Charts
import SwiftUI

struct BatteryView: View {
    @EnvironmentObject private var battery: BatteryManager

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "Battery",
                    subtitle: "Charge, health, and electrical readings from macOS."
                )
                batteryContent(for: layout)
            }
        }
        .navigationTitle("Battery")
    }

    @ViewBuilder
    private func batteryContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact:
            chargeSection
            historySection
            healthSection
            electricalSection
            telemetryDetails
            readOnlyNote
        case .standard:
            chargeSection
            historySection
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                    healthSection
                    electricalSection
                }
                VStack(spacing: TunixDesign.sectionSpacing) {
                    healthSection
                    electricalSection
                }
            }
            telemetryDetails
            readOnlyNote
        case .wide, .large:
            HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    chargeSection
                    historySection
                }
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    healthSection
                    electricalSection
                }
            }
            telemetryDetails
            readOnlyNote
        }
    }
}

private extension BatteryView {
    var chargeSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(battery.chargePercentString)
                            .font(.system(size: 58, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("Charge")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(battery.powerStateLabel)
                            .font(.title3.weight(.semibold))
                        Text(battery.powerDisplay)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                ProgressView(value: battery.chargePercent ?? 0, total: 100)
                    .tint(battery.isCharging ? TunixBrand.healthy : TunixBrand.accent)
                    .accessibilityLabel("Battery charge")
                    .accessibilityValue(battery.chargePercentString)
            }
        }
    }

    var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TunixSectionHeader(title: "Charge history", subtitle: "Today")
            if battery.todayHistory.isEmpty {
                Text("Collecting charge history…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                Chart(battery.todayHistory) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Charge", point.chargeLevel)
                    )
                    .foregroundStyle(battery.isCharging ? TunixBrand.healthy : TunixBrand.accent)
                }
                .chartYScale(domain: 0 ... 100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(TunixDesign.chartGrid)
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(TunixDesign.chartGrid)
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent))%")
                            }
                        }
                    }
                }
                .frame(height: 150)
                .accessibilityHidden(true)
            }
        }
    }

    var healthSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                TunixSectionHeader(title: "Health")
                metricGrid([
                    ("Health", battery.healthPercentString),
                    ("Cycle count", battery.cycleCountText),
                    ("Maximum capacity", battery.maxCapacityDisplay),
                    ("Design capacity", battery.designCapacityDisplay),
                ])
            }
        }
    }

    var electricalSection: some View {
        TunixPanel {
            VStack(alignment: .leading, spacing: 16) {
                TunixSectionHeader(title: "Electrical")
                metricGrid([
                    ("Power", battery.signedPowerDisplay),
                    ("Voltage", battery.voltageDisplay),
                    ("Current", battery.amperageDisplay),
                    ("Temperature", battery.temperatureDisplay),
                    ("Time remaining", battery.timeToEmptyDisplay),
                    ("Time to full", battery.timeToFullDisplay),
                ])
            }
        }
    }

    var telemetryDetails: some View {
        DisclosureGroup("Telemetry details") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Source", battery.sourceDisplay)
                detailRow("Last sample", battery.staleAgeDisplay)
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    var readOnlyNote: some View {
        Label(
            "\(ProductIdentity.displayName) observes battery state; macOS remains responsible for charging policy.",
            systemImage: "checkmark.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    func metricGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                TunixMetricRow(title: item.0, value: item.1)
            }
        }
    }

    func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

// swiftlint:enable trailing_comma
