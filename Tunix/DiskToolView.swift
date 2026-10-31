import SwiftUI

struct DiskToolView: View {
    @EnvironmentObject private var diskTool: DiskTool
    @State private var showingDeletionConfirmation = false

    private let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "Cleanup",
                    subtitle:
                    "Review only verified Small Matter-owned or supported user-selected data, then delete it " +
                        "deliberately."
                )
                cleanupContent(for: layout)
            }
        }
        .navigationTitle("Cleanup")
        .confirmationDialog(
            "Delete eligible files?",
            isPresented: $showingDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Eligible Files", role: .destructive) {
                diskTool.deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the reviewed eligible files in the selected supported scope. " +
                    "They are not placed in Quarantine and cannot be undone."
            )
        }
    }

    @ViewBuilder
    private func cleanupContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact, .standard:
            workflow
            controls
            opportunityList
            CleanupResultSummaryView(diskTool: diskTool, formatter: formatter)
            CleanupCapabilityNote()
        case .wide, .large:
            HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    workflow
                    controls
                    opportunityList
                }
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    CleanupResultSummaryView(diskTool: diskTool, formatter: formatter)
                    CleanupCapabilityNote()
                }
                .frame(width: 340, alignment: .topLeading)
            }
        }
    }

    private var workflow: some View {
        HStack(spacing: 10) {
            workflowStep("1", "Scan")
            workflowDivider
            workflowStep("2", "Review")
            workflowDivider
            workflowStep("3", "Delete")
            workflowDivider
            workflowStep("4", "Verify")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cleanup workflow: scan, review, delete, verify")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(diskTool.isScanning ? "Scanning…" : scanLabel) {
                diskTool.scan()
            }
            .buttonStyle(.borderedProminent)
            .disabled(diskTool.isScanning || diskTool.isDeleting)
            .accessibilityIdentifier("cleanup-scan")

            Button("Review Xcode Derived Data…") {
                diskTool.chooseXcodeDerivedDataLocation()
            }
            .buttonStyle(.bordered)
            .disabled(diskTool.isScanning || diskTool.isDeleting)
            .accessibilityIdentifier("cleanup-choose-derived-data")

            Button(diskTool.isDeleting ? "Deleting…" : "Delete Selected…") {
                showingDeletionConfirmation = true
            }
            .buttonStyle(.bordered)
            .disabled(
                diskTool.isScanning || diskTool.isDeleting || diskTool.inventory == nil
                    || diskTool.selectedCandidateIDs.isEmpty
            )
            .accessibilityIdentifier("cleanup-delete-selected")

            if diskTool.lastAction != nil {
                Button("Undo Last Quarantine") {
                    diskTool.undoLastAction()
                }
                .buttonStyle(.bordered)
                .disabled(diskTool.isDeleting)
                .accessibilityIdentifier("cleanup-undo-quarantine")
            }

            Spacer()
            if let lastScan = diskTool.lastScan {
                Text("Scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let selectedSupportedScope = diskTool.selectedSupportedScope {
                Text("Selected scope: \(selectedSupportedScope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanLabel: String {
        diskTool.selectedSupportedScope == nil ? "Scan App-Owned Data" : "Scan Supported Data"
    }

    private var opportunityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            TunixSectionHeader(
                title: "Verified cleanup opportunities",
                subtitle: "Only Small Matter-owned or explicitly supported user-selected data appears here"
            )

            if let inventory = diskTool.inventory {
                HStack(spacing: 16) {
                    CleanupSummaryMetric("Scanned", value: "\(inventory.scannedItemCount)")
                    CleanupSummaryMetric("Eligible", value: "\(inventory.candidates.count)")
                    CleanupSummaryMetric(
                        "Estimated",
                        value: formatter.string(fromByteCount: Int64(inventory.estimatedAllocatedBytes))
                    )
                }
                .padding(.bottom, 4)

                if inventory.candidates.isEmpty {
                    emptyOpportunities
                } else {
                    ForEach(inventory.candidates) { candidate in
                        CleanupCandidateRow(diskTool: diskTool, candidate: candidate, formatter: formatter)
                    }
                }

                if !inventory.skipped.isEmpty {
                    DisclosureGroup("Skipped for safety · \(skippedCount(inventory))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(inventory.skipped) { summary in
                                Text("\(summary.count) · \(summary.reason.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("cleanup-skipped-details")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Scan before choosing what to delete.", systemImage: "magnifyingglass")
                        .font(.headline)
                    Text(
                        "Small Matter will not sweep system folders, other applications, Quarantine, evidence, " +
                            "or user documents. Choose the standard Xcode Derived Data folder to review that " +
                            "specific regenerable category; arbitrary folders are not supported."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                .accessibilityIdentifier("cleanup-not-scanned")
            }
        }
    }

    private var emptyOpportunities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No verified cleanup opportunities.", systemImage: "checkmark.circle")
                .font(.headline)
            Text(
                "Nothing in the approved cleanup scopes is " +
                    "currently eligible for permanent deletion. " +
                    "This does not mean other locations are empty; they are " +
                    "intentionally not treated as safe cleanup targets."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .accessibilityIdentifier("cleanup-empty-state")
    }

    private func skippedCount(_ inventory: CleanupInventory) -> Int {
        inventory.skipped.reduce(0) { $0 + $1.count }
    }

    private func workflowStep(_ number: String, _ title: String) -> some View {
        Label(title, systemImage: "circle.fill")
            .labelStyle(WorkflowLabelStyle(number: number))
    }

    private var workflowDivider: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct WorkflowLabelStyle: LabelStyle {
    let number: String

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Color.secondary.opacity(0.15), in: Circle())
            configuration.title
        }
    }
}
