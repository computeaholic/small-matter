import SwiftUI

@MainActor
struct OverviewHeader: View {
    @ObservedObject var stats: SystemStatsModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            TunixPageHeader(
                title: "Overview",
                subtitle: "A quiet read on what your Mac is experiencing right now."
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
                Text(stats.systemTelemetryStatusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stats.systemTelemetryIsAvailable ? .secondary : TunixBrand.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Overview. \(stats.systemTelemetryStatusLabel). " +
                "Updated \(stats.lastUpdated.formatted(date: .omitted, time: .shortened))"
        )
    }
}
