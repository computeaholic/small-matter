import SwiftUI

struct CleanupCandidateRow: View {
    @ObservedObject var diskTool: DiskTool
    let candidate: CleanupCandidate
    let formatter: ByteCountFormatter

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                isOn: Binding(
                    get: { diskTool.isSelected(candidate) },
                    set: { diskTool.setSelected(candidate, isSelected: $0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName)
                        .font(.body.weight(.semibold))
                    Text(candidate.evidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Permanently deleted · \(candidate.category)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            Text(formatter.string(fromByteCount: Int64(candidate.allocatedBytes)))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(candidate.displayName), \(formatter.string(fromByteCount: Int64(candidate.allocatedBytes))), " +
                "eligible for permanent deletion"
        )
        .accessibilityIdentifier("cleanup-candidate-\(candidate.id)")
    }
}
