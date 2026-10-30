import SwiftUI

@MainActor
struct OverviewSupportingPanels: View {
    @ObservedObject var stats: SystemStatsModel
    @ObservedObject var battery: BatteryManager
    let navigate: (AppSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
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
            investigatePanel
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
                    Button("Details") { navigate(.battery) }
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
                    if let freePercent {
                        Text("free")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(freePercent)%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(storageColor)
                    }
                }
                Text(stats.storageHasSample ? "of \(stats.diskTotalText) on the startup volume" :
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
    }

    private func investigateButton(_ title: String, systemImage: String, destination: AppSection) -> some View {
        Button { navigate(destination) } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("overview-investigate-\(destination.rawValue)")
    }

    private var freePercent: Int? {
        guard let free = stats.storageSnapshot.freeBytes,
              let total = stats.storageSnapshot.totalBytes,
              total > 0
        else { return nil }
        return Int((Double(free) / Double(total) * 100).rounded())
    }

    private var storageColor: Color {
        guard let freePercent else { return .secondary }
        return freePercent < 10 ? TunixBrand.warning : TunixBrand.accent
    }
}
