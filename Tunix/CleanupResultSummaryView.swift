import SwiftUI

struct CleanupResultSummaryView: View {
    @ObservedObject var diskTool: DiskTool
    let formatter: ByteCountFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = diskTool.lastResult {
                TunixSectionHeader(
                    title: "Last deletion",
                    subtitle: result.completedAt.formatted(date: .abbreviated, time: .shortened)
                )
                HStack(spacing: 14) {
                    CleanupSummaryMetric("Deleted", value: "\(result.deletedCount)")
                    CleanupSummaryMetric("Failed", value: "\(result.failedCount)")
                    CleanupSummaryMetric("Changed", value: "\(result.staleCount)")
                }
                Text(
                    "Estimated target: \(formatter.string(fromByteCount: Int64(result.estimatedAllocatedBytes))) · " +
                        observedReclaimedText(result)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !result.diagnostics.isEmpty {
                    DisclosureGroup("Failure summary") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(result.diagnostics) { diagnostic in
                                Text("\(diagnostic.count) · \(diagnostic.category) · \(diagnostic.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }

            if let error = diskTool.lastError {
                Label("Needs attention", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(TunixBrand.warning)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("cleanup-result-summary")
    }

    private func observedReclaimedText(_ result: CleanupDeletionResult) -> String {
        guard let observed = result.observedSpaceReclaimedBytes else {
            return "Observed free-space change unavailable"
        }
        return "Observed free-space change: \(formatter.string(fromByteCount: Int64(observed)))"
    }
}

struct CleanupSummaryMetric: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

struct CleanupCapabilityNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TunixSectionHeader(title: "Access and safety")
            Text(
                CleanupDistributionContext.current == .appStore
                    ? "The Mac App Store sandbox limits cleanup to Small Matter-owned disposable data. " +
                    "Other locations require an explicit supported access grant and are not scanned here."
                    : "Direct distribution uses the same conservative app-owned scope. Small Matter does not request " +
                    "Full Disk Access, elevate privileges, or bypass macOS protections."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Quarantined files are reversible; permanently deleted files are not.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("cleanup-capability-note")
    }
}
