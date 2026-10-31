import SwiftUI

@MainActor
struct OverviewSupportingPanels: View {
    @ObservedObject var stats: SystemStatsModel
    @ObservedObject var battery: BatteryManager
    let navigate: (AppSection) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: TunixDesign.groupSpacing) {
                batterySummary
                Divider()
                    .frame(height: 44)
                storageSummary
            }
            VStack(spacing: TunixDesign.groupSpacing) {
                batterySummary
                storageSummary
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(
            TunixDesign.subtleFill,
            in: RoundedRectangle(cornerRadius: TunixDesign.panelRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TunixDesign.panelRadius, style: .continuous)
                .stroke(TunixDesign.panelStroke, lineWidth: 0.75)
        }
        .accessibilityIdentifier("overview-supporting-details")
    }

    private var batterySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(
                    "Battery & power",
                    systemImage: battery.isCharging ? "bolt.battery.100percent" : "battery.100percent"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Details") { navigate(.battery) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("overview-open-battery")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(battery.chargePercentString)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(battery.powerStateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(battery.powerDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview-battery-summary")
    }

    private var storageSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Storage", systemImage: "internaldrive")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.storageHasSample ? stats.diskFreeText : "Unavailable")
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let freePercent {
                    Text("free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(freePercent)%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(storageColor)
                }
            }
            Text(stats.storageHasSample ? "of \(stats.diskTotalText) on the startup volume" :
                "Storage capacity is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview-storage-summary")
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
